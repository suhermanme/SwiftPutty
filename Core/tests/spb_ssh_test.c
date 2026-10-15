/*
 * C-level tests for SSH sessions (M04), against upstream's test server
 * uppity run by spb_ssh_fixture on 127.0.0.1: host key confirmation
 * (accept and store, accept once, cancel, changed key), login prompts in
 * the terminal (user name, password, wrong password), shell input and
 * output, terminal size, exit status, and closing with a prompt pending.
 * Live reconfiguration (M07) and port forwarding (M08): local, dynamic
 * and remote forwardings added, used and removed on a live connection,
 * their status events, and the H-1 / H-2 regressions.
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "PuTTYBridge.h"

#ifndef SPB_SSH_FIXTURE
#error "SPB_SSH_FIXTURE, SPB_UPPITY and SPB_FIXTURES_DIR come from CMake"
#endif

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

/* ---------- The SSH server fixture ---------- */

typedef struct fixture {
    pid_t pid;
    int to_child;                      /* closing it stops the fixture */
    int port;
} fixture;

static char workdir[512];

/*
 * The fixture binaries. Sanitizer builds run the plain build's copies
 * (SPB_SSH_FIXTURE_DIR, set by scripts/build-core.sh): the sanitizers are
 * for the code under test, not for the test server, whose forked shells
 * gain nothing from running sanitized.
 */
static void fixture_paths(const char **fixture, const char **uppity)
{
    static char fx[1024], up[1024];
    const char *dir = getenv("SPB_SSH_FIXTURE_DIR");
    if (dir && *dir) {
        snprintf(fx, sizeof(fx), "%s/spb_ssh_fixture", dir);
        snprintf(up, sizeof(up), "%s/uppity", dir);
        *fixture = fx;
        *uppity = up;
    } else {
        *fixture = SPB_SSH_FIXTURE;
        *uppity = SPB_UPPITY;
    }
}

static fixture fixture_start(const char *hostkey, int port)
{
    const char *fixture_bin, *uppity_bin;
    fixture_paths(&fixture_bin, &uppity_bin);
    int in[2], out[2];
    if (pipe(in) < 0 || pipe(out) < 0) {
        perror("pipe");
        exit(2);
    }
    char key[1024], portstr[16];
    snprintf(key, sizeof(key), "%s/%s", SPB_FIXTURES_DIR, hostkey);
    snprintf(portstr, sizeof(portstr), "%d", port);

    fixture f = { .pid = fork() };
    if (f.pid == 0) {
        dup2(in[0], STDIN_FILENO);
        dup2(out[1], STDOUT_FILENO);
        close(in[1]);
        close(out[0]);
        if (port)
            execl(fixture_bin, fixture_bin, uppity_bin, key, workdir,
                  "--port", portstr, (char *)NULL);
        else
            execl(fixture_bin, fixture_bin, uppity_bin, key, workdir,
                  (char *)NULL);
        _exit(127);
    }
    close(in[0]);
    close(out[1]);
    f.to_child = in[1];
    FILE *fp = fdopen(out[0], "r");
    if (fscanf(fp, "PORT %d", &f.port) != 1) {
        fprintf(stderr, "fixture did not start\n");
        exit(2);
    }
    fclose(fp);
    return f;
}

static void fixture_stop(fixture *f)
{
    close(f->to_child);
    waitpid(f->pid, NULL, 0);
}

/* ---------- Callbacks ---------- */

