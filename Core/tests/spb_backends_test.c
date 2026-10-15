/*
 * C-level tests for PuTTY's other backends (M11), each against a peer
 * played by the test itself: Telnet (active and passive negotiation,
 * terminal type, window size, echo, Return as Telnet New Line, IAC
 * doubling, the Telnet commands menu), Rlogin (the greeting with local
 * and remote user names, a privileged source port, the user name asked
 * in the terminal, the server's window size request as urgent data),
 * SUPDUP (the terminal parameters as 36-bit words, the greeting up to
 * %TDNOP, the location string), and a serial line, played by a
 * pseudo-terminal (opening, line settings applied at start and changed
 * live, data both ways, a line that does not exist). Proxies (M12):
 * SOCKS 5 (no auth, password auth, host name left to the proxy), SOCKS 4,
 * HTTP CONNECT with Basic auth, the 'Telnet' ad-hoc command, a local
 * command, and the rules for when not to use the proxy.
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>                      /* openpty */

#include "PuTTYBridge.h"

static int failures;

#define CHECK(cond) do {                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n",                \
                    __FILE__, __LINE__, #cond);                         \
            failures++;                                                 \
        }                                                               \
    } while (0)

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------- The peer's end ---------- */

static int listen_loopback(int *port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = { .sin_family = AF_INET,
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t len = sizeof(a);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(fd, 4) < 0) {
        perror("listen");
        exit(2);
    }
    getsockname(fd, (struct sockaddr *)&a, &len);
    *port = ntohs(a.sin_port);
    return fd;
}

static int accept_within(int lfd, double timeout)
{
    struct pollfd p = { .fd = lfd, .events = POLLIN };
    if (poll(&p, 1, (int)(timeout * 1000)) <= 0)
        return -1;
    return accept(lfd, NULL, NULL);
}

/* Bytes the peer has received on one connection or line. */
typedef struct peer {
    int fd;
    unsigned char buf[8192];
    size_t len;
} peer;

/* Read whatever arrives within `timeout`; returns false on EOF. */
static bool peer_pump(peer *p, double timeout)
{
    struct pollfd pf = { .fd = p->fd, .events = POLLIN };
    if (poll(&pf, 1, (int)(timeout * 1000)) <= 0)
        return true;
    ssize_t n = read(p->fd, p->buf + p->len, sizeof(p->buf) - p->len);
    if (n > 0)
        p->len += (size_t)n;
    return n > 0;
}

/* Wait until `needle` has been received; it is then dropped, with
 * everything before it. */
static bool peer_expect(peer *p, const void *needle, size_t n, double timeout)
{
    double deadline = now_seconds() + timeout;
    for (;;) {
        unsigned char *at = memmem(p->buf, p->len, needle, n);
        if (at) {
            size_t used = (size_t)(at - p->buf) + n;
            memmove(p->buf, p->buf + used, p->len - used);
            p->len -= used;
            return true;
        }
        if (now_seconds() >= deadline || !peer_pump(p, 0.05)) {
            if (!memmem(p->buf, p->len, needle, n)) {
                fprintf(stderr, "  peer did not receive %zu expected bytes; "
                        "got %zu:", n, p->len);
                for (size_t i = 0; i < p->len && i < 160; i++)
                    fprintf(stderr, " %02x", p->buf[i]);
                fprintf(stderr, "\n");
                return false;
            }
        }
    }
}

static bool peer_quiet(peer *p, double timeout)
{
    peer_pump(p, timeout);
    return p->len == 0;
}

static void peer_send(peer *p, const void *data, size_t len)
{
    const char *d = data;
    while (len) {
        ssize_t n = write(p->fd, d, len);
        if (n <= 0) {
            perror("peer write");
            return;
        }
        d += n;
        len -= (size_t)n;
    }
}

#define PEER_EXPECT(p, lit) peer_expect(p, lit, sizeof(lit) - 1, 10)
#define PEER_SEND(p, lit) peer_send(p, lit, sizeof(lit) - 1)

/* ---------- Callbacks ---------- */

typedef struct record {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    spb_session_state state;
    char detail[512];
    char event_log[32768];
    char specials[2048];               /* command names, '|' separated */
    int reconfigured;
    bool released;
} record;

static record rec = {
    .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER,
};

#define WITH_REC(code) do {                                             \
        pthread_mutex_lock(&rec.lock); code;                            \
        pthread_cond_broadcast(&rec.cond);                              \
        pthread_mutex_unlock(&rec.lock);                                \
    } while (0)

