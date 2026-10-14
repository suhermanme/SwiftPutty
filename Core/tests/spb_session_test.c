/*
 * C-level tests for the PuTTY core thread and the session executor (M02):
 * timers, command ordering, Raw sessions against a local TCP server,
 * failure paths, release semantics, concurrency and shutdown. Also the
 * session log and its "file exists" question (M05).
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success. Run
 * plain, under `leaks --atExit`, and under ASan/UBSan and TSan by
 * scripts/build-core.sh.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "PuTTYBridge.h"

static atomic_int failures;

#define CHECK(cond) do {                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n",                \
                    __FILE__, __LINE__, #cond);                         \
            atomic_fetch_add(&failures, 1);                             \
        }                                                               \
    } while (0)

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------- A local TCP server ---------- */

typedef enum {
    SERVER_ECHO,          /* echo until the client closes */
    SERVER_GREET_CLOSE,   /* send "bye\n", then close */
} server_mode;

typedef struct server {
    int listen_fd;
    int port;
    server_mode mode;
    pthread_t thread;
} server;

static void *server_conn_main(void *arg)
{
    int fd = (int)(intptr_t)arg;
    char buf[65536];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        for (ssize_t off = 0; off < n; ) {
            ssize_t w = write(fd, buf + off, n - off);
            if (w <= 0)
                goto out;
            off += w;
        }
    }
  out:
    close(fd);
    return NULL;
}

static void *server_main(void *arg)
{
    server *srv = arg;
    for (;;) {
        int fd = accept(srv->listen_fd, NULL, NULL);
        if (fd < 0)
            return NULL;               /* listener closed: stop */
        if (srv->mode == SERVER_GREET_CLOSE) {
            ssize_t w = write(fd, "bye\n", 4);
            (void)w;
            close(fd);
            continue;
        }
        pthread_t t;
        pthread_create(&t, NULL, server_conn_main, (void *)(intptr_t)fd);
        pthread_detach(t);
    }
}

static int listen_on_loopback(int *port_out)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        listen(fd, 256) < 0) {
        perror("bind/listen");
        exit(2);
    }
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    *port_out = ntohs(addr.sin_port);
    return fd;
}

static void server_start(server *srv, server_mode mode)
{
    srv->mode = mode;
    srv->listen_fd = listen_on_loopback(&srv->port);
    pthread_create(&srv->thread, NULL, server_main, srv);
}

static void server_stop(server *srv)
{
    shutdown(srv->listen_fd, SHUT_RDWR);
    close(srv->listen_fd);
    pthread_join(srv->thread, NULL);
}

/* A port with nothing listening on it. */
static int unused_port(void)
{
    int port;
    int fd = listen_on_loopback(&port);
    close(fd);
    return port;
}

/* ---------- Recording callbacks ---------- */

typedef struct recorder {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    spb_session_state states[8];
    int nstates;
    char *last_detail;
    char *output;
    size_t output_len, output_cap;
    int event_log_lines;
    char *event_log_text;              /* all lines, '\n'-terminated */
    int prompts;
    spb_prompt_kind prompt_kind;
    uint64_t prompt_id;
    char *prompt_title;
    char *prompt_paragraph;
    int prompts_cancelled;
    spb_settings *exported;            /* last settings_exported */
    uint64_t exported_request;
    int32_t protocol_info;
    int reconfigured;
    uint64_t reconfigured_request;
    bool got_exit;
    int32_t exit_code;
    bool released;
    int callbacks_after_release;       /* callbacks after `released` */
    int callbacks_off_core_thread;
} recorder;

static void rec_init(recorder *r)
{
    memset(r, 0, sizeof(*r));
    pthread_mutex_init(&r->lock, NULL);
    pthread_cond_init(&r->cond, NULL);
}

static void rec_destroy(recorder *r)
{
    free(r->last_detail);
    free(r->output);
    free(r->event_log_text);
    free(r->prompt_title);
    free(r->prompt_paragraph);
    spb_settings_free(r->exported);
    pthread_cond_destroy(&r->cond);
    pthread_mutex_destroy(&r->lock);
}

static void rec_enter(recorder *r)
{
    pthread_mutex_lock(&r->lock);
    if (!spb_core_is_core_thread())
        r->callbacks_off_core_thread++;
    if (r->released)
        r->callbacks_after_release++;
}

static void rec_leave(recorder *r)
{
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->lock);
}

