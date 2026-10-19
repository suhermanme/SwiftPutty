/*
 * C-level tests for SSH sessions (M04), against upstream's test server
 * uppity run by spb_ssh_fixture on 127.0.0.1: host key confirmation
 * (accept and store, accept once, cancel, changed key), login prompts in
 * the terminal (user name, password, wrong password), shell input and
 * output, terminal size, exit status, and closing with a prompt pending.
 * Live reconfiguration (M07) and port forwarding (M08): local, dynamic
 * and remote forwardings added, used and removed on a live connection,
 * their status events, and the H-1 / H-2 regressions. Session
 * operations (M10): the Special Commands list and a user-requested
 * rekey, Clear Scrollback, Reset Terminal, the close warning, and
 * Restart Session.
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

/* extra: NULL-terminated uppity options, or NULL. */
static fixture fixture_start_with(const char *hostkey, int port,
                                  const char *const *extra)
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
        const char *args[64];
        int n = 0;
        args[n++] = fixture_bin;
        args[n++] = uppity_bin;
        args[n++] = key;
        args[n++] = workdir;
        if (port) {
            args[n++] = "--port";
            args[n++] = portstr;
        }
        if (extra && *extra) {
            args[n++] = "--";
            while (*extra && n < 63)
                args[n++] = *extra++;
        }
        args[n] = NULL;
        execv(fixture_bin, (char *const *)args);
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