static void cb_state(void *ctx, spb_session_state st, const char *detail)
{
    WITH_REC(rec.state = st;
             snprintf(rec.detail, sizeof(rec.detail), "%s",
                      detail ? detail : ""));
}

static void cb_event_log(void *ctx, const char *line)
{
    WITH_REC(size_t n = strlen(rec.event_log);
             snprintf(rec.event_log + n, sizeof(rec.event_log) - n, "%s\n",
                      line));
}

static void cb_specials(void *ctx, const spb_special *list, size_t n)
{
    WITH_REC(rec.specials[0] = 0;
             for (size_t i = 0; i < n; i++) {
                 if (list[i].kind != SPB_SPECIAL_COMMAND)
                     continue;
                 size_t len = strlen(rec.specials);
                 snprintf(rec.specials + len, sizeof(rec.specials) - len,
                          "%s|", list[i].name);
             });
}

static int32_t special_code(const spb_special *list, size_t n,
                            const char *name)
{
    for (size_t i = 0; i < n; i++)
        if (list[i].kind == SPB_SPECIAL_COMMAND && !strcmp(list[i].name, name))
            return list[i].code;
    return -1;
}

/* The code of a listed command, captured from the last list. */
static struct { char name[64]; int32_t code, arg; } wanted;

static void cb_specials_capture(void *ctx, const spb_special *list, size_t n)
{
    cb_specials(ctx, list, n);
    int32_t code = special_code(list, n, wanted.name);
    if (code >= 0)
        WITH_REC(wanted.code = code);
}

static spb_settings *exported;

static void cb_exported(void *ctx, uint64_t request, spb_settings *settings,
                        int32_t info)
{
    WITH_REC(spb_settings_free(exported); exported = settings);
}

static void cb_reconfigured(void *ctx, uint64_t request, const char *error)
{
    WITH_REC(if (!error) rec.reconfigured++);
}

static void cb_released(void *ctx) { WITH_REC(rec.released = true); }

static const spb_session_callbacks callbacks = {
    .state_changed = cb_state,
    .event_log = cb_event_log,
    .specials_changed = cb_specials_capture,
    .settings_exported = cb_exported,
    .reconfigured = cb_reconfigured,
    .released = cb_released,
};

typedef bool (*rec_pred)(void);

static bool wait_rec(rec_pred pred, double timeout)
{
    double deadline = now_seconds() + timeout;
    pthread_mutex_lock(&rec.lock);
    bool ok;
    while (!(ok = pred()) && now_seconds() < deadline) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 20 * 1000000;
        if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(&rec.cond, &rec.lock, &ts);
    }
    pthread_mutex_unlock(&rec.lock);
    return ok;
}

static bool is_connected(void) { return rec.state == SPB_SESSION_CONNECTED; }
static bool is_final(void)
{
    return rec.state == SPB_SESSION_CLOSED || rec.state == SPB_SESSION_FAILED;
}
static bool is_released(void) { return rec.released; }
static bool has_code(void) { return wanted.code >= 0; }
static bool is_exported(void) { return exported != NULL; }
static bool is_reconfigured(void) { return rec.reconfigured > 0; }

static bool log_has(const char *needle)
{
    pthread_mutex_lock(&rec.lock);
    bool found = strstr(rec.event_log, needle) != NULL;
    pthread_mutex_unlock(&rec.lock);
    return found;
}

static bool wait_log(const char *needle, double timeout)
{
    double deadline = now_seconds() + timeout;
    while (!log_has(needle)) {
        if (now_seconds() >= deadline) {
            fprintf(stderr, "  event log lacks \"%s\":\n%s\n", needle,
                    rec.event_log);
            return false;
        }
        usleep(5000);
    }
    return true;
}

/* ---------- The session and its terminal ---------- */

static spb_session *session;
static spb_frame_info info;
static spb_cell *cells;
static uint8_t *lattrs, *dirty;
static size_t cells_cap, rows_cap;

static void read_frame(void)
{
    while (!spb_session_read_frame(session, &info, cells, cells_cap, lattrs,
                                   dirty, rows_cap)) {
        size_t need = (size_t)info.cols * info.rows;
        if (!need)
            return;
        cells = realloc(cells, need * sizeof(spb_cell));
        cells_cap = need;
        lattrs = realloc(lattrs, info.rows);
        dirty = realloc(dirty, info.rows);
        rows_cap = info.rows;
    }
}