static void cb_state(void *ctx, spb_session_state state, const char *detail)
{
    recorder *r = ctx;
    rec_enter(r);
    if (r->nstates < 8)
        r->states[r->nstates++] = state;
    free(r->last_detail);
    r->last_detail = detail ? strdup(detail) : NULL;
    rec_leave(r);
}

static void cb_event_log(void *ctx, const char *line)
{
    recorder *r = ctx;
    rec_enter(r);
    r->event_log_lines++;
    size_t old = r->event_log_text ? strlen(r->event_log_text) : 0;
    r->event_log_text = realloc(r->event_log_text, old + strlen(line) + 2);
    strcpy(r->event_log_text + old, line);
    strcat(r->event_log_text + old, "\n");
    rec_leave(r);
}

static void cb_output(void *ctx, const void *data, size_t len,
                      bool is_stderr)
{
    recorder *r = ctx;
    rec_enter(r);
    if (r->output_len + len + 1 > r->output_cap) {
        r->output_cap = (r->output_len + len + 1) * 2;
        r->output = realloc(r->output, r->output_cap);
    }
    memcpy(r->output + r->output_len, data, len);
    r->output_len += len;
    r->output[r->output_len] = '\0';
    rec_leave(r);
}

static void cb_remote_exit(void *ctx, int32_t code)
{
    recorder *r = ctx;
    rec_enter(r);
    r->got_exit = true;
    r->exit_code = code;
    rec_leave(r);
}

static void cb_released(void *ctx)
{
    recorder *r = ctx;
    rec_enter(r);
    r->released = true;
    rec_leave(r);
}

static void cb_prompt(void *ctx, const spb_prompt *prompt)
{
    recorder *r = ctx;
    rec_enter(r);
    r->prompts++;
    r->prompt_kind = prompt->kind;
    r->prompt_id = prompt->id;
    free(r->prompt_title);
    free(r->prompt_paragraph);
    r->prompt_title = r->prompt_paragraph = NULL;
    for (size_t i = 0; i < prompt->n_items; i++) {
        if (prompt->items[i].type == SPB_DIALOG_TITLE && !r->prompt_title)
            r->prompt_title = strdup(prompt->items[i].text);
        if (prompt->items[i].type == SPB_DIALOG_PARAGRAPH &&
            !r->prompt_paragraph)
            r->prompt_paragraph = strdup(prompt->items[i].text);
    }
    rec_leave(r);
}

static void cb_prompt_cancelled(void *ctx, uint64_t id)
{
    recorder *r = ctx;
    rec_enter(r);
    r->prompts_cancelled++;
    rec_leave(r);
}

static void cb_exported(void *ctx, uint64_t request, spb_settings *settings,
                        int32_t info)
{
    recorder *r = ctx;
    rec_enter(r);
    spb_settings_free(r->exported);
    r->exported = settings;
    r->exported_request = request;
    r->protocol_info = info;
    rec_leave(r);
}

static void cb_reconfigured(void *ctx, uint64_t request, const char *error)
{
    recorder *r = ctx;
    rec_enter(r);
    if (!error)
        r->reconfigured++;
    r->reconfigured_request = request;
    rec_leave(r);
}

static const spb_session_callbacks recording_callbacks = {
    .state_changed = cb_state,
    .event_log = cb_event_log,
    .output = cb_output,
    .remote_exit = cb_remote_exit,
    .released = cb_released,
    .prompt = cb_prompt,
    .prompt_cancelled = cb_prompt_cancelled,
    .settings_exported = cb_exported,
    .reconfigured = cb_reconfigured,
};

typedef bool (*rec_pred)(recorder *r, const void *arg);

/* Wait (up to timeout seconds) for pred; returns whether it held. */
static bool rec_wait(recorder *r, rec_pred pred, const void *arg,
                     double timeout)
{
    double deadline = now_seconds() + timeout;
    pthread_mutex_lock(&r->lock);
    bool ok;
    while (!(ok = pred(r, arg))) {
        double left = deadline - now_seconds();
        if (left <= 0)
            break;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        double abs_t = tv.tv_sec + tv.tv_usec / 1e6 + left;
        struct timespec ts = { .tv_sec = (time_t)abs_t,
                               .tv_nsec = (long)((abs_t - (time_t)abs_t) * 1e9) };
        pthread_cond_timedwait(&r->cond, &r->lock, &ts);
    }
    pthread_mutex_unlock(&r->lock);
    return ok;
}

