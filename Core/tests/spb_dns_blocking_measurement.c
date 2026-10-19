/*
 * M14: deterministically hold PuTTY's synchronous getaddrinfo call while a
 * second Raw session is active. This isolates core-thread serialization from
 * resolver/network variability; run explicitly as a measurement, not a test.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <netdb.h>
#include <unistd.h>
#include <dlfcn.h>

#include "PuTTYBridge.h"

#define HELD_HOST "spb-delayed-resolver.invalid"
#define PROBE "dns-stall-probe\n"

typedef struct observation {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    spb_session *session;
    bool connected, output, released;
    double output_at;
    char data[128];
    size_t len;
} observation;

static pthread_mutex_t resolver_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t resolver_cond = PTHREAD_COND_INITIALIZER;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static int (*system_getaddrinfo)(const char *, const char *,
                                 const struct addrinfo *, struct addrinfo **);
static bool resolver_entered, resolver_continue;
static double resolver_entered_at, resolver_released_at;

static void resolve_system_getaddrinfo(void)
{
    *(void **)(&system_getaddrinfo) = dlsym(RTLD_NEXT, "getaddrinfo");
}

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Deliberate link-time interposition: only the sentinel target blocks.
 * All other lookups use the system resolver unchanged. */
int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result)
{
    if (!node || strcmp(node, HELD_HOST)) {
        pthread_once(&resolve_once, resolve_system_getaddrinfo);
        if (!system_getaddrinfo)
            return EAI_FAIL;
        return system_getaddrinfo(node, service, hints, result);
    }

    pthread_mutex_lock(&resolver_lock);
    resolver_entered_at = now_seconds();
    resolver_entered = true;
    pthread_cond_broadcast(&resolver_cond);
    while (!resolver_continue)
        pthread_cond_wait(&resolver_cond, &resolver_lock);
    pthread_mutex_unlock(&resolver_lock);

    if (result)
        *result = NULL;
    return EAI_NONAME;
}


static void state_changed(void *ctx, spb_session_state state, const char *detail)
{
    observation *o = ctx;
    (void)detail;
    if (state == SPB_SESSION_CONNECTED) {
        pthread_mutex_lock(&o->lock);
        o->connected = true;
        pthread_cond_broadcast(&o->cond);
        pthread_mutex_unlock(&o->lock);
    }
}

static void output(void *ctx, const void *data, size_t len, bool is_stderr)
{
    observation *o = ctx;
    (void)is_stderr;
    pthread_mutex_lock(&o->lock);
    size_t n = len < sizeof(o->data) - o->len ? len : sizeof(o->data) - o->len;
    memcpy(o->data + o->len, data, n);
    o->len += n;
    /* Acknowledge before waking a waiter that may release the session. */
    spb_session_ack_output(o->session, len);
    if (o->len >= sizeof(PROBE) - 1 &&
        !memcmp(o->data, PROBE, sizeof(PROBE) - 1)) {
        o->output_at = now_seconds();
        o->output = true;
        pthread_cond_broadcast(&o->cond);
    }
    pthread_mutex_unlock(&o->lock);
}

static void released(void *ctx)
{
    observation *o = ctx;
    pthread_mutex_lock(&o->lock);
    o->released = true;
    pthread_cond_broadcast(&o->cond);
    pthread_mutex_unlock(&o->lock);
}

static const spb_session_callbacks callbacks = {
    .state_changed = state_changed,
    .output = output,
    .released = released,
};

static bool wait_flag(observation *o, bool *flag, double seconds)
{
    double until = now_seconds() + seconds;
    pthread_mutex_lock(&o->lock);
    while (!*flag && now_seconds() < until) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 10000000;
        if (ts.tv_nsec >= 1000000000) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&o->cond, &o->lock, &ts);
    }
    bool done = *flag;
    pthread_mutex_unlock(&o->lock);
    return done;
}

static void *echo_server(void *arg)
{
    int listener = *(int *)arg;
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) {
        char buf[256];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            size_t off = 0;
            while (off < (size_t)n) {
                ssize_t written = write(fd, buf + off, (size_t)n - off);
                if (written <= 0)
                    break;
                off += (size_t)written;
            }
        }
        close(fd);
    }
    return NULL;
}