typedef struct record {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    spb_session_state state;
    char detail[512];
    int exit_code;
    bool got_exit, released;
    /* Prompts */
    int prompts;
    spb_prompt_kind prompt_kind;
    uint64_t prompt_id;
    bool prompt_scary, prompt_has_fingerprint;
    char prompt_title[256];
    int prompts_cancelled;
    /* Event Log and reconfiguration (M07) */
    char event_log[16384];
    spb_settings *exported;
    int32_t protocol_info;
    int reconfigured;
    /* Port forwarding status events (M08), in order */
    struct { spb_portfwd_state state; char key[64]; char message[256]; }
        portfwd[256];
    int n_portfwd;
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

static void cb_exit(void *ctx, int32_t code)
{
    WITH_REC(rec.got_exit = true; rec.exit_code = code);
}

static void cb_released(void *ctx) { WITH_REC(rec.released = true); }

static void cb_prompt(void *ctx, const spb_prompt *p)
{
    bool scary = false, fingerprint = false;
    char title[256] = "";
    for (size_t i = 0; i < p->n_items; i++) {
        if (p->items[i].type == SPB_DIALOG_SCARY_HEADING)
            scary = true;
        if (p->items[i].type == SPB_DIALOG_DISPLAY &&
            strstr(p->items[i].text, "ssh-ed25519"))
            fingerprint = true;
        if (p->items[i].type == SPB_DIALOG_TITLE)
            snprintf(title, sizeof(title), "%s", p->items[i].text);
    }
    WITH_REC(rec.prompts++; rec.prompt_kind = p->kind;
             rec.prompt_id = p->id; rec.prompt_scary = scary;
             rec.prompt_has_fingerprint = fingerprint;
             snprintf(rec.prompt_title, sizeof(rec.prompt_title), "%s",
                      title));
}

static void cb_prompt_cancelled(void *ctx, uint64_t id)
{
    WITH_REC(rec.prompts_cancelled++);
}

static void cb_event_log(void *ctx, const char *line)
{
    WITH_REC(size_t n = strlen(rec.event_log);
             snprintf(rec.event_log + n, sizeof(rec.event_log) - n, "%s\n",
                      line));
}

static void cb_exported(void *ctx, uint64_t request, spb_settings *settings,
                        int32_t info)
{
    WITH_REC(spb_settings_free(rec.exported); rec.exported = settings;
             rec.protocol_info = info);
}

static void cb_reconfigured(void *ctx, uint64_t request, const char *error)
{
    WITH_REC(if (!error) rec.reconfigured++);
}

static void cb_portfwd(void *ctx, const spb_portfwd_status *st)
{
    WITH_REC(if (rec.n_portfwd < 256) {
                 rec.portfwd[rec.n_portfwd].state = st->state;
                 snprintf(rec.portfwd[rec.n_portfwd].key,
                          sizeof(rec.portfwd[0].key), "%s", st->key);
                 snprintf(rec.portfwd[rec.n_portfwd].message,
                          sizeof(rec.portfwd[0].message), "%s",
                          st->message ? st->message : "");
                 rec.n_portfwd++;
             });
}

static const spb_session_callbacks callbacks = {
    .state_changed = cb_state,
    .remote_exit = cb_exit,
    .released = cb_released,
    .prompt = cb_prompt,
    .prompt_cancelled = cb_prompt_cancelled,
    .event_log = cb_event_log,
    .settings_exported = cb_exported,
    .reconfigured = cb_reconfigured,
    .portfwd_status = cb_portfwd,
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

static bool has_prompt(void) { return rec.prompts > 0; }
static bool is_connected(void) { return rec.state == SPB_SESSION_CONNECTED; }
static bool is_final(void)
{
    return rec.state == SPB_SESSION_CLOSED || rec.state == SPB_SESSION_FAILED;
}
static bool is_released(void) { return rec.released; }
static bool prompt_was_cancelled(void) { return rec.prompts_cancelled > 0; }

static void reset_record(void)
{
    spb_settings_free(rec.exported);
    rec.exported = NULL;
    rec.event_log[0] = '\0';
    rec.reconfigured = 0;
    rec.n_portfwd = 0;
    WITH_REC(rec.state = SPB_SESSION_CREATED; rec.detail[0] = 0;
             rec.got_exit = false; rec.released = false; rec.prompts = 0;
             rec.prompts_cancelled = 0);
}

/* ---------- Terminal contents ---------- */

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

/* The whole screen as text (ASCII only; rows joined with '\n', trailing
 * spaces removed, so needles must not end in a space). PuTTY's trust
 * sigil in front of its own prompts reads as spaces. */
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

static void open_session(int port, const char *username, bool kbdint)
{
    reset_record();
    spb_settings *s = spb_settings_new_defaults();
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    spb_settings_set(s, "HostName", "127.0.0.1");
    spb_settings_set(s, "PortNumber", portstr);
    spb_settings_set(s, "UserName", username ? username : "");
    spb_settings_set(s, "AuthKI", kbdint ? "1" : "0");
    /* No agent or GSSAPI: the test's results must not depend on the
     * developer's environment. */
    spb_settings_set(s, "TryAgent", "0");
    spb_settings_set(s, "AuthGSSAPI", "0");
    spb_settings_set(s, "AuthGSSAPIKEX", "0");
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

static void answer(spb_prompt_answer a)
{
    pthread_mutex_lock(&rec.lock);
    uint64_t id = rec.prompt_id;
    rec.prompts = 0;
    pthread_mutex_unlock(&rec.lock);
    spb_session_answer_prompt(session, id, a);
}

/* ---------- Tests ---------- */

static void test_first_connection(fixture *f)
{
    open_session(f->port, NULL, true);

    /* Unknown host key: a dialog, which we accept and store. */
    CHECK(wait_rec(has_prompt, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.prompt_kind == SPB_PROMPT_HOST_KEY);
    CHECK(rec.prompt_has_fingerprint);
    CHECK(!rec.prompt_scary);
    CHECK(strstr(rec.prompt_title, "Security Alert") != NULL);
    CHECK(rec.state == SPB_SESSION_CONNECTING);
    pthread_mutex_unlock(&rec.lock);
    answer(SPB_ANSWER_ACCEPT_AND_STORE);

    /* The login prompts are in the terminal, as in PuTTY. uppity's
     * keyboard-interactive script: an echoed prompt ("stoat") and a
     * silent one ("weasel"). */
    CHECK(wait_screen("login as:", 20));
    type("tester\r");
    CHECK(wait_screen("Initial double prompt", 20));
    CHECK(wait_screen("Echoey prompt:", 20));
    type("stoat\r");
    CHECK(wait_screen("Echoey prompt: stoat\n", 20));
    CHECK(wait_screen("Silent prompt:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    CHECK(strstr(screen_text(), "weasel") == NULL);   /* never echoed */

    /* A shell: computed output proves the command ran remotely. */
    type("echo hello-$((6*7))\r");
    CHECK(wait_screen("\nhello-42\n", 20));

    /* The terminal size reaches the remote pty. */
    spb_session_resize(session, 100, 30, 800, 480);
    type("stty size\r");
    CHECK(wait_screen("\n30 100\n", 20));

    type("exit 3\r");
    CHECK(wait_rec(is_final, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_CLOSED);
    /* uppity reports 127 when its pty reaches EOF before it has reaped the
     * shell (unix/pty.c, EXITTYPE_WEIRD): a race in the test server. The
     * client reports what it is sent; exact codes are checked against
     * OpenSSH by hand (docs/TESTING.md). */
    CHECK(rec.got_exit && (rec.exit_code == 3 || rec.exit_code == 127));
    pthread_mutex_unlock(&rec.lock);
    release_session();
}

static void test_stored_key_and_wrong_password(fixture *f)
{
    /* The key is cached now: no dialog. The user name is configured, so
     * only the password is asked for. */
    open_session(f->port, "tester", false);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("not-the-password\r");
    CHECK(wait_screen("Access denied\n", 20));
    /* Asked again (the line starts with PuTTY's trust sigil). */
    CHECK(wait_screen("Access denied\n   tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.prompts == 0);
    pthread_mutex_unlock(&rec.lock);

    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
}

static bool is_exported(void) { return rec.exported != NULL; }
static bool is_reconfigured(void) { return rec.reconfigured > 0; }
/* Re-keyed, and the new first choice (ChaCha20) is in use afterwards. */
static bool rekeyed(void)
{
    const char *start = strstr(rec.event_log,
        "Initiating key re-exchange (cipher settings changed)");
    if (!start)
        return false;
    const char *init = strstr(start, "inbound encryption");
    if (!init)
        return false;
    const char *line = init;
    while (line > start && line[-1] != '\n')
        line--;
    return strstr(line, "ChaCha20") != NULL && strstr(line, "ChaCha20") < init;
}

/* M07: Change Settings on a live SSH session never reconnects. A new
 * cipher order makes PuTTY re-key the same connection. */
static void test_live_reconfigure(fixture *f)
{
    open_session(f->port, "tester", false);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    uint64_t transport = spb_session_transport_id(session);
    CHECK(transport != 0);

    spb_session_export_settings(session, 7);
    CHECK(wait_rec(is_exported, 10));
    pthread_mutex_lock(&rec.lock);
    spb_settings *s = rec.exported;
    rec.exported = NULL;
    CHECK(rec.protocol_info == 2);                     /* SSH-2 */
    pthread_mutex_unlock(&rec.lock);

    spb_settings_set(s, "Cipher", "chacha20,aes,aesgcm,3des,WARN,des,blowfish,arcfour");
    spb_settings_set(s, "PingIntervalSecs", "30");     /* keepalives on */
    spb_session_reconfigure(session, s, 8);
    spb_settings_free(s);
    CHECK(wait_rec(is_reconfigured, 10));
    CHECK(wait_rec(rekeyed, 20));

    /* Same connection, shell still there. */
    type("echo still-$((5*5))\r");
    CHECK(wait_screen("\nstill-25\n", 20));
    CHECK(spb_session_transport_id(session) == transport);
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_CONNECTED);
    pthread_mutex_unlock(&rec.lock);

    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
}

static void test_accept_once_and_cancel(void)
{
    /* A second server on another port: its key is not cached. */
    fixture other = fixture_start("hostkey-b.ppk", 0);

    open_session(other.port, "tester", false);
    CHECK(wait_rec(has_prompt, 20));
    answer(SPB_ANSWER_ACCEPT_ONCE);
    CHECK(wait_screen("password:", 20));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();

    /* "Connect Once" did not store it: asked again; Cancel ends it. */
    open_session(other.port, "tester", false);
    CHECK(wait_rec(has_prompt, 20));
    answer(SPB_ANSWER_CANCEL);
    CHECK(wait_rec(is_final, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_FAILED || rec.state == SPB_SESSION_CLOSED);
    pthread_mutex_unlock(&rec.lock);
    release_session();

    /* Closing while the dialog is up withdraws it. */
    open_session(other.port, "tester", false);
    CHECK(wait_rec(has_prompt, 20));
    spb_session_close(session);
    CHECK(wait_rec(prompt_was_cancelled, 10));
    uint64_t stale = rec.prompt_id;
    spb_session_answer_prompt(session, stale, SPB_ANSWER_ACCEPT_ONCE);
    CHECK(spb_core_barrier());         /* the stale answer is ignored */
    release_session();

    fixture_stop(&other);
}

static void test_changed_host_key(fixture *f)
{
    /* Same address and port, different key: PuTTY's scary warning. */
    int port = f->port;
    fixture_stop(f);
    fixture impostor = fixture_start("hostkey-b.ppk", port);

    open_session(port, "tester", false);
    CHECK(wait_rec(has_prompt, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.prompt_kind == SPB_PROMPT_HOST_KEY);
    CHECK(rec.prompt_scary);
    pthread_mutex_unlock(&rec.lock);
    answer(SPB_ANSWER_CANCEL);
    CHECK(wait_rec(is_final, 20));
    release_session();

    fixture_stop(&impostor);
}

/* ---------- Port forwarding (M08) ---------- */

/* A loopback echo server: one thread per connection. */
typedef struct echo_server { int fd, port; pthread_t thread; } echo_server;

static int loopback_listener(int *port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = { .sin_family = AF_INET,
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t len = sizeof(a);
    if (bind(fd, (struct sockaddr *)&a, len) < 0 || listen(fd, 64) < 0) {
        perror("listen");
        exit(2);
    }
    getsockname(fd, (struct sockaddr *)&a, &len);
    *port = ntohs(a.sin_port);
    return fd;
}

static int free_port(void)
{
    int port, fd = loopback_listener(&port);
    close(fd);
    return port;
}

static void *echo_conn(void *arg)
{
    int fd = (int)(intptr_t)arg;
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0)
        if (write(fd, buf, n) != n)
            break;
    close(fd);
    return NULL;
}

static void *echo_main(void *arg)
{
    echo_server *e = arg;
    int fd;
    while ((fd = accept(e->fd, NULL, NULL)) >= 0) {
        pthread_t t;
        pthread_create(&t, NULL, echo_conn, (void *)(intptr_t)fd);
        pthread_detach(t);
    }
    return NULL;
}

static void echo_start(echo_server *e)
{
    e->fd = loopback_listener(&e->port);
    pthread_create(&e->thread, NULL, echo_main, e);
}

static void echo_stop(echo_server *e)
{
    shutdown(e->fd, SHUT_RDWR);
    close(e->fd);
    pthread_join(e->thread, NULL);
}

/* Connect to 127.0.0.1:port; -1 if refused. */
static int connect_port(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct timeval tv = { 5, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port),
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool read_exactly(int fd, char *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0)
            return false;
        got += r;
    }
    return true;
}

/* Send text over fd and expect it back. */
static bool echoes(int fd, const char *text)
{
    size_t n = strlen(text);
    char buf[256] = "";
    return write(fd, text, n) == (ssize_t)n && read_exactly(fd, buf, n) &&
        !memcmp(buf, text, n);
}

/* SOCKS5 CONNECT to 127.0.0.1:target through the proxy at port. */
static int socks5_connect(int port, int target)
{
    int fd = connect_port(port);
    if (fd < 0)
        return -1;
    unsigned char hello[] = { 5, 1, 0 }, reply[10];
    unsigned char req[] = { 5, 1, 0, 1, 127, 0, 0, 1,
                            (unsigned char)(target >> 8),
                            (unsigned char)target };
    if (write(fd, hello, 3) != 3 || !read_exactly(fd, (char *)reply, 2) ||
        reply[1] != 0 || write(fd, req, sizeof(req)) != sizeof(req) ||
        !read_exactly(fd, (char *)reply, 10) || reply[1] != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static spb_settings *export_running(void)
{
    WITH_REC(spb_settings_free(rec.exported); rec.exported = NULL);
    spb_session_export_settings(session, 1);
    CHECK(wait_rec(is_exported, 10));
    pthread_mutex_lock(&rec.lock);
    spb_settings *s = rec.exported;
    rec.exported = NULL;
    pthread_mutex_unlock(&rec.lock);
    return s;
}

/* Reconfigure with PortForwardings = forwards (saved form) and wait for
 * the answer. */
static void set_forwards(const char *forwards)
{
    spb_settings *s = export_running();
    spb_settings_set(s, "PortForwardings", forwards);
    WITH_REC(rec.reconfigured = 0);
    spb_session_reconfigure(session, s, 2);
    spb_settings_free(s);
    CHECK(wait_rec(is_reconfigured, 10));
}

static const char *pf_key;
static spb_portfwd_state pf_state;
static bool has_status(void)
{
    for (int i = 0; i < rec.n_portfwd; i++)
        if (rec.portfwd[i].state == pf_state &&
            !strcmp(rec.portfwd[i].key, pf_key))
            return true;
    return false;
}

static bool wait_status(const char *key, spb_portfwd_state state)
{
    pf_key = key;
    pf_state = state;
    return wait_rec(has_status, 20);
}

static void clear_statuses(void)
{
    WITH_REC(rec.n_portfwd = 0);
}

/* A command round trip: the shell still runs, and every packet that
 * arrived before its output (e.g. global request replies) was handled. */
static bool shell_alive(void)
{
    static int n;
    char cmd[64], want[64];
    snprintf(cmd, sizeof(cmd), "echo alive-$((%d+1))\r", n);
    snprintf(want, sizeof(want), "\nalive-%d\n", n + 1);
    n++;
    type(cmd);
    return wait_screen(want, 20);
}

static void test_port_forwarding(fixture *f)
{
    echo_server echo;
    echo_start(&echo);

    open_session(f->port, "tester", false);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    uint64_t transport = spb_session_transport_id(session);

    int pl = free_port(), pd = free_port(), pr = free_port();
    char forwards[256], kl[32], kd[32], kr[32];
    snprintf(kl, sizeof(kl), "L%d", pl);
    snprintf(kd, sizeof(kd), "L%d", pd);      /* dynamic: L key, value D */
    snprintf(kr, sizeof(kr), "R%d", pr);
    snprintf(forwards, sizeof(forwards),
             "L%d=127.0.0.1:%d,D%d,R%d=127.0.0.1:%d",
             pl, echo.port, pd, pr, echo.port);

    /* Added live: all three come up, with their status. */
    set_forwards(forwards);
    CHECK(wait_status(kl, SPB_PORTFWD_LISTENING));
    CHECK(wait_status(kd, SPB_PORTFWD_LISTENING));
    CHECK(wait_status(kr, SPB_PORTFWD_REMOTE_REQUESTED));
    CHECK(wait_status(kr, SPB_PORTFWD_REMOTE_ENABLED));

    /* Local: through the client to the echo server. */
    int lfd = connect_port(pl);
    CHECK(lfd >= 0 && echoes(lfd, "local"));
    /* Dynamic: SOCKS5 to the echo server. */
    int dfd = socks5_connect(pd, echo.port);
    CHECK(dfd >= 0 && echoes(dfd, "dynamic"));
    if (dfd >= 0)
        close(dfd);
    /* Remote: the server listens, the client connects onwards. */
    int rfd = connect_port(pr);
    CHECK(rfd >= 0 && echoes(rfd, "remote"));
    if (rfd >= 0)
        close(rfd);

    /* Removed live: closed, new connections refused, the established
     * local stream still works, the shell too, same connection. */
    clear_statuses();
    set_forwards("");
    CHECK(wait_status(kl, SPB_PORTFWD_CLOSED));
    CHECK(wait_status(kd, SPB_PORTFWD_CLOSED));
    CHECK(wait_status(kr, SPB_PORTFWD_CLOSED));
    CHECK(connect_port(pl) < 0);
    CHECK(connect_port(pd) < 0);
    CHECK(lfd >= 0 && echoes(lfd, "still"));
    if (lfd >= 0)
        close(lfd);
    CHECK(shell_alive());
    CHECK(spb_session_transport_id(session) == transport);

    /* Remote forwarding on and off, many times. */
    snprintf(forwards, sizeof(forwards), "R%d=127.0.0.1:%d", pr, echo.port);
    for (int i = 0; i < 50; i++) {
        clear_statuses();
        set_forwards(forwards);
        CHECK(wait_status(kr, SPB_PORTFWD_REMOTE_ENABLED));
        if (i % 10 == 0) {
            rfd = connect_port(pr);
            CHECK(rfd >= 0 && echoes(rfd, "again"));
            if (rfd >= 0)
                close(rfd);
        }
        set_forwards("");
        CHECK(wait_status(kr, SPB_PORTFWD_CLOSED));
    }
    CHECK(shell_alive());

    /* A local port that is taken: listen failed, with PuTTY's reason. */
    int taken, busy = loopback_listener(&taken);
    char kt[32], taken_fwd[64];
    snprintf(kt, sizeof(kt), "L%d", taken);
    snprintf(taken_fwd, sizeof(taken_fwd), "L%d=127.0.0.1:%d", taken,
             echo.port);
    clear_statuses();
    set_forwards(taken_fwd);
    CHECK(wait_status(kt, SPB_PORTFWD_LISTEN_FAILED));
    set_forwards("");
    close(busy);

    /* H-1: a remote forwarding removed before the server has answered
     * (both changes run before any reply is read). Without patch 0007
     * the reply handler then uses the freed record (ASan: use after
     * free). */
    for (int i = 0; i < 5; i++) {
        spb_settings *s = export_running();
        spb_settings_set(s, "PortForwardings", forwards);
        spb_session_reconfigure(session, s, 3);
        spb_settings_set(s, "PortForwardings", "");
        spb_session_reconfigure(session, s, 4);
        spb_settings_free(s);
        CHECK(shell_alive());              /* the replies have been read */
    }
    CHECK(shell_alive());
    rfd = connect_port(pr);                /* and the server let go */
    CHECK(rfd < 0);
    if (rfd >= 0)
        close(rfd);

    /* H-2: two remote forwardings on one server port ("R" and "4R"); one
     * is a duplicate. Without patch 0008 its freed record stays in the
     * forwarding manager and the next change uses it (ASan: use after
     * free). */
    char both[128];
    snprintf(both, sizeof(both), "R%d=127.0.0.1:%d,4R%d=127.0.0.1:%d",
             pr, echo.port, pr, echo.port);
    clear_statuses();
    set_forwards(both);
    pthread_mutex_lock(&rec.lock);
    bool duplicate = false;
    for (int i = 0; i < rec.n_portfwd; i++)
        if (rec.portfwd[i].state == SPB_PORTFWD_DUPLICATE)
            duplicate = true;
    pthread_mutex_unlock(&rec.lock);
    CHECK(duplicate);
    for (int i = 0; i < 3; i++) {
        set_forwards(both);                /* the same again */
        CHECK(shell_alive());
    }
    set_forwards("");
    CHECK(shell_alive());
    CHECK(spb_session_transport_id(session) == transport);

    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    echo_stop(&echo);
}

int main(void)
{
    char template[] = "/tmp/spb-ssh-test-XXXXXX";
    char *base = mkdtemp(template);
    if (!base) {
        perror("mkdtemp");
        return 2;
    }
    char state_dir[600];
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);
    snprintf(workdir, sizeof(workdir), "%s", base);
    signal(SIGPIPE, SIG_IGN);

    char *err = NULL;
    spb_core_options opts = { .state_dir = state_dir };
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "init: %s\n", err);
        return 2;
    }

    fixture server = fixture_start("hostkey-a.ppk", 0);
    test_first_connection(&server);
    test_stored_key_and_wrong_password(&server);
    test_live_reconfigure(&server);
    test_port_forwarding(&server);
    test_accept_once_and_cancel();
    test_changed_host_key(&server);

    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);
    CHECK(spb_core_shutdown());
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
    printf("spb_ssh_test: all checks passed\n");
    return 0;
}