static const char *screen_text(void)
{
    static char buf[64 * 1024];
    size_t n = 0;
    read_frame();
    for (int y = 0; y < info.rows; y++) {
        size_t start = n;
        for (int x = 0; x < info.cols && n < sizeof(buf) - 2; x++) {
            uint32_t c = cells[(size_t)y * info.cols + x].chars[0];
            buf[n++] = (c >= 0x20 && c < 0x7F) ? (char)c : ' ';
        }
        while (n > start && buf[n - 1] == ' ')
            n--;
        buf[n++] = '\n';
    }
    buf[n] = '\0';
    return buf;
}

static bool wait_screen(const char *needle, double timeout)
{
    double deadline = now_seconds() + timeout;
    while (now_seconds() < deadline) {
        if (strstr(screen_text(), needle))
            return true;
        usleep(5000);
    }
    fprintf(stderr, "  screen lacks \"%s\":\n%s\n", needle, screen_text());
    return false;
}

static void type(const char *text)
{
    spb_session_text(session, text, strlen(text), 0);
}

/* pairs: NULL-terminated keyword/value pairs over PuTTY's defaults. */
static void open_session(const char *const *pairs, const char *special)
{
    WITH_REC(rec.state = SPB_SESSION_CREATED; rec.detail[0] = 0;
             rec.event_log[0] = 0; rec.specials[0] = 0;
             rec.reconfigured = 0; rec.released = false;
             wanted.code = -1;
             snprintf(wanted.name, sizeof(wanted.name), "%s",
                      special ? special : ""));
    spb_settings *s = spb_settings_new_defaults();
    for (; *pairs; pairs += 2)
        spb_settings_set(s, pairs[0], pairs[1]);
    char *err = NULL;
    session = spb_session_create(s, &callbacks, NULL, &err);
    spb_settings_free(s);
    if (!session) {
        fprintf(stderr, "create: %s\n", err);
        exit(2);
    }
    spb_session_set_focus(session, true);
    spb_session_start(session);
}

static void release_session(void)
{
    spb_session_release(session);
    CHECK(wait_rec(is_released, 10));
    session = NULL;
}

/* ---------- Telnet ---------- */

#define IAC "\xff"
#define WILL "\xfb"
#define WONT "\xfc"
#define DO "\xfd"
#define SB "\xfa"
#define SE "\xf0"
#define TTYPE "\x18"
#define NAWS "\x1f"
#define TOPT_ECHO "\x01"
#define SGA "\x03"