static fixture fixture_start(const char *hostkey, int port)
{
    return fixture_start_with(hostkey, port, NULL);
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
    /* Special Commands (M10): the last list, and how many lists */
    struct { spb_special_kind kind; char name[64]; int32_t code, arg; }
        specials[128];
    size_t n_specials;
    int specials_updates;
    /* Close warning answers (M10) */
    int close_warnings;
    bool close_connected;
    char close_text[256];
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

static void cb_specials(void *ctx, const spb_special *list, size_t n)
{
    WITH_REC(rec.n_specials = n < 128 ? n : 128;
             for (size_t i = 0; i < rec.n_specials; i++) {
                 rec.specials[i].kind = list[i].kind;
                 snprintf(rec.specials[i].name, sizeof(rec.specials[0].name),
                          "%s", list[i].name ? list[i].name : "");
                 rec.specials[i].code = list[i].code;
                 rec.specials[i].arg = list[i].arg;
             }
             rec.specials_updates++);
}

static void cb_close_warning(void *ctx, uint64_t request, bool connected,
                             const char *text)
{
    WITH_REC(rec.close_warnings++; rec.close_connected = connected;
             snprintf(rec.close_text, sizeof(rec.close_text), "%s",
                      text ? text : ""));
}

static const spb_session_callbacks callbacks = {
    .specials_changed = cb_specials,
    .close_warning = cb_close_warning,
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
    WITH_REC(rec.n_specials = 0; rec.specials_updates = 0;
             rec.close_warnings = 0; rec.close_text[0] = 0;
             rec.state = SPB_SESSION_CREATED; rec.detail[0] = 0;
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

/* extra: NULL-terminated keyword/value pairs over the test defaults. */
static void open_session_with(int port, const char *username, bool kbdint,
                              const char *const *extra);

static void open_session(int port, const char *username, bool kbdint)
{
    open_session_with(port, username, kbdint, NULL);
}

static void open_session_with(int port, const char *username, bool kbdint,
                              const char *const *extra)
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
    for (; extra && *extra; extra += 2)
        spb_settings_set(s, extra[0], extra[1]);
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

/* ---------- Session operations (M10) ---------- */

static bool has_specials(void) { return rec.n_specials > 0; }
static bool no_specials(void)
{
    return rec.n_specials == 0 && rec.specials_updates > 0;
}
static bool close_warned(void) { return rec.close_warnings > 0; }
static bool rekeyed_by_user(void)
{
    return strstr(rec.event_log,
                  "Initiating key re-exchange (at user request)") != NULL;
}
static bool restarted_log(void)
{
    return strstr(rec.event_log, "----- Session restarted -----") != NULL;
}

/* The listed entry called name: its index, or -1. */
static int find_special(const char *name)
{
    int found = -1;
    pthread_mutex_lock(&rec.lock);
    for (size_t i = 0; i < rec.n_specials && found < 0; i++)
        if (!strcmp(rec.specials[i].name, name))
            found = (int)i;
    pthread_mutex_unlock(&rec.lock);
    return found;
}

/* The terminal updates on PuTTY's own timer: poll the frames. */
static bool wait_frame(bool (*pred)(void), double timeout)
{
    double deadline = now_seconds() + timeout;
    while (now_seconds() < deadline) {
        read_frame();
        if (pred())
            return true;
        usleep(5000);
    }
    return false;
}

static bool scrollback_empty(void)
{
    return info.scroll_total == info.scroll_page;
}

static bool screen_cleared(void)
{
    return strstr(screen_text(), "line-60") == NULL;
}

static void query_close_warning(void)
{
    WITH_REC(rec.close_warnings = 0);
    spb_session_query_close_warning(session, 1);
    CHECK(wait_rec(close_warned, 10));
}

static void login_with_password(void)
{
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
}

static void test_session_operations(fixture *f)
{
    open_session(f->port, "tester", false);
    login_with_password();

    /* The Special Commands, as SSH-2 lists them: Break and the signals,
     * a submenu of more signals, then "Repeat key exchange" after a
     * separator. Closed submenus, and no trailing end marker. */
    CHECK(wait_rec(has_specials, 20));
    int brk = find_special("Break"), rekey = find_special("Repeat key exchange");
    int more = find_special("More signals");
    CHECK(brk >= 0 && rekey >= 0 && more >= 0);
    pthread_mutex_lock(&rec.lock);
    int depth = 0;
    bool separator = false;
    for (size_t i = 0; i < rec.n_specials; i++) {
        depth += rec.specials[i].kind == SPB_SPECIAL_SUBMENU;
        depth -= rec.specials[i].kind == SPB_SPECIAL_END_SUBMENU;
        CHECK(depth >= 0);
        separator |= rec.specials[i].kind == SPB_SPECIAL_SEPARATOR;
    }
    CHECK(depth == 0 && separator);
    CHECK(more >= 0 && rec.specials[more].kind == SPB_SPECIAL_SUBMENU);
    int32_t rekey_code = rekey >= 0 ? rec.specials[rekey].code : 0;
    int32_t rekey_arg = rekey >= 0 ? rec.specials[rekey].arg : 0;
    pthread_mutex_unlock(&rec.lock);

    /* Not listed: ignored. Then the listed rekey, on the same
     * connection. */
    uint64_t transport = spb_session_transport_id(session);
    spb_session_special(session, 0x7fff, 0);
    spb_session_special(session, rekey_code, rekey_arg);
    CHECK(wait_rec(rekeyed_by_user, 20));
    type("echo after-rekey-$((4*4))\r");
    CHECK(wait_screen("\nafter-rekey-16\n", 20));
    CHECK(spb_session_transport_id(session) == transport);

    /* Clear Scrollback: only the screen is left. */
    type("for i in $(seq 1 60); do echo line-$i; done\r");
    CHECK(wait_screen("\nline-60\n", 20));
    read_frame();
    CHECK(info.scroll_total > info.scroll_page);
    spb_session_clear_scrollback(session);
    CHECK(wait_frame(scrollback_empty, 10));

    /* Reset Terminal clears the screen (term_pwron with clear). */
    spb_session_reset_terminal(session);
    CHECK(wait_frame(screen_cleared, 10));
    type("echo reset-$((3*3))\r");
    CHECK(wait_screen("reset-9\n", 20));

    /* Connected: closing would end the session. No sharing, no extra
     * text. Restart is ignored while connected. */
    query_close_warning();
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.close_connected && rec.close_text[0] == 0);
    pthread_mutex_unlock(&rec.lock);
    spb_session_restart(session);
    CHECK(spb_core_barrier());
    CHECK(spb_session_transport_id(session) == transport);
    CHECK(!restarted_log());

    /* Closed: no specials, nothing to warn about. */
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    CHECK(wait_rec(no_specials, 10));
    query_close_warning();
    pthread_mutex_lock(&rec.lock);
    CHECK(!rec.close_connected);
    pthread_mutex_unlock(&rec.lock);
    spb_session_special(session, rekey_code, rekey_arg);  /* no backend */

    /* Restart Session: a new connection on the same session and
     * terminal, logged as upstream does. */
    spb_session_restart(session);
    CHECK(wait_rec(restarted_log, 10));
    login_with_password();
    CHECK(spb_session_transport_id(session) != transport);
    CHECK(wait_rec(has_specials, 20));
    type("echo again-$((7*6))\r");
    CHECK(wait_screen("\nagain-42\n", 20));

    /* Ended by the remote side, then restarted again. */
    type("exit\r");
    CHECK(wait_rec(is_final, 20));
    spb_session_reset_terminal(session);   /* forget the last prompt */
    CHECK(spb_core_barrier());
    spb_session_restart(session);
    login_with_password();
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
}

/* A failed connection can be restarted too, and fails again. */
static void test_restart_after_failure(void)
{
    int port;
    {
        /* A port with nothing listening. */
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = { .sin_family = AF_INET,
                                 .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        socklen_t len = sizeof(a);
        bind(fd, (struct sockaddr *)&a, sizeof(a));
        getsockname(fd, (struct sockaddr *)&a, &len);
        port = ntohs(a.sin_port);
        close(fd);
    }
    open_session(port, "tester", false);
    CHECK(wait_rec(is_final, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_FAILED);
    rec.state = SPB_SESSION_CREATED;
    pthread_mutex_unlock(&rec.lock);
    spb_session_restart(session);
    CHECK(wait_rec(is_final, 20));
    CHECK(restarted_log());
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_FAILED);
    pthread_mutex_unlock(&rec.lock);
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

/* ---------- Public-key authentication (M09) ---------- */

/* M12: "SSH to proxy and use port forwarding": a Raw session to a local
 * echo server, through uppity as the jump host (its host key is already
 * stored). The jump session's settings come from the frontend's saved
 * sessions (API v10): "Default Settings" when the proxy host is a host
 * name, or the saved session it names. */
static int jump_port;
static int lookups;

static spb_settings *saved_session(void *ctx, const char *name)
{
    lookups++;                         /* core thread only */
    bool is_default = !strcmp(name, "Default Settings");
    if (!is_default && strcmp(name, "jump-session"))
        return NULL;
    spb_settings *s = spb_settings_new_defaults();
    /* Password authentication only: no agent, GSSAPI or k-i. */
    spb_settings_set(s, "AuthKI", "0");
    spb_settings_set(s, "TryAgent", "0");
    spb_settings_set(s, "AuthGSSAPI", "0");
    spb_settings_set(s, "AuthGSSAPIKEX", "0");
    if (!is_default) {
        char port[16];
        snprintf(port, sizeof(port), "%d", jump_port);
        spb_settings_set(s, "HostName", "127.0.0.1");
        spb_settings_set(s, "PortNumber", port);
        spb_settings_set(s, "UserName", "tester");
    }
    return s;
}
static bool echoed_twice(void)
{
    const char *t = screen_text(), *first = strstr(t, "jump-hop");
    return first && strstr(first + 1, "jump-hop");
}

static void jump_once(const char *const *settings, bool password_prompt)
{
    echo_server echo;
    echo_start(&echo);
    open_session_with(echo.port, NULL, false, settings);
    if (password_prompt) {
        /* No stored password: asked in the terminal, for the proxy. */
        CHECK(wait_screen("tester@127.0.0.1's password:", 20));
        type("weasel\r");
    }
    CHECK(wait_rec(is_connected, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.prompts == 0);
    pthread_mutex_unlock(&rec.lock);
    CHECK(strstr(rec.event_log, "proxy: Using username \"tester\"") != NULL);
    /* Raw edits and echoes the line locally (Return sends it); the echo
     * server echoes it again. */
    type("jump-hop");
    spb_session_key(session, SPB_KEY_RETURN, 0);
    double deadline = now_seconds() + 20;
    while (!echoed_twice() && now_seconds() < deadline)
        usleep(5000);
    CHECK(echoed_twice());
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    echo_stop(&echo);
}

static void test_ssh_jump_proxy(fixture *f)
{
    jump_port = f->port;
    spb_core_set_saved_session_lookup(saved_session, NULL);
    char proxy_port[16];
    snprintf(proxy_port, sizeof(proxy_port), "%d", f->port);

    /* A host name: settings from "Default Settings", user name and
     * password from the proxy settings. */
    const char *const by_host[] = {
        "Protocol", "raw", "ProxyMethod", "6", "ProxyHost", "127.0.0.1",
        "ProxyPort", proxy_port, "ProxyLocalhost", "1",
        "ProxyUsername", "tester", "ProxyPassword", "weasel", NULL };
    jump_once(by_host, false);

    /* A saved session's name: its host, port and user name; no stored
     * password, so PuTTY asks for it. */
    const char *const by_session[] = {
        "Protocol", "raw", "ProxyMethod", "6", "ProxyHost", "jump-session",
        "ProxyLocalhost", "1", NULL };
    jump_once(by_session, true);

    CHECK(spb_core_barrier());
    CHECK(lookups >= 2);
    spb_core_set_saved_session_lookup(NULL, NULL);
}

/* M12: Connection/Data's environment variables reach the server (SSH
 * "env" requests); a comma in a value is escaped in the saved form. */
static void test_environment(fixture *f)
{
    const char *const env[] = {
        "Environment", "SPB_ONE=first value,SPB_TWO=a\\,b", NULL };
    open_session_with(f->port, "tester", false, env);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    type("echo \"<$SPB_ONE> <$SPB_TWO>\"\r");
    CHECK(wait_screen("\n<first value> <a,b>\n", 20));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
}

/* M13: a real Kerberos login (D-044). A Docker container runs an MIT KDC
 * for SWIFTPUTTY.TEST and an OpenSSH server with GSSAPI authentication
 * and key exchange (Core/tests/fixtures/kerberos). The test gets a ticket
 * with macOS's kinit into a credential cache of its own, under a
 * krb5.conf of its own (KRB5CCNAME, KRB5_CONFIG), then:
 *   1. GSSAPI key exchange and authentication: logged in, no password;
 *   2. GSSAPI authentication only (key exchange off): the same;
 *   3. no ticket: GSSAPI fails and the password is asked for.
 * Skipped, and says so, when Docker is not running. */
static bool has_prompt_or_connected(void)
{
    return rec.prompts > 0 || rec.state == SPB_SESSION_CONNECTED ||
           rec.state == SPB_SESSION_FAILED;
}

static bool log_has(const char *needle)
{
    pthread_mutex_lock(&rec.lock);
    bool found = strstr(rec.event_log, needle) != NULL;
    pthread_mutex_unlock(&rec.lock);
    return found;
}

static void kerberos_login(int port, bool kex, bool expect_gssapi)
{
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    /* By name: the service ticket is for host/localhost. */
    const char *const gss[] = { "HostName", "localhost", "AuthGSSAPI", "1",
                                "AuthGSSAPIKEX", kex ? "1" : "0", NULL };
    open_session_with(port, "tester", false, gss);
    /* Host key dialog for the first connection without key exchange. */
    CHECK(wait_rec(has_prompt_or_connected, 30) ||
          wait_screen("password:", 1));
    pthread_mutex_lock(&rec.lock);
    bool prompted = rec.prompts > 0;
    pthread_mutex_unlock(&rec.lock);
    if (prompted)
        answer(SPB_ANSWER_ACCEPT_AND_STORE);
    if (expect_gssapi) {
        CHECK(wait_rec(is_connected, 30));
        CHECK(strstr(screen_text(), "password:") == NULL);
        if (kex) {
            CHECK(log_has("Doing GSSAPI (with Kerberos V5)"));
            CHECK(log_has("GSSAPI Key Exchange complete!"));
            CHECK(log_has("Trying gssapi-keyex..."));
        } else {
            CHECK(!log_has("GSSAPI Key Exchange complete!"));
            CHECK(log_has("GSSAPI authentication loop finished OK"));
        }
    } else {
        CHECK(wait_screen("tester@localhost's password:", 30));
        type("weasel\r");
        CHECK(wait_rec(is_connected, 20));
        CHECK(!log_has("GSSAPI authentication loop finished OK"));
    }
    type("echo krb-$(id -un)\r");
    CHECK(wait_screen("krb-tester\n", 20));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    if (!expect_gssapi || getenv("SPB_KRB_VERBOSE")) {
        pthread_mutex_lock(&rec.lock);
        if (getenv("SPB_KRB_VERBOSE"))
            fprintf(stderr, "%s", rec.event_log);
        pthread_mutex_unlock(&rec.lock);
    }
    release_session();
}

/* The fixture is started, and KRB5_CONFIG / KRB5CCNAME set, before
 * anything in the process uses GSSAPI: Apple's Kerberos reads its
 * configuration once, when it is first used. */
static struct {
    bool up;
    char cid[128];
    int ssh_port, kdc_port;
    char conf[700], pw[700];
} krb;

static void kerberos_setup(void)
{
    char cmd[1200], line[256] = "";
    snprintf(cmd, sizeof(cmd), "'%s/kerberos/fixture.sh' start", SPB_FIXTURES_DIR);
    FILE *p = popen(cmd, "r");
    bool got = p && fgets(line, sizeof(line), p);
    int status = p ? pclose(p) : -1;
    if (!got || status != 0) {
        fprintf(stderr, "  Kerberos login test skipped: Docker is not "
                "available (fixture status %d)\n", status);
        return;
    }
    if (sscanf(line, "%127s %d %d", krb.cid, &krb.ssh_port, &krb.kdc_port) != 3) {
        fprintf(stderr, "  Kerberos fixture said \"%s\"\n", line);
        failures++;
        return;
    }
    char cache[700];
    snprintf(krb.conf, sizeof(krb.conf), "%s/krb5.conf", workdir);
    snprintf(cache, sizeof(cache), "FILE:%s/krb5cc", workdir);
    snprintf(krb.pw, sizeof(krb.pw), "%s/krb5pw", workdir);
    FILE *f = fopen(krb.conf, "w");
    fprintf(f, "[libdefaults]\n default_realm = SWIFTPUTTY.TEST\n"
            " dns_lookup_realm = false\n dns_lookup_kdc = false\n"
            " dns_canonicalize_hostname = false\n rdns = false\n"
            "[realms]\n SWIFTPUTTY.TEST = {\n  kdc = tcp/127.0.0.1:%d\n }\n"
            "[domain_realm]\n localhost = SWIFTPUTTY.TEST\n", krb.kdc_port);
    fclose(f);
    f = fopen(krb.pw, "w");
    fputs("kerberos-pw\n", f);
    fclose(f);
    /* This process only: the developer's own Kerberos setup and
     * tickets are never touched. */
    setenv("KRB5_CONFIG", krb.conf, 1);
    setenv("KRB5CCNAME", cache, 1);
    krb.up = true;
}

static void test_kerberos(void)
{
    if (!krb.up)
        return;
    char cmd[1200];
    snprintf(cmd, sizeof(cmd),
             "kinit --password-file='%s' tester@SWIFTPUTTY.TEST", krb.pw);
    CHECK(system(cmd) == 0);

    kerberos_login(krb.ssh_port, true, true);
    kerberos_login(krb.ssh_port, false, true);
    CHECK(system("kdestroy >/dev/null 2>&1") == 0);
    kerberos_login(krb.ssh_port, false, false);
}

static void kerberos_teardown(void)
{
    if (!krb.up)
        return;
    unlink(krb.pw);
    char cmd[1200];
    snprintf(cmd, sizeof(cmd), "'%s/kerberos/fixture.sh' stop %s",
             SPB_FIXTURES_DIR, krb.cid);
    if (system(cmd) != 0)
        fprintf(stderr, "  could not stop container %s\n", krb.cid);
}

/* M13: with GSSAPI on (PuTTY's defaults) and macOS's libraries now
 * loaded (patch 0021), a login to a server without GSSAPI still works
 * and is not held up by Kerberos. Timed against GSSAPI off. */
static void test_gssapi_defaults_do_not_delay(fixture *f)
{
    double took[2];
    for (int on = 0; on < 2; on++) {
        const char *const gss[] = { "AuthGSSAPI", on ? "1" : "0",
                                    "AuthGSSAPIKEX", on ? "1" : "0", NULL };
        double start = now_seconds();
        open_session_with(f->port, "tester", false, gss);
        CHECK(wait_screen("tester@127.0.0.1's password:", 30));
        took[on] = now_seconds() - start;
        type("weasel\r");
        CHECK(wait_rec(is_connected, 20));
        spb_session_close(session);
        CHECK(wait_rec(is_final, 10));
        release_session();
    }
    fprintf(stderr, "  to the password prompt: %.2f s without GSSAPI, "
            "%.2f s with it\n", took[0], took[1]);
    CHECK(took[1] < took[0] + 5);
}

/* M13: session logs never hold a password, whatever is logged
 * (CONF_logomitpass, on by default): printable output, all session
 * output, SSH packets, and SSH packets with raw data. A wrong password
 * and the right one are typed; neither may reach the file. */
static void test_logs_omit_passwords(fixture *f)
{
    /* The fifth run is the control: with "Omit known password fields"
     * off, the packet log does show the password, so the check can see
     * one. */
    static const char *const types[] = { "1", "2", "3", "4", "3" };
    for (size_t i = 0; i < 5; i++) {
        bool control = i == 4;
        char path[700];
        snprintf(path, sizeof(path), "%s/log-%zu.txt", workdir, i);
        const char *const logging[] = {
            "LogType", types[i], "LogFileName", path, "LogFileClash", "1",
            "LogFlush", "1", "SSHLogOmitPasswords", control ? "0" : "1", NULL };
        open_session_with(f->port, "tester", false, logging);
        CHECK(wait_screen("tester@127.0.0.1's password:", 20));
        type("Wrong-Secret-9\r");
        CHECK(wait_screen("Access denied\n", 20));
        type("weasel\r");
        CHECK(wait_rec(is_connected, 20));
        type("echo logged-$((3*3))\r");
        CHECK(wait_screen("\nlogged-9\n", 20));
        spb_session_close(session);
        CHECK(wait_rec(is_final, 10));
        release_session();

        FILE *fp = fopen(path, "rb");
        CHECK(fp != NULL);
        if (!fp)
            continue;
        static char log[1 << 20];
        size_t n = fread(log, 1, sizeof(log) - 1, fp);
        fclose(fp);
        log[n] = 0;
        /* The log is not empty, and for packet logs it has the request
         * that carried the password. */
        CHECK(memmem(log, n, "logged-9", 8) != NULL || types[i][0] >= '3');
        if (types[i][0] >= '3')
            CHECK(memmem(log, n, "SSH2_MSG_USERAUTH_REQUEST", 25) != NULL);
        /* Packet logs are hex dumps, 16 bytes a line, so a password can
         * be split between lines: look in the dumped bytes too. */
        static char bytes[1 << 20];
        size_t nb = 0;
        for (char *line = log; line && *line; ) {
            char *end = strchr(line, '\n');
            unsigned off;
            if (sscanf(line, "  %8x  ", &off) == 1 && line[10] == ' ') {
                for (int k = 0; k < 16; k++) {
                    unsigned b;
                    if (sscanf(line + 12 + 3 * k, "%2x", &b) != 1)
                        break;
                    bytes[nb++] = (char)b;
                }
            }
            line = end ? end + 1 : NULL;
        }
        bool leaked = memmem(log, n, "weasel", 6) ||
                      memmem(log, n, "Wrong-Secret-9", 14) ||
                      memmem(bytes, nb, "weasel", 6) ||
                      memmem(bytes, nb, "Wrong-Secret-9", 14);
        if (leaked != control) {
            fprintf(stderr, "  LogType %s%s: a password is %sin the log\n",
                    types[i], control ? " (not omitting)" : "",
                    leaked ? "" : "not ");
            failures++;
        }
        unlink(path);
    }
}

/* M12: connection sharing. A second session to the same server reuses
 * the first one's connection: no login, a sharing downstream (backend
 * cfg info -1), and the upstream's close warning names it. Sessions are
 * swapped with a second set of globals by hand: the record and terminal
 * helpers follow `session`. */
static bool is_exported_info(void) { return rec.exported != NULL; }

static void test_connection_sharing(fixture *f)
{
    const char *const share[] = { "ConnectionSharing", "1", NULL };
    open_session_with(f->port, "tester", false, share);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    type("weasel\r");
    CHECK(wait_rec(is_connected, 20));
    CHECK(strstr(rec.event_log, "Could not set up connection sharing") == NULL);
    spb_session *upstream = session;

    /* The downstream: the record is reset, but the upstream keeps
     * running (its callbacks keep landing in the same record). */
    open_session_with(f->port, "tester", false, share);
    spb_session *downstream = session;
    CHECK(wait_screen("Reusing a shared connection to this server.", 20));
    CHECK(wait_rec(is_connected, 20));
    type("echo shared-$((3*3))\r");
    CHECK(wait_screen("\nshared-9\n", 20));
    spb_session_export_settings(downstream, 1);
    CHECK(wait_rec(is_exported_info, 10));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.protocol_info == -1);
    spb_settings_free(rec.exported);
    rec.exported = NULL;
    pthread_mutex_unlock(&rec.lock);

    /* The upstream warns that closing it closes the downstream too. */
    session = upstream;
    query_close_warning();
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.close_connected);
    CHECK(!strcmp(rec.close_text, "This will also close 1 downstream connection."));
    pthread_mutex_unlock(&rec.lock);

    session = downstream;
    spb_session_close(downstream);
    spb_session_release(downstream);
    session = upstream;
    spb_session_close(upstream);
    CHECK(wait_rec(is_final, 10));
    release_session();
    CHECK(spb_core_barrier());
}

/* M12: manually configured host keys. A fresh server (its key not
 * cached): a listed fingerprint is accepted with no dialog and nothing
 * stored; an unlisted key fails. Also the canonical form "Add key"
 * stores. */
static void test_manual_host_keys(void)
{
    static const char fp[] = "SHA256:ADly5k1O7s2C72nWl2ReSxP+HnNPcmTIGAcWJE/gMmg";
    char *canon = spb_canonical_manual_host_key(
        "127.0.0.1 ssh-ed25519 255 SHA256:ADly5k1O7s2C72nWl2ReSxP+HnNPcmTIGAcWJE/gMmg");
    CHECK(canon && !strcmp(canon, fp));
    spb_string_free(canon);
    canon = spb_canonical_manual_host_key(
        "MD5:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99");
    CHECK(canon && !strcmp(canon, "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"));
    spb_string_free(canon);
    CHECK(spb_canonical_manual_host_key("not a key") == NULL);

    fixture fresh = fixture_start("hostkey-a.ppk", 0);
    const char *const listed[] = { "SSHManualHostKeys", fp, NULL };
    open_session_with(fresh.port, "tester", false, listed);
    CHECK(wait_screen("tester@127.0.0.1's password:", 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.prompts == 0);                       /* no host key dialog */
    pthread_mutex_unlock(&rec.lock);
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();

    const char *const other[] = {
        "SSHManualHostKeys", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", NULL };
    open_session_with(fresh.port, "tester", false, other);
    CHECK(wait_rec(is_final, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_FAILED);
    CHECK(strstr(rec.detail, "Host key not in manually configured list") != NULL);
    CHECK(rec.prompts == 0);
    pthread_mutex_unlock(&rec.lock);
    release_session();

    /* Nothing was stored: without the list, PuTTY asks. */
    open_session(fresh.port, "tester", false);
    CHECK(wait_rec(has_prompt, 20));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    fixture_stop(&fresh);
}

/* M12: the trusted host CA store, with upstream's dialog rules. */
static void test_host_cas(void)
{
    char path[700], text[2048];
    snprintf(path, sizeof(path), "%s/userkey.pub", SPB_FIXTURES_DIR);
    FILE *fp = fopen(path, "r");
    size_t n = fp ? fread(text, 1, sizeof(text) - 1, fp) : 0;
    text[n] = '\0';
    if (fp)
        fclose(fp);

    size_t count;
    char **names = spb_host_ca_names(&count);
    CHECK(count == 0);
    spb_strings_free(names, count);

    /* The key: a public key file's text, shown by its fingerprint. */
    char *blob = NULL, *info = spb_host_ca_key_info(text, &blob);
    CHECK(info && !strncmp(info, "ssh-ed25519 255 SHA256:", 23));
    CHECK(blob && !strncmp(blob, "AAAAC3NzaC1lZDI1NTE5", 20));
    spb_string_free(info);
    info = spb_host_ca_key_info("not a key!", NULL);
    CHECK(info && !strncmp(info, "Cannot decode key", 17));
    spb_string_free(info);
    /* An Ed25519 key whose point is one byte long: refused, not an
     * assertion failure (patch 0017; found by fuzzing). */
    info = spb_host_ca_key_info("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAAQA=", NULL);
    CHECK(info && strncmp(info, "ssh-ed25519 255 SHA256:", 23) != 0);
    spb_string_free(info);

    spb_host_ca *ca = spb_host_ca_new_default();
    CHECK(ca && !ca->permit_rsa_sha1 && ca->permit_rsa_sha256 && ca->permit_rsa_sha512);
    free(ca->name);
    ca->name = strdup("Test CA");
    free(ca->public_key);
    ca->public_key = strdup(text);

    /* Upstream's checks, in its order. */
    size_t off, len;
    char *err = spb_host_ca_save(ca, &off, &len);
    CHECK(err && !strcmp(err, "No validity expression configured for this key"));
    spb_string_free(err);
    free(ca->validity);
    ca->validity = strdup("*.example.org &&");
    err = spb_host_ca_save(ca, &off, &len);
    CHECK(err && !strncmp(err, "Error in expression: ", 21));
    CHECK(off != SIZE_MAX && off <= strlen(ca->validity));
    spb_string_free(err);
    free(ca->validity);
    ca->validity = strdup("*.example.org || port:2222");
    free(ca->public_key);
    ca->public_key = strdup("garbage");
    err = spb_host_ca_save(ca, NULL, NULL);
    CHECK(err && !strcmp(err, "No valid CA public key entered"));
    spb_string_free(err);
    free(ca->public_key);
    ca->public_key = strdup(text);
    ca->permit_rsa_sha1 = true;
    CHECK(spb_host_ca_save(ca, NULL, NULL) == NULL);
    spb_host_ca_free(ca);

    names = spb_host_ca_names(&count);
    CHECK(count == 1 && !strcmp(names[0], "Test CA"));
    spb_strings_free(names, count);
    ca = spb_host_ca_load("Test CA");
    CHECK(ca && !strcmp(ca->public_key, blob));       /* stored as a blob */
    CHECK(ca && !strcmp(ca->validity, "*.example.org || port:2222"));
    CHECK(ca && ca->permit_rsa_sha1);
    spb_host_ca_free(ca);
    CHECK(spb_host_ca_load("No such CA") == NULL);

    CHECK(spb_host_ca_delete("Test CA") == NULL);
    names = spb_host_ca_names(&count);
    CHECK(count == 0);
    spb_strings_free(names, count);
    spb_string_free(blob);
}

/* M12: authentication through an SSH agent (the system ssh-agent at
 * SSH_AUTH_SOCK, as PuTTY's Unix code uses it), and agent forwarding:
 * the remote shell lists the agent's key through the forwarded agent. */
static void test_agent(void)
{
    char dir[600], sock[700], key[700], cmd[2048], pub[700], src[700];
    snprintf(dir, sizeof(dir), "%s/agent", workdir);
    snprintf(sock, sizeof(sock), "%s/s", dir);
    snprintf(key, sizeof(key), "%s/userkey", dir);
    snprintf(src, sizeof(src), "%s/userkey.openssh", SPB_FIXTURES_DIR);
    snprintf(pub, sizeof(pub), "%s/userkey.pub", SPB_FIXTURES_DIR);
    /* ssh-add refuses a key others can read; git does not keep modes. */
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s' && cp '%s' '%s' && chmod 600 '%s'",
             dir, src, key, key);
    CHECK(system(cmd) == 0);

    snprintf(cmd, sizeof(cmd), "ssh-agent -a '%s'", sock);
    FILE *out = popen(cmd, "r");
    int agent_pid = 0;
    char line[512];
    while (out && fgets(line, sizeof(line), out))
        if (strstr(line, "SSH_AGENT_PID="))
            agent_pid = atoi(strstr(line, "SSH_AGENT_PID=") + 14);
    if (out)
        pclose(out);
    CHECK(agent_pid > 0);
    snprintf(cmd, sizeof(cmd), "SSH_AUTH_SOCK='%s' ssh-add -q '%s' 2>/dev/null",
             sock, key);
    CHECK(system(cmd) == 0);
    char *old_sock = getenv("SSH_AUTH_SOCK") ? strdup(getenv("SSH_AUTH_SOCK")) : NULL;
    setenv("SSH_AUTH_SOCK", sock, 1);

    /* A server that only accepts the key. */
    const char *const opts[] = {
        "--userkey", pub, "--deny-auth", "password",
        "--deny-auth", "keyboard-interactive", NULL };
    fixture keyed = fixture_start_with("hostkey-a.ppk", 0, opts);
    const char *const use_agent[] = { "TryAgent", "1", "AgentFwd", "1", NULL };
    open_session_with(keyed.port, "tester", false, use_agent);
    CHECK(wait_rec(has_prompt, 20));           /* a new port: host key */
    answer(SPB_ANSWER_ACCEPT_ONCE);
    CHECK(wait_rec(is_connected, 20));
    CHECK(strstr(rec.event_log, "Pageant has 1 SSH-2 keys") != NULL);
    CHECK(wait_screen("Authenticating with public key \"SwiftPutty test user key", 20));
    CHECK(wait_screen("\" from agent", 20));

    /* Forwarded: the remote side sees the same key. */
    type("ssh-add -l\r");
    CHECK(wait_screen("256 SHA256:KPyQwdntNVnuUdA0ck24gH8/uII7Oamqccky7fdsN0c", 20));
    CHECK(wait_screen("not secret (ED25519)", 20));
    CHECK(strstr(rec.event_log, "Agent forwarding enabled") != NULL);
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();
    fixture_stop(&keyed);

    if (old_sock) {
        setenv("SSH_AUTH_SOCK", old_sock, 1);
        free(old_sock);
    } else {
        unsetenv("SSH_AUTH_SOCK");
    }
    if (agent_pid > 0)
        kill(agent_pid, SIGTERM);
}

static void test_public_key_auth(void)
{
    char pub[700], key[700], secret_key[700];
    snprintf(pub, sizeof(pub), "%s/userkey.pub", SPB_FIXTURES_DIR);
    snprintf(key, sizeof(key), "%s/userkey.ppk", SPB_FIXTURES_DIR);
    snprintf(secret_key, sizeof(secret_key), "%s/userkey-secret.ppk",
             SPB_FIXTURES_DIR);
    /* A server that only accepts this key, and shows a banner. */
    const char *const opts[] = {
        "--userkey", pub, "--deny-auth", "password",
        "--deny-auth", "keyboard-interactive",
        "--bannertext", "Welcome to the key-only test server\n", NULL };
    fixture keyed = fixture_start_with("hostkey-a.ppk", 0, opts);

    /* An unencrypted key: logged in with no prompt at all. */
    const char *const with_key[] = { "PublicKeyFile", key, NULL };
    open_session_with(keyed.port, "tester", false, with_key);
    CHECK(wait_rec(has_prompt, 20));       /* a new port: unknown host key */
    answer(SPB_ANSWER_ACCEPT_AND_STORE);
    CHECK(wait_screen("Authenticating with public key \"SwiftPutty test user key (userkey)", 20));
    CHECK(wait_screen("Welcome to the key-only test server", 20));  /* banner */
    CHECK(wait_rec(is_connected, 20));
    type("echo key-$((2*21))\r");
    CHECK(wait_screen("\nkey-42\n", 20));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();

    /* An encrypted key: PuTTY asks for the passphrase in the terminal;
     * a wrong one is asked again. */
    const char *const with_secret[] = { "PublicKeyFile", secret_key,
                                        "SshBanner", "0", NULL };
    open_session_with(keyed.port, "tester", false, with_secret);
    CHECK(wait_screen("Passphrase for key \"SwiftPutty test user key (passphrase 'secret')", 20));
    /* Each try runs Argon2 over several MiB, which ThreadSanitizer slows
     * enough that 20 seconds was not always enough on a loaded host. */
    type("wrong\r");
    CHECK(wait_screen("Wrong passphrase", 90));
    type("secret\r");
    CHECK(wait_rec(is_connected, 90));
    CHECK(strstr(screen_text(), "Welcome to the key-only") == NULL); /* banner off */
    CHECK(strstr(screen_text(), "secret") == NULL || strstr(screen_text(), "'secret'"));
    spb_session_close(session);
    CHECK(wait_rec(is_final, 10));
    release_session();

    /* No key, and nothing else allowed: the server refuses. */
    open_session(keyed.port, "tester", false);
    CHECK(wait_rec(is_final, 20));
    pthread_mutex_lock(&rec.lock);
    CHECK(rec.state == SPB_SESSION_FAILED);
    CHECK(strstr(rec.detail, "No supported authentication methods") != NULL);
    pthread_mutex_unlock(&rec.lock);
    release_session();

    fixture_stop(&keyed);
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
    kerberos_setup();

    char *err = NULL;
    spb_core_options opts = { .state_dir = state_dir };
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "init: %s\n", err);
        return 2;
    }

#define RUN_TEST(call) do {                                           \
        fprintf(stderr, "running %s\n", #call);                       \
        call;                                                         \
    } while (0)

    fixture server = fixture_start("hostkey-a.ppk", 0);
    RUN_TEST(test_first_connection(&server));
    RUN_TEST(test_stored_key_and_wrong_password(&server));
    RUN_TEST(test_live_reconfigure(&server));
    RUN_TEST(test_port_forwarding(&server));
    RUN_TEST(test_session_operations(&server));
    RUN_TEST(test_ssh_jump_proxy(&server));
    RUN_TEST(test_environment(&server));
    RUN_TEST(test_logs_omit_passwords(&server));
    RUN_TEST(test_gssapi_defaults_do_not_delay(&server));
    RUN_TEST(test_connection_sharing(&server));
    RUN_TEST(test_manual_host_keys());
    RUN_TEST(test_host_cas());
    RUN_TEST(test_agent());
    RUN_TEST(test_restart_after_failure());
    RUN_TEST(test_accept_once_and_cancel());
    RUN_TEST(test_changed_host_key(&server));
    RUN_TEST(test_public_key_auth());
    RUN_TEST(test_kerberos());
    RUN_TEST(kerberos_teardown());

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