static bool pred_state(recorder *r, const void *arg)
{
    spb_session_state want = *(const spb_session_state *)arg;
    for (int i = 0; i < r->nstates; i++)
        if (r->states[i] == want)
            return true;
    return false;
}

static bool pred_output_len(recorder *r, const void *arg)
{
    return r->output_len >= *(const size_t *)arg;
}

static bool pred_released(recorder *r, const void *arg)
{
    return r->released;
}

static bool pred_exported(recorder *r, const void *arg)
{
    return r->exported && r->exported_request == *(const uint64_t *)arg;
}

static bool pred_reconfigured(recorder *r, const void *arg)
{
    return r->reconfigured >= *(const int *)arg;
}

static bool pred_prompted(recorder *r, const void *arg)
{
    return r->prompts > 0;
}

static bool wait_state(recorder *r, spb_session_state state, double timeout)
{
    return rec_wait(r, pred_state, &state, timeout);
}

static bool wait_output(recorder *r, size_t len, double timeout)
{
    return rec_wait(r, pred_output_len, &len, timeout);
}

static spb_settings *raw_settings(const char *host, int port)
{
    spb_settings *s = spb_settings_new_defaults();
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    spb_settings_set(s, "Protocol", "raw");
    spb_settings_set(s, "HostName", host);
    spb_settings_set(s, "PortNumber", portstr);
    return s;
}

static spb_session *new_session(spb_settings *settings, recorder *r)
{
    char *err = NULL;
    spb_session *s = spb_session_create(settings, &recording_callbacks, r,
                                        &err);
    CHECK(s != NULL);
    CHECK(err == NULL);
    spb_string_free(err);
    return s;
}

/* ---------- Core thread and timers ---------- */

typedef struct timer_probe {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    int order[4];
    double fired_at[4];
    int fired;
    bool off_core_thread;
} timer_probe;

typedef struct timer_arg {
    timer_probe *probe;
    int index;
} timer_arg;

static void timer_fired(void *ctx)
{
    timer_arg *a = ctx;
    pthread_mutex_lock(&a->probe->lock);
    if (!spb_core_is_core_thread())
        a->probe->off_core_thread = true;
    a->probe->fired_at[a->index] = now_seconds();
    a->probe->order[a->probe->fired++] = a->index;
    pthread_cond_broadcast(&a->probe->cond);
    pthread_mutex_unlock(&a->probe->lock);
}

static void test_core_thread_and_timers(void)
{
    CHECK(!spb_core_is_core_thread());
    /* A barrier returns while its iteration is still running; a second
     * one runs in a later iteration, so the first has been counted. */
    uint64_t before = spb_debug_loop_iterations();
    CHECK(spb_core_barrier());
    CHECK(spb_core_barrier());
    CHECK(spb_debug_loop_iterations() > before);

    /* Idle: the loop blocks in poll() rather than spinning. */
    CHECK(spb_core_barrier());
    uint64_t idle_start = spb_debug_loop_iterations();
    usleep(200 * 1000);
    CHECK(spb_debug_loop_iterations() - idle_start <= 2);

    timer_probe probe = { .fired = 0 };
    pthread_mutex_init(&probe.lock, NULL);
    pthread_cond_init(&probe.cond, NULL);
    timer_arg args[3] = { { &probe, 0 }, { &probe, 1 }, { &probe, 2 } };

    double start = now_seconds();
    spb_debug_after_delay(300, timer_fired, &args[0]);
    spb_debug_after_delay(100, timer_fired, &args[1]);
    spb_debug_after_delay(0, timer_fired, &args[2]);

    pthread_mutex_lock(&probe.lock);
    while (probe.fired < 3) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 5;
        if (pthread_cond_timedwait(&probe.cond, &probe.lock, &ts))
            break;
    }
    pthread_mutex_unlock(&probe.lock);

    CHECK(probe.fired == 3);
    CHECK(!probe.off_core_thread);
    CHECK(probe.order[0] == 2 && probe.order[1] == 1 && probe.order[2] == 0);
    /* Never early (allowing for tick granularity); not grossly late. */
    CHECK(probe.fired_at[1] - start >= 0.095);
    CHECK(probe.fired_at[0] - start >= 0.295);
    CHECK(probe.fired_at[0] - start < 2.0);

    pthread_cond_destroy(&probe.cond);
    pthread_mutex_destroy(&probe.lock);
}

/* ---------- Raw sessions ---------- */