static void test_telnet(void)
{
    int port, lfd = listen_loopback(&port);
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    const char *const settings[] = {
        "Protocol", "telnet", "HostName", "127.0.0.1", "PortNumber", portstr,
        "TerminalType", "xterm", NULL };
    open_session(settings, "Are You There");

    peer p = { .fd = accept_within(lfd, 10) };
    CHECK(p.fd >= 0);
    CHECK(wait_rec(is_connected, 10));

    /* Active negotiation: the client offers its options at once. */
    CHECK(PEER_EXPECT(&p, IAC WILL NAWS));
    CHECK(PEER_EXPECT(&p, IAC WILL TTYPE));
    CHECK(PEER_EXPECT(&p, IAC DO TOPT_ECHO));
    p.len = 0;

    /* Terminal type, upper-cased as PuTTY sends it. */
    PEER_SEND(&p, IAC DO TTYPE IAC SB TTYPE "\x01" IAC SE);
    CHECK(PEER_EXPECT(&p, IAC SB TTYPE "\x00" "XTERM" IAC SE));
    /* Window size, and again after a resize. */
    PEER_SEND(&p, IAC DO NAWS);
    CHECK(PEER_EXPECT(&p, IAC SB NAWS "\x00\x50\x00\x18" IAC SE));
    spb_session_resize(session, 100, 30, 0, 0);
    CHECK(PEER_EXPECT(&p, IAC SB NAWS "\x00\x64\x00\x1e" IAC SE));
    CHECK(wait_log("client subnegotiation: SB TTYPE IS XTERM", 10));

    /* The server echoes and suppresses go-ahead: character at a time,
     * no local echo. */
    PEER_SEND(&p, IAC WILL TOPT_ECHO IAC WILL SGA "hello telnet\r\n");
    CHECK(wait_screen("hello telnet", 10));
    peer_pump(&p, 0.2);
    p.len = 0;

    /* Return sends Telnet New Line (CR LF) by default. */
    type("ab");
    spb_session_key(session, SPB_KEY_RETURN, 0);
    CHECK(PEER_EXPECT(&p, "ab\r\n"));
    CHECK(strstr(screen_text(), "ab") == NULL);       /* not echoed locally */

    /* A data byte 0xFF is doubled. */
    spb_session_send(session, "\xff", 1);
    CHECK(PEER_EXPECT(&p, "\xff\xff"));

    /* The Telnet commands menu, and one of its commands. */
    CHECK(wait_rec(has_code, 10));
    pthread_mutex_lock(&rec.lock);
    CHECK(strstr(rec.specials, "Are You There|Break|Synch|") != NULL);
    CHECK(strstr(rec.specials, "End Of File|") != NULL);
    int32_t ayt = wanted.code;
    pthread_mutex_unlock(&rec.lock);
    spb_session_special(session, ayt, 0);
    CHECK(PEER_EXPECT(&p, IAC "\xf6"));

    /* The server closes: the session ends cleanly. */
    close(p.fd);
    CHECK(wait_rec(is_final, 10));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_CLOSED);
    pthread_mutex_unlock(&rec.lock);
    release_session();

    /* Passive negotiation: nothing until the server starts, and Return
     * as ^M when Telnet New Line is off. */
    const char *const passive[] = {
        "Protocol", "telnet", "HostName", "127.0.0.1", "PortNumber", portstr,
        "PassiveTelnet", "1", "TelnetRet", "0", NULL };
    open_session(passive, NULL);
    peer q = { .fd = accept_within(lfd, 10) };
    CHECK(q.fd >= 0);
    CHECK(wait_rec(is_connected, 10));
    CHECK(peer_quiet(&q, 0.5));
    PEER_SEND(&q, IAC DO TTYPE);
    CHECK(PEER_EXPECT(&q, IAC WILL TTYPE));
    PEER_SEND(&q, IAC WILL TOPT_ECHO IAC WILL SGA);
    CHECK(PEER_EXPECT(&q, IAC DO SGA));
    q.len = 0;
    type("x");
    spb_session_key(session, SPB_KEY_RETURN, 0);
    CHECK(PEER_EXPECT(&q, "x\r"));
    CHECK(q.len == 0 || (q.buf[0] != '\n'));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(q.fd);
    close(lfd);
}

/* ---------- Rlogin ---------- */

static int peer_port(int fd)
{
    struct sockaddr_in a;
    socklen_t len = sizeof(a);
    getpeername(fd, (struct sockaddr *)&a, &len);
    return ntohs(a.sin_port);
}

static void test_rlogin(void)
{
    int port, lfd = listen_loopback(&port);
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    const char *const settings[] = {
        "Protocol", "rlogin", "HostName", "127.0.0.1", "PortNumber", portstr,
        "LocalUserName", "localme", "UserName", "remoteme",
        "TerminalType", "xterm", "TerminalSpeed", "38400,38400", NULL };
    open_session(settings, NULL);

    peer p = { .fd = accept_within(lfd, 10) };
    CHECK(p.fd >= 0);
    /* rlogin's "privileged" source port, as upstream binds it. */
    int src = peer_port(p.fd);
    CHECK(src >= 512 && src <= 1023);
    if (!(src >= 512 && src <= 1023))
        fprintf(stderr, "  rlogin source port %d\n", src);
    CHECK(peer_expect(&p, "\0localme\0remoteme\0xterm/38400\0", 30, 10));
    CHECK(wait_rec(is_connected, 10));

    /* The server's first byte (NUL) is not shown. */
    PEER_SEND(&p, "\0welcome to rlogin\r\n");
    CHECK(wait_screen("welcome to rlogin", 10));

    /* The server asks for window sizes with urgent data 0x80. */
    send(p.fd, "\x80", 1, MSG_OOB);
    CHECK(PEER_EXPECT(&p, "\xff\xff" "ss" "\x00\x18\x00\x50\x00\x00\x00\x00"));
    spb_session_resize(session, 90, 40, 0, 0);
    CHECK(PEER_EXPECT(&p, "\xff\xff" "ss" "\x00\x28\x00\x5a\x00\x00\x00\x00"));

    type("ls");
    CHECK(PEER_EXPECT(&p, "ls"));
    close(p.fd);
    CHECK(wait_rec(is_final, 10));
    release_session();

    /* No remote user name configured: PuTTY asks in the terminal. */
    const char *const ask[] = {
        "Protocol", "rlogin", "HostName", "127.0.0.1", "PortNumber", portstr,
        "LocalUserName", "localme", "TerminalSpeed", "9600,9600", NULL };
    open_session(ask, NULL);
    peer q = { .fd = accept_within(lfd, 10) };
    CHECK(q.fd >= 0);
    CHECK(wait_screen("rlogin username:", 10));
    type("bob\r");
    CHECK(peer_expect(&q, "\0localme\0bob\0xterm/9600\0", 24, 10));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(q.fd);
    close(lfd);
}