static spb_session *new_raw(const char *host, int port, observation *o)
{
    spb_settings *settings = spb_settings_new_defaults();
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    spb_settings_set(settings, "Protocol", "raw");
    spb_settings_set(settings, "HostName", host);
    spb_settings_set(settings, "PortNumber", portstr);
    char *err = NULL;
    spb_session *session = spb_session_create(settings, &callbacks, o, &err);
    spb_settings_free(settings);
    if (!session || err) {
        fprintf(stderr, "session creation failed: %s\n", err ? err : "unknown");
        spb_string_free(err);
        exit(2);
    }
    o->session = session;
    spb_string_free(err);
    return session;
}

int main(void)
{
    char state_dir[] = "/tmp/spb-dns-measurement-XXXXXX";
    if (!mkdtemp(state_dir)) {
        perror("mkdtemp");
        return 2;
    }
    spb_core_options options = { .state_dir = state_dir };
    char *err = NULL;
    if (!spb_core_init(&options, &err)) {
        fprintf(stderr, "core init failed: %s\n", err ? err : "unknown");
        spb_string_free(err);
        return 2;
    }
    spb_string_free(err);

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (listener < 0 || bind(listener, (struct sockaddr *)&addr, sizeof(addr)) ||
        listen(listener, 1)) {
        perror("loopback listener");
        return 2;
    }
    socklen_t addrlen = sizeof(addr);
    getsockname(listener, (struct sockaddr *)&addr, &addrlen);
    pthread_t server;
    pthread_create(&server, NULL, echo_server, &listener);

    observation active = { .lock = PTHREAD_MUTEX_INITIALIZER,
                           .cond = PTHREAD_COND_INITIALIZER };
    observation delayed = { .lock = PTHREAD_MUTEX_INITIALIZER,
                            .cond = PTHREAD_COND_INITIALIZER };
    spb_session *first = new_raw("127.0.0.1", ntohs(addr.sin_port), &active);
    spb_session_start(first);
    if (!wait_flag(&active, &active.connected, 5)) {
        fprintf(stderr, "active session did not connect\n");
        return 2;
    }

    spb_session *second = new_raw(HELD_HOST, 22, &delayed);
    spb_session_start(second);
    pthread_mutex_lock(&resolver_lock);
    while (!resolver_entered)
        pthread_cond_wait(&resolver_cond, &resolver_lock);
    pthread_mutex_unlock(&resolver_lock);

    double probe_sent_at = now_seconds();
    spb_session_send(first, PROBE, sizeof(PROBE) - 1);
    bool progressed_while_blocked = wait_flag(&active, &active.output, 0.25);

    pthread_mutex_lock(&resolver_lock);
    resolver_continue = true;
    resolver_released_at = now_seconds();
    pthread_cond_broadcast(&resolver_cond);
    pthread_mutex_unlock(&resolver_lock);
    if (!wait_flag(&active, &active.output, 5)) {
        fprintf(stderr, "active session did not echo probe\n");
        return 2;
    }

    double block_to_output_ms = (active.output_at - resolver_entered_at) * 1000.0;
    double send_to_output_ms = (active.output_at - probe_sent_at) * 1000.0;
    printf("resolver held: %.1f ms; second-session probe output: %s; "
           "resolver-entry-to-output: %.1f ms; probe-to-output: %.1f ms\n",
           (resolver_released_at - resolver_entered_at) * 1000.0,
           progressed_while_blocked ? "within 250 ms" : "after release",
           block_to_output_ms, send_to_output_ms);

    spb_session_release(second);
    spb_session_release(first);
    wait_flag(&delayed, &delayed.released, 5);
    wait_flag(&active, &active.released, 5);
    spb_core_barrier();
    spb_core_shutdown();
    shutdown(listener, SHUT_RDWR);
    close(listener);
    char seed[512];
    snprintf(seed, sizeof(seed), "%s/randomseed", state_dir);
    unlink(seed);
    rmdir(state_dir);
    return progressed_while_blocked ? 1 : 0;
}