static void test_raw_echo(server *echo)
{
    size_t fds_before = spb_debug_uxsel_fds();
    recorder r;
    rec_init(&r);
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);

    /* Input before connection is buffered by the backend, as in PuTTY. */
    spb_session_start(s);
    spb_session_send(s, "early ", 6);
    CHECK(wait_state(&r, SPB_SESSION_CONNECTED, 10));
    spb_session_send(s, "hello\n", 6);
    CHECK(wait_output(&r, 12, 10));
    pthread_mutex_lock(&r.lock);
    CHECK(r.output && !strcmp(r.output, "early hello\n"));
    CHECK(r.nstates == 2);
    CHECK(r.states[0] == SPB_SESSION_CONNECTING);
    CHECK(r.states[1] == SPB_SESSION_CONNECTED);
    CHECK(r.event_log_lines >= 2);     /* "Looking up host", "Connected to" */
    pthread_mutex_unlock(&r.lock);

    CHECK(spb_core_barrier());
    CHECK(spb_debug_uxsel_fds() == fds_before + 1);

    spb_session_close(s);
    CHECK(wait_state(&r, SPB_SESSION_CLOSED, 10));
    pthread_mutex_lock(&r.lock);
    CHECK(r.last_detail && strstr(r.last_detail, "closed by user"));
    CHECK(!r.got_exit);
    pthread_mutex_unlock(&r.lock);

    /* Input after close is ignored. */
    spb_session_send(s, "ignored", 7);
    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    CHECK(spb_core_barrier());
    CHECK(spb_debug_uxsel_fds() == fds_before);
    CHECK(r.callbacks_after_release == 0);
    CHECK(r.callbacks_off_core_thread == 0);
    rec_destroy(&r);
}

static void test_large_transfer(server *echo)
{
    enum { SIZE = 4 << 20 };
    unsigned char *payload = malloc(SIZE);
    /* Printable text: the terminal answers some control sequences, and
     * the echoed answers would add to the output. */
    for (size_t i = 0; i < SIZE; i++)
        payload[i] = (i % 80 == 79) ? '\n' :
            (unsigned char)('!' + (i * 2654435761u >> 13) % 94);

    recorder r;
    rec_init(&r);
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_CONNECTED, 10));
    for (size_t off = 0; off < SIZE; off += 100000)
        spb_session_send(s, payload + off,
                         off + 100000 <= SIZE ? 100000 : SIZE - off);
    CHECK(wait_output(&r, SIZE, 60));
    pthread_mutex_lock(&r.lock);
    CHECK(r.output_len == SIZE);
    CHECK(r.output && !memcmp(r.output, payload, SIZE));
    pthread_mutex_unlock(&r.lock);

    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    rec_destroy(&r);
    free(payload);
}

static void test_remote_close(void)
{
    server srv;
    server_start(&srv, SERVER_GREET_CLOSE);

    recorder r;
    rec_init(&r);
    spb_settings *settings = raw_settings("127.0.0.1", srv.port);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_CLOSED, 10));
    pthread_mutex_lock(&r.lock);
    CHECK(r.output && !strcmp(r.output, "bye\n"));
    CHECK(r.got_exit && r.exit_code == 0);
    CHECK(r.last_detail && strstr(r.last_detail, "remote host"));
    CHECK(r.states[r.nstates - 1] == SPB_SESSION_CLOSED);
    pthread_mutex_unlock(&r.lock);

    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    CHECK(r.callbacks_after_release == 0);
    rec_destroy(&r);
    server_stop(&srv);
}

static void expect_failure(spb_settings *settings, const char *needle,
                           bool expect_connecting)
{
    recorder r;
    rec_init(&r);
    spb_session *s = new_session(settings, &r);
    spb_session_start(s);
    spb_session_start(s);              /* a second start is ignored */
    CHECK(wait_state(&r, SPB_SESSION_FAILED, 30));
    spb_session_send(s, "x", 1);       /* ignored */
    spb_session_close(s);              /* no state change after FAILED */
    CHECK(spb_core_barrier());
    pthread_mutex_lock(&r.lock);
    CHECK(r.last_detail && strstr(r.last_detail, needle));
    if (!(r.last_detail && strstr(r.last_detail, needle)))
        fprintf(stderr, "  expected \"%s\", detail was: %s\n", needle,
                r.last_detail ? r.last_detail : "(null)");
    CHECK(r.states[r.nstates - 1] == SPB_SESSION_FAILED);
    CHECK((r.states[0] == SPB_SESSION_CONNECTING) == expect_connecting);
    CHECK(!pred_state(&r, &(spb_session_state){ SPB_SESSION_CONNECTED }));
    CHECK(!pred_state(&r, &(spb_session_state){ SPB_SESSION_CLOSED }));
    pthread_mutex_unlock(&r.lock);
    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    rec_destroy(&r);
}