/* ---------- SUPDUP ---------- */

static uint64_t word36(const unsigned char *b)
{
    uint64_t w = 0;
    for (int i = 0; i < 6; i++)
        w = (w << 6) | (b[i] & 077);
    return w;
}

static void test_supdup(void)
{
    int port, lfd = listen_loopback(&port);
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    const char *const settings[] = {
        "Protocol", "supdup", "HostName", "127.0.0.1", "PortNumber", portstr,
        "SUPDUPLocation", "Test Lab", "SUPDUPMoreProcessing", "1", NULL };
    open_session(settings, NULL);

    peer p = { .fd = accept_within(lfd, 10) };
    CHECK(p.fd >= 0);
    CHECK(wait_rec(is_connected, 10));

    /* Six 36-bit words, each as six 6-bit bytes. */
    double deadline = now_seconds() + 10;
    while (p.len < 36 && now_seconds() < deadline)
        peer_pump(&p, 0.05);
    CHECK(p.len >= 36);
    CHECK(word36(p.buf) == 0777773000000ULL);       /* -6 words */
    CHECK(word36(p.buf + 6) == 7);                   /* terminal type */
    uint64_t ttyopt = word36(p.buf + 12);
    CHECK(ttyopt & 0000200000000ULL);                /* TOMOR: **MORE** */
    CHECK(!(ttyopt & 0000100000000ULL));             /* TOROL off */
    CHECK(word36(p.buf + 18) == 24);                 /* height */
    CHECK(word36(p.buf + 24) == 79);                 /* width - 1 */
    CHECK(word36(p.buf + 30) == 1);                  /* scroll amount */
    p.len = 0;

    /* The greeting, up to %TDNOP; then display data, after which the
     * client sends its location. */
    PEER_SEND(&p, "SUPDUP greeting\r\n\210");
    CHECK(wait_screen("SUPDUP greeting", 10));
    PEER_SEND(&p, "Ready");
    CHECK(wait_screen("Ready", 10));
    CHECK(peer_expect(&p, "\300\302Test Lab\0", 11, 10));

    type("q");
    CHECK(PEER_EXPECT(&p, "q"));
    close(p.fd);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(lfd);
}

/* ---------- Serial ---------- */

static speed_t line_speed(int fd)
{
    struct termios t;
    if (tcgetattr(fd, &t) < 0)
        return 0;
    return cfgetospeed(&t);
}

static void test_serial(void)
{
    int master, slave;
    char line[128];
    if (openpty(&master, &slave, line, NULL, NULL) < 0) {
        perror("openpty");
        failures++;
        return;
    }
    /* The device end is raw, so bytes pass unchanged. */
    struct termios t;
    tcgetattr(slave, &t);
    cfmakeraw(&t);
    tcsetattr(slave, TCSANOW, &t);

    const char *const settings[] = {
        "Protocol", "serial", "SerialLine", line, "SerialSpeed", "9600",
        "SerialDataBits", "8", "SerialStopHalfbits", "2",
        "SerialParity", "0", "SerialFlowControl", "0", NULL };
    open_session(settings, NULL);
    CHECK(wait_rec(is_connected, 10));
    char opening[200];
    snprintf(opening, sizeof(opening), "Opening serial device %s", line);
    CHECK(wait_log(opening, 10));
    CHECK(wait_log("Configuring baud rate 9600", 10));
    CHECK(wait_log("1 stop bit", 10));
    CHECK(line_speed(slave) == B9600);

    peer m = { .fd = master };
    PEER_SEND(&m, "from the device\r\n");
    CHECK(wait_screen("from the device", 10));
    type("typed");
    CHECK(PEER_EXPECT(&m, "typed"));

    /* Change Settings: a new speed applies to the open line. */
    spb_session_export_settings(session, 1);
    CHECK(wait_rec(is_exported, 10));
    pthread_mutex_lock(&rec.lock);
    spb_settings *s = exported;
    exported = NULL;
    pthread_mutex_unlock(&rec.lock);
    spb_settings_set(s, "SerialSpeed", "19200");
    spb_session_reconfigure(session, s, 2);
    spb_settings_free(s);
    CHECK(wait_rec(is_reconfigured, 10));
    CHECK(wait_log("Configuring baud rate 19200", 10));
    CHECK(line_speed(slave) == B19200);
    type("again");
    CHECK(PEER_EXPECT(&m, "again"));

    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(master);
    close(slave);
}

