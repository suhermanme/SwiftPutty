/*
 * C-level tests for SSH sessions (M04), against upstream's test server
 * uppity run by spb_ssh_fixture on 127.0.0.1: host key confirmation
 * (accept and store, accept once, cancel, changed key), login prompts in
 * the terminal (user name, password, wrong password), shell input and
 * output, terminal size, exit status, and closing with a prompt pending.
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success.
 */

#include <errno.h>
#include <pthread.h>
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

static fixture fixture_start(const char *hostkey, int port)
{
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
            execl(SPB_SSH_FIXTURE, SPB_SSH_FIXTURE, SPB_UPPITY, key, workdir,
                  "--port", portstr, (char *)NULL);
        else
            execl(SPB_SSH_FIXTURE, SPB_SSH_FIXTURE, SPB_UPPITY, key, workdir,
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

static const spb_session_callbacks callbacks = {
    .state_changed = cb_state,
    .remote_exit = cb_exit,
    .released = cb_released,
    .prompt = cb_prompt,
    .prompt_cancelled = cb_prompt_cancelled,
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