static void test_failures(void)
{
    spb_settings *refused = raw_settings("127.0.0.1", unused_port());
    expect_failure(refused, "refused", true);
    spb_settings_free(refused);

    spb_settings *nxdomain = raw_settings("no-such-host.invalid", 9);
    expect_failure(nxdomain, "Unable to open connection", true);
    spb_settings_free(nxdomain);

    spb_settings *telnet = raw_settings("127.0.0.1", 23);
    spb_settings_set(telnet, "Protocol", "telnet");
    expect_failure(telnet, "M11", false);
    spb_settings_free(telnet);
}

static void test_release_paths(server *echo)
{
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);

    /* Never started. */
    for (int i = 0; i < 1000; i++) {
        recorder r;
        rec_init(&r);
        spb_session *s = new_session(settings, &r);
        spb_session_release(s);
        CHECK(rec_wait(&r, pred_released, NULL, 10));
        CHECK(r.nstates == 0);
        CHECK(r.callbacks_after_release == 0);
        rec_destroy(&r);
    }

    /* Released while connecting, and while connected with traffic in
     * flight: `released` still comes last. */
    for (int i = 0; i < 200; i++) {
        recorder r;
        rec_init(&r);
        spb_session *s = new_session(settings, &r);
        spb_session_start(s);
        if (i % 2) {
            wait_state(&r, SPB_SESSION_CONNECTED, 10);
            spb_session_send(s, "ping\n", 5);
        }
        spb_session_release(s);
        CHECK(rec_wait(&r, pred_released, NULL, 10));
        CHECK(spb_core_barrier());
        CHECK(r.callbacks_after_release == 0);
        rec_destroy(&r);
    }

    /* No callbacks at all. */
    spb_session *quiet = spb_session_create(settings, NULL, NULL, NULL);
    spb_session_start(quiet);
    spb_session_send(quiet, "x", 1);
    spb_session_release(quiet);

    spb_settings_free(settings);
    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);
}

typedef struct worker_arg {
    int port;
    int index;
    int sessions;
} worker_arg;

static void *concurrent_worker(void *varg)
{
    worker_arg *a = varg;
    spb_settings *settings = raw_settings("127.0.0.1", a->port);
    enum { MAX = 32 };
    recorder recs[MAX];
    spb_session *sessions[MAX];
    char expected[MAX][64];

    for (int i = 0; i < a->sessions; i++) {
        rec_init(&recs[i]);
        sessions[i] = new_session(settings, &recs[i]);
        spb_session_start(sessions[i]);
        snprintf(expected[i], sizeof(expected[i]),
                 "worker %d session %d payload\n", a->index, i);
        spb_session_send(sessions[i], expected[i], strlen(expected[i]));
    }
    for (int i = 0; i < a->sessions; i++) {
        CHECK(wait_output(&recs[i], strlen(expected[i]), 30));
        pthread_mutex_lock(&recs[i].lock);
        CHECK(recs[i].output && !strcmp(recs[i].output, expected[i]));
        pthread_mutex_unlock(&recs[i].lock);
        spb_session_release(sessions[i]);
    }
    for (int i = 0; i < a->sessions; i++) {
        CHECK(rec_wait(&recs[i], pred_released, NULL, 30));
        CHECK(recs[i].callbacks_off_core_thread == 0);
        rec_destroy(&recs[i]);
    }
    spb_settings_free(settings);
    return NULL;
}

static void test_concurrent_sessions(server *echo)
{
    size_t fds_before = spb_debug_uxsel_fds();
    enum { WORKERS = 8, PER_WORKER = 16 };
    pthread_t threads[WORKERS];
    worker_arg args[WORKERS];
    for (int i = 0; i < WORKERS; i++) {
        args[i] = (worker_arg){ echo->port, i, PER_WORKER };
        pthread_create(&threads[i], NULL, concurrent_worker, &args[i]);
    }
    for (int i = 0; i < WORKERS; i++)
        pthread_join(threads[i], NULL);
    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);
    CHECK(spb_debug_uxsel_fds() == fds_before);
}