/* ---------- Proxies (M12) ---------- */

/* A Raw session to target.invalid:4321 through a proxy the test plays;
 * extra: more keyword/value pairs. Returns the proxy's connection. */
static peer proxied_session(int lfd, int proxy_port, const char *method,
                            const char *const *extra)
{
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", proxy_port);
    const char *pairs[40] = {
        "Protocol", "raw", "HostName", "target.invalid", "PortNumber", "4321",
        "ProxyMethod", method, "ProxyHost", "127.0.0.1", "ProxyPort", portstr,
    };
    size_t n = 12;
    for (; extra && *extra && n < 38; extra++)
        pairs[n++] = *extra;
    pairs[n] = NULL;
    open_session(pairs, NULL);
    peer p = { .fd = accept_within(lfd, 10) };
    CHECK(p.fd >= 0);
    return p;
}

/* After the proxy's handshake the test is the target: data both ways,
 * the client speaking first (as Rlogin's does). */
static void check_tunnel(peer *p)
{
    CHECK(wait_rec(is_connected, 10));
    spb_session_send(session, "up", 2);
    CHECK(peer_expect(p, "up", 2, 3));
    PEER_SEND(p, "via the proxy\r\n");
    CHECK(wait_screen("via the proxy", 10));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(p->fd);
}