static void test_shutdown(server *echo)
{
    recorder r;
    rec_init(&r);
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_CONNECTED, 10));

    CHECK(!spb_core_shutdown());       /* refused: open handle */
    CHECK(spb_core_is_initialised());

    /* Shutdown straight after release: the queued teardown still runs. */
    spb_session_release(s);
    CHECK(spb_core_shutdown());
    CHECK(r.released);
    CHECK(spb_debug_live_sessions() == 0);
    CHECK(!spb_core_is_initialised());
    CHECK(!spb_core_barrier());
    rec_destroy(&r);

    char *err = NULL;
    spb_settings *later = spb_settings_new_defaults();
    CHECK(spb_session_create(later, NULL, NULL, &err) == NULL);
    spb_string_free(err);
    spb_settings_free(later);
}

/* ---------- Session log (M05) ---------- */

static void write_file(const char *path, const char *text)
{
    FILE *fp = fopen(path, "wb");
    fputs(text, fp);
    fclose(fp);
}

/* Contents of path (owned), or NULL if it does not exist. */
static char *read_file(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp)
        return NULL;
    char *buf = calloc(1, 65536);
    size_t n = fread(buf, 1, 65535, fp);
    buf[n] = '\0';
    fclose(fp);
    return buf;
}

typedef enum {
    LOG_NO_ANSWER,          /* release with the question still open */
    LOG_ANSWER_WHILE_CONNECTED,
    LOG_ANSWER_AFTER_CLOSE, /* the connection is gone; queued data stays */
} log_answer_timing;

/*
 * One logged Raw session: "All session output" to path, with the given
 * "if the file exists" setting. If a question comes, it is answered with
 * answer at the given time. Returns the file's contents afterwards.
 */
static char *logged_session(server *echo, const char *path,
                            const char *clash, bool expect_prompt,
                            spb_prompt_answer answer,
                            log_answer_timing timing, recorder *r)
{
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);
    spb_settings_set(settings, "LogType", "2");
    spb_settings_set(settings, "LogFileName", path);
    spb_settings_set(settings, "LogFileClash", clash);
    spb_settings_set(settings, "LogHeader", "0");
    spb_session *s = new_session(settings, r);
    spb_settings_free(settings);

    spb_session_start(s);
    CHECK(wait_state(r, SPB_SESSION_CONNECTED, 10));
    spb_session_send(s, "logged\n", 7);
    CHECK(wait_output(r, 7, 10));
    /* The terminal has logged what it received by the next iteration. */
    CHECK(spb_core_barrier());
    CHECK(spb_core_barrier());

    if (expect_prompt) {
        CHECK(rec_wait(r, pred_prompted, NULL, 10));
        pthread_mutex_lock(&r->lock);
        CHECK(r->prompts == 1);
        CHECK(r->prompt_kind == SPB_PROMPT_LOG_FILE_EXISTS);
        CHECK(r->prompt_title &&
              !strcmp(r->prompt_title, "SwiftPutty Log to File"));
        CHECK(r->prompt_paragraph && strstr(r->prompt_paragraph, path) &&
              strstr(r->prompt_paragraph, "already exists"));
        uint64_t id = r->prompt_id;
        pthread_mutex_unlock(&r->lock);

        if (timing == LOG_ANSWER_AFTER_CLOSE) {
            spb_session_close(s);
            CHECK(wait_state(r, SPB_SESSION_CLOSED, 10));
            CHECK(spb_core_barrier());
            /* Not withdrawn with the connection. */
            pthread_mutex_lock(&r->lock);
            CHECK(r->prompts_cancelled == 0);
            pthread_mutex_unlock(&r->lock);
        }
        if (timing != LOG_NO_ANSWER) {
            spb_session_answer_prompt(s, id, answer);
            /* A second answer is stale and ignored. */
            spb_session_answer_prompt(s, id, SPB_ANSWER_LOG_OVERWRITE);
            /* Let the answer's Event Log line out before release, which
             * suppresses callbacks at once. */
            CHECK(spb_core_barrier());
        }
    } else {
        pthread_mutex_lock(&r->lock);
        CHECK(r->prompts == 0);
        pthread_mutex_unlock(&r->lock);
    }

    spb_session_release(s);
    CHECK(rec_wait(r, pred_released, NULL, 10));
    CHECK(r->callbacks_after_release == 0);
    return read_file(path);
}

static void test_session_log(server *echo, const char *base)
{
    char path[600];
    snprintf(path, sizeof(path), "%s/session.log", base);
    recorder r;
    char *contents;

    /* No file yet: created without asking. */
    unlink(path);
    rec_init(&r);
    contents = logged_session(echo, path, "-1", false, 0, 0, &r);
    CHECK(contents && !strcmp(contents, "logged\n"));
    CHECK(r.event_log_text &&
          strstr(r.event_log_text, "Writing new session log (raw mode)"));
    free(contents);
    rec_destroy(&r);

    /* Ask; the answers are GTK PuTTY's buttons. */
    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "-1", true,
                              SPB_ANSWER_LOG_APPEND,
                              LOG_ANSWER_WHILE_CONNECTED, &r);
    CHECK(contents && !strcmp(contents, "old\nlogged\n"));
    CHECK(r.event_log_text &&
          strstr(r.event_log_text, "Appending session log"));
    free(contents);
    rec_destroy(&r);

    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "-1", true,
                              SPB_ANSWER_LOG_OVERWRITE,
                              LOG_ANSWER_WHILE_CONNECTED, &r);
    CHECK(contents && !strcmp(contents, "logged\n"));
    free(contents);
    rec_destroy(&r);

    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "-1", true, SPB_ANSWER_CANCEL,
                              LOG_ANSWER_WHILE_CONNECTED, &r);
    CHECK(contents && !strcmp(contents, "old\n"));
    CHECK(r.event_log_text &&
          strstr(r.event_log_text, "Disabled writing session log"));
    free(contents);
    rec_destroy(&r);

    /* Answered after the connection has gone: what was received while
     * the question was open is still written. */
    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "-1", true,
                              SPB_ANSWER_LOG_APPEND,
                              LOG_ANSWER_AFTER_CLOSE, &r);
    CHECK(contents && !strcmp(contents, "old\nlogged\n"));
    free(contents);
    rec_destroy(&r);

    /* Released with the question open: withdrawn; file untouched. */
    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "-1", true, 0, LOG_NO_ANSWER,
                              &r);
    CHECK(contents && !strcmp(contents, "old\n"));
    free(contents);
    rec_destroy(&r);

    /* "Always overwrite" and "Always append" do not ask. */
    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "1", false, 0, 0, &r);
    CHECK(contents && !strcmp(contents, "logged\n"));
    free(contents);
    rec_destroy(&r);

    write_file(path, "old\n");
    rec_init(&r);
    contents = logged_session(echo, path, "0", false, 0, 0, &r);
    CHECK(contents && !strcmp(contents, "old\nlogged\n"));
    free(contents);
    rec_destroy(&r);

    unlink(path);
}

/* ---------- Live reconfiguration (M07) ---------- */

/* Export the running settings (owned by the caller). */
static spb_settings *export_settings(spb_session *s, recorder *r,
                                     uint64_t request)
{
    spb_session_export_settings(s, request);
    CHECK(rec_wait(r, pred_exported, &request, 10));
    pthread_mutex_lock(&r->lock);
    spb_settings *settings = r->exported;
    r->exported = NULL;
    pthread_mutex_unlock(&r->lock);
    return settings;
}