static void test_proxies(void)
{
    int port, lfd = listen_loopback(&port);
    char logline[200];

    /* SOCKS 5, no authentication. The host name is left to the proxy
     * (ProxyDNS Auto), so target.invalid never needs to resolve. */
    peer p = proxied_session(lfd, port, "2", NULL);
    CHECK(PEER_EXPECT(&p, "\x05\x03\x00\x03\x02"));      /* none, CHAP, password */
    PEER_SEND(&p, "\x05\x00");
    CHECK(PEER_EXPECT(&p, "\x05\x01\x00\x03\x0e" "target.invalid" "\x10\xe1"));
    PEER_SEND(&p, "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00");
    snprintf(logline, sizeof(logline),
             "Connecting to SOCKS 5 proxy at 127.0.0.1 port %d", port);
    CHECK(wait_log(logline, 10));
    CHECK(wait_log("Leaving host lookup to proxy of \"target.invalid\"", 10));
    check_tunnel(&p);

    /* SOCKS 5 with a user name and password (RFC 1929). */
    const char *const creds[] = { "ProxyUsername", "user", "ProxyPassword", "pass",
                                  NULL };
    p = proxied_session(lfd, port, "2", creds);
    CHECK(PEER_EXPECT(&p, "\x05\x03\x00\x03\x02"));
    PEER_SEND(&p, "\x05\x02");
    CHECK(PEER_EXPECT(&p, "\x01\x04user\x04pass"));
    PEER_SEND(&p, "\x01\x00");
    CHECK(PEER_EXPECT(&p, "\x05\x01\x00\x03\x0e" "target.invalid" "\x10\xe1"));
    PEER_SEND(&p, "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00");
    check_tunnel(&p);

    /* SOCKS 4 to an IP address (proxying local host turned on). */
    const char *const socks4[] = { "HostName", "127.0.0.1", "ProxyLocalhost", "1",
                                   "ProxyUsername", "u4", NULL };
    p = proxied_session(lfd, port, "1", socks4);
    CHECK(PEER_EXPECT(&p, "\x04\x01\x10\xe1\x7f\x00\x00\x01u4\0"));
    PEER_SEND(&p, "\x00\x5a\x00\x00\x00\x00\x00\x00");
    check_tunnel(&p);

    /* HTTP CONNECT: credentials only after the proxy asks for them (a
     * 407 offering Basic), on the same connection ("user:pass"). */
    p = proxied_session(lfd, port, "3", creds);
    CHECK(PEER_EXPECT(&p, "CONNECT target.invalid:4321 HTTP/1.1\r\n"
                      "Host: target.invalid:4321\r\n\r\n"));
    PEER_SEND(&p, "HTTP/1.1 407 Proxy Authentication Required\r\n"
              "Proxy-Authenticate: Basic realm=\"test\"\r\n"
              "Content-Length: 0\r\n\r\n");
    CHECK(PEER_EXPECT(&p, "CONNECT target.invalid:4321 HTTP/1.1\r\n"
                      "Host: target.invalid:4321\r\n"
                      "Proxy-Authorization: Basic dXNlcjpwYXNz\r\n\r\n"));
    PEER_SEND(&p, "HTTP/1.1 200 Connection established\r\n\r\n");
    check_tunnel(&p);

    /* 'Telnet' proxy: the ad-hoc command, with its default text. */
    p = proxied_session(lfd, port, "4", NULL);
    CHECK(PEER_EXPECT(&p, "connect target.invalid 4321\n"));
    check_tunnel(&p);

    /* Not proxied: local host connections (by default), and hosts in
     * the exclusion list. The proxy hears nothing. */
    int tport, tfd = listen_loopback(&tport);
    char tportstr[16];
    snprintf(tportstr, sizeof(tportstr), "%d", tport);
    for (int round = 0; round < 2; round++) {
        const char *const direct_local[] = { "HostName", "127.0.0.1", "PortNumber", tportstr,
                                             NULL };
        const char *const direct_excluded[] = { "HostName", "127.0.0.1", "PortNumber", tportstr,
                                                "ProxyLocalhost", "1",
                                                "ProxyExcludeList", "127.0.0.*", NULL };
        char portstr[16];
        snprintf(portstr, sizeof(portstr), "%d", port);
        const char *pairs[24] = { "Protocol", "raw", "ProxyMethod", "2",
                                  "ProxyHost", "127.0.0.1", "ProxyPort", portstr };
        size_t n = 8;
        for (const char *const *e = round ? direct_excluded : direct_local; *e; e++)
            pairs[n++] = *e;
        pairs[n] = NULL;
        open_session(pairs, NULL);
        peer t = { .fd = accept_within(tfd, 10) };
        CHECK(t.fd >= 0);
        CHECK(wait_rec(is_connected, 10));
        CHECK(accept_within(lfd, 0.3) < 0);
        PEER_SEND(&t, "direct\r\n");
        CHECK(wait_screen("direct", 10));
        spb_session_close(session);
        CHECK(wait_rec(is_final, 10));
        release_session();
        close(t.fd);
    }
    close(tfd);

    /* Local proxy command: a subprogram, with %host and %port filled in,
     * carries the connection. */
    const char *const local[] = {
        "ProxyMethod", "5",
        "ProxyTelnetCommand", "printf 'local-proxy:%host:%port\\r\\n'; cat", NULL };
    const char *pairs[16] = { "Protocol", "raw", "HostName", "target.invalid",
                              "PortNumber", "4321" };
    size_t n = 6;
    for (const char *const *e = local; *e; e++)
        pairs[n++] = *e;
    pairs[n] = NULL;
    open_session(pairs, NULL);
    CHECK(wait_screen("local-proxy:target.invalid:4321", 10));
    CHECK(wait_rec(is_connected, 10));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();

    close(lfd);
}

/* ---------- Local commands (M13) ---------- */

static char workdir[600];

static bool read_file(const char *name, char *buf, size_t size)
{
    char path[700];
    snprintf(path, sizeof(path), "%s/%s", workdir, name);
    FILE *f = fopen(path, "r");
    if (!f)
        return false;
    size_t n = fread(buf, 1, size - 1, f);
    buf[n] = 0;
    fclose(f);
    return true;
}

/* The process whose pid the command wrote to `name` has been reaped:
 * not even a zombie is left. */
static bool reaped(const char *name)
{
    char buf[32];
    if (!read_file(name, buf, sizeof(buf)))
        return false;
    pid_t pid = (pid_t)atoi(buf);
    if (pid <= 0)
        return false;
    double deadline = now_seconds() + 10;
    while (now_seconds() < deadline) {
        if (kill(pid, 0) < 0 && errno == ESRCH)
            return true;
        usleep(10000);
    }
    return false;
}