static void test_reconfigure(server *echo, const char *base)
{
    char path[600];
    snprintf(path, sizeof(path), "%s/reconfig.log", base);
    unlink(path);
    recorder r;
    rec_init(&r);
    spb_settings *settings = raw_settings("127.0.0.1", echo->port);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);
    CHECK(spb_session_transport_id(s) == 0);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_CONNECTED, 10));
    uint64_t transport = spb_session_transport_id(s);
    CHECK(transport != 0);

    /* The running settings, as PuTTY would save them. */
    spb_settings *running = export_settings(s, &r, 1);
    CHECK(running && !strcmp(spb_settings_get(running, "HostName"), "127.0.0.1"));
    CHECK(running && !strcmp(spb_settings_get(running, "Protocol"), "raw"));
    CHECK(r.protocol_info == 0);                       /* Raw has no versions */

    /* Applying them unchanged is a no-op that keeps the connection. */
    int want = 1;
    spb_session_reconfigure(s, running, 2);
    CHECK(rec_wait(&r, pred_reconfigured, &want, 10));
    CHECK(r.reconfigured_request == 2);

    /* Turn logging on mid-session: later output is logged. */
    spb_settings_set(running, "LogType", "2");
    spb_settings_set(running, "LogFileName", path);
    spb_settings_set(running, "LogHeader", "0");
    want = 2;
    spb_session_reconfigure(s, running, 3);
    CHECK(rec_wait(&r, pred_reconfigured, &want, 10));
    spb_settings *after = export_settings(s, &r, 4);
    CHECK(after && !strcmp(spb_settings_get(after, "LogType"), "2"));
    spb_settings_free(after);
    spb_session_send(s, "after\n", 6);
    CHECK(wait_output(&r, 6, 10));
    CHECK(spb_core_barrier());
    CHECK(spb_core_barrier());
    CHECK(spb_session_transport_id(s) == transport);

    /* The creation snapshot is unchanged by reconfiguration. */
    spb_settings *created = spb_session_copy_settings(s);
    CHECK(!strcmp(spb_settings_get(created, "LogType"), "0"));
    spb_settings_free(created);

    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    spb_settings_free(running);
    char *contents = read_file(path);
    CHECK(contents && !strcmp(contents, "after\n"));
    free(contents);
    unlink(path);
    rec_destroy(&r);

    /* Reconfiguring after the connection has ended is harmless. */
    rec_init(&r);
    settings = raw_settings("127.0.0.1", unused_port());
    s = new_session(settings, &r);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_FAILED, 10));
    want = 1;
    spb_session_reconfigure(s, settings, 5);
    CHECK(rec_wait(&r, pred_reconfigured, &want, 10));
    spb_settings_free(settings);
    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    rec_destroy(&r);
}

/* ---------- prepare_session ---------- */

static void test_prepare_session(server *echo)
{
    /* "user@host:junk" connects to host with that user name, as PuTTY. */
    spb_settings *settings = raw_settings(" someone@127.0.0.1:99 ",
                                          echo->port);
    spb_settings_prepare_session(settings);
    CHECK(!strcmp(spb_settings_get(settings, "HostName"), "127.0.0.1"));
    CHECK(!strcmp(spb_settings_get(settings, "UserName"), "someone"));

    /* An unbracketed IPv6 literal keeps its colons. */
    spb_settings_set(settings, "HostName", "::1");
    spb_settings_prepare_session(settings);
    CHECK(!strcmp(spb_settings_get(settings, "HostName"), "::1"));

    /* Sessions apply it themselves. */
    spb_settings_set(settings, "HostName", "other@127.0.0.1");
    recorder r;
    rec_init(&r);
    spb_session *s = new_session(settings, &r);
    spb_settings_free(settings);
    spb_settings *used = spb_session_copy_settings(s);
    CHECK(!strcmp(spb_settings_get(used, "HostName"), "127.0.0.1"));
    CHECK(!strcmp(spb_settings_get(used, "UserName"), "other"));
    spb_settings_free(used);
    spb_session_start(s);
    CHECK(wait_state(&r, SPB_SESSION_CONNECTED, 10));
    spb_session_release(s);
    CHECK(rec_wait(&r, pred_released, NULL, 10));
    rec_destroy(&r);
}

int main(void)
{
    char template[] = "/tmp/spb-session-test-XXXXXX";
    char *base = mkdtemp(template);
    if (!base) {
        perror("mkdtemp");
        return 2;
    }
    char state_dir[512];
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);

    char *err = NULL;
    spb_core_options opts = { .state_dir = state_dir };
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "spb_core_init: %s\n", err);
        return 2;
    }

    server echo;
    server_start(&echo, SERVER_ECHO);

    test_core_thread_and_timers();
    test_raw_echo(&echo);
    test_large_transfer(&echo);
    test_remote_close();
    test_failures();
    test_release_paths(&echo);
    test_concurrent_sessions(&echo);
    test_session_log(&echo, base);
    test_prepare_session(&echo);
    test_reconfigure(&echo, base);
    test_shutdown(&echo);
    CHECK(spb_debug_live_settings() == 0);

    server_stop(&echo);

    /* PuTTY may have written its random seed into the state directory. */
    char seed[600];
    snprintf(seed, sizeof(seed), "%s/randomseed", state_dir);
    unlink(seed);
    rmdir(state_dir);
    rmdir(base);

    int n = atomic_load(&failures);
    if (n) {
        fprintf(stderr, "%d check(s) failed\n", n);
        return 1;
    }
    printf("spb_session_test: all checks passed\n");
    return 0;
}