static void test_preconnect(void)
{
    int tport, tfd = listen_loopback(&tport);
    char tportstr[16], cmd[2048];
    snprintf(tportstr, sizeof(tportstr), "%d", tport);

    /* The command runs to completion before the connection is made; its
     * exit status is logged; it does not inherit this process's
     * descriptors (fd 200, a copy of the listening socket, is not
     * close-on-exec); and it is reaped. */
    CHECK(dup2(tfd, 200) == 200);
    snprintf(cmd, sizeof(cmd),
             "echo $$ > '%s/pre.pid'; "
             "if [ -e /dev/fd/200 ]; then echo inherited; else echo closed; fi > '%s/pre.fds'; "
             "echo %%host:%%port > '%s/pre.ran'; exit 3",
             workdir, workdir, workdir);
    const char *const pairs[] = { "Protocol", "raw", "HostName", "127.0.0.1",
                                  "PortNumber", tportstr,
                                  "PreConnectCommand", cmd, NULL };
    open_session(pairs, NULL);
    peer t = { .fd = accept_within(tfd, 10) };
    CHECK(t.fd >= 0);
    char buf[256];
    snprintf(buf, sizeof(buf), "127.0.0.1:%d\n", tport);
    char ran[256] = "";
    CHECK(read_file("pre.ran", ran, sizeof(ran)) && !strcmp(ran, buf));
    CHECK(wait_log("Running pre-connect command: echo $$", 10));
    CHECK(wait_log("Pre-connect command exited with status 3", 10));
    CHECK(wait_rec(is_connected, 10));
    PEER_SEND(&t, "after the command\r\n");
    CHECK(wait_screen("after the command", 10));
    char fds[64] = "";
    CHECK(read_file("pre.fds", fds, sizeof(fds)) && !strcmp(fds, "closed\n"));
    close(200);
    CHECK(reaped("pre.pid"));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    close(t.fd);

    /* %user and %pass are refused (the command does not run), and the
     * session keeps its proxy credentials for the proxy (patch 0014:
     * before, %pass expanded to the password, in the Event Log too, and
     * the SOCKS 5 proxy got empty credentials). */
    int pport, pfd = listen_loopback(&pport);
    snprintf(cmd, sizeof(cmd), "echo %%user:%%pass > '%s/leak'", workdir);
    const char *const creds[] = { "ProxyUsername", "user", "ProxyPassword", "s3cretpw",
                                  "PreConnectCommand", cmd, NULL };
    peer p = proxied_session(pfd, pport, "2", creds);
    CHECK(PEER_EXPECT(&p, "\x05\x03\x00\x03\x02"));
    PEER_SEND(&p, "\x05\x02");
    CHECK(PEER_EXPECT(&p, "\x01\x04user\x08s3cretpw"));
    PEER_SEND(&p, "\x01\x00");
    CHECK(PEER_EXPECT(&p, "\x05\x01\x00\x03\x0e" "target.invalid" "\x10\xe1"));
    PEER_SEND(&p, "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00");
    CHECK(wait_log("Pre-connect command: references to %user or %pass not supported", 10));
    check_tunnel(&p);
    CHECK(!read_file("leak", buf, sizeof(buf)));
    CHECK(!log_has("s3cretpw"));

    /* A local proxy command is reaped when its connection closes (it
     * was left a zombie before patch 0015). */
    snprintf(cmd, sizeof(cmd), "echo $$ > '%s/proxy.pid'; echo proxied; cat", workdir);
    const char *const local[] = { "Protocol", "raw", "HostName", "target.invalid",
                                  "PortNumber", "4321", "ProxyMethod", "5",
                                  "ProxyTelnetCommand", cmd, NULL };
    open_session(local, NULL);
    CHECK(wait_screen("proxied", 10));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    CHECK(reaped("proxy.pid"));

    close(pfd);
    close(tfd);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    char template[] = "/tmp/spb-backends-test-XXXXXX";
    char *base = mkdtemp(template);
    if (!base) {
        perror("mkdtemp");
        return 2;
    }
    char state_dir[600];
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);
    char *err = NULL;
    spb_core_options opts = { .state_dir = state_dir };
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "init: %s\n", err);
        return 2;
    }

    test_telnet();
    test_rlogin();
    test_supdup();
    test_serial();
    test_proxies();
    snprintf(workdir, sizeof(workdir), "%s", base);
    test_preconnect();

    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);
    CHECK(spb_core_shutdown());
    spb_settings_free(exported);
    free(cells);
    free(lattrs);
    free(dirty);

    char cmd[700];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", base);
    if (system(cmd) != 0)
        fprintf(stderr, "could not remove %s\n", base);

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("spb_backends_test: all checks passed\n");
    return 0;
}
