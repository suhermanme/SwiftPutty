/*
 * spb_eventloop.c - the PuTTY core thread (docs/DECISIONS.md D-003).
 *
 * One dedicated thread per process runs a loop modelled directly on
 * upstream's unix/cliloop.c: on every iteration it re-reads uxsel's fd
 * set (first_fd/next_fd) and the timer queue, waits, dispatches
 * select_result(), then runs toplevel callbacks. All PuTTY code runs on
 * this thread.
 *
 * It waits with select(), not upstream's pollwrap (poll()): macOS's
 * poll() never reports TCP urgent data, which every PuTTY socket asks
 * for as SELECT_X (Rlogin's window size requests, Telnet's SYNCH), while
 * select()'s exception set does (docs/DECISIONS.md D-035). Defining
 * _DARWIN_UNLIMITED_SELECT lifts FD_SETSIZE; the sets are sized to the
 * highest descriptor.
 *
 * Other threads never call into PuTTY. They post commands to a locked
 * FIFO queue and wake the loop through a self-pipe; the loop runs the
 * commands at top level, in posting order, once per iteration.
 *
 * Because the loop rescans uxsel's fd set and the timer queue on every
 * iteration, and because uxsel and timers are only ever touched on the
 * core thread, the uxsel/timer notification hooks need do nothing: any
 * change they report was made by code the loop itself is running, and the
 * loop looks again before it next blocks (exactly as in cliloop).
 */

#define _DARWIN_UNLIMITED_SELECT 1     /* before any system header */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

#include "spb_internal.h"

typedef struct spb_command spb_command;
struct spb_command {
    spb_command_fn fn;
    void *ctx;
    spb_command *next;
};

static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static spb_command *queue_head, *queue_tail;  /* protected by queue_lock */
static bool queue_accepting;                  /* protected by queue_lock */

static int wake_pipe[2] = { -1, -1 };
static atomic_bool wake_pending;

static pthread_t core_thread;
static atomic_bool core_thread_running;
static bool stop_requested;                   /* core thread only */

static atomic_uint_fast64_t loop_iterations;

bool spb_loop_on_core_thread(void)
{
    return atomic_load(&core_thread_running) &&
        pthread_equal(pthread_self(), core_thread);
}

void spb_loop_assert_core_thread(void)
{
    if (!spb_loop_on_core_thread())
        modalfatalbox("SwiftPutty internal error: PuTTY code entered "
                      "outside the core thread");
}

static void loop_wake(void)
{
    if (atomic_exchange(&wake_pending, true))
        return;                        /* a wake-up is already on its way */
    static const char byte = 0;
    ssize_t ret;
    do {
        ret = write(wake_pipe[1], &byte, 1);
    } while (ret < 0 && errno == EINTR);
    /* EAGAIN means the pipe is full, so the loop will wake anyway. */
}

/*
 * Empty the pipe, then clear the flag; the caller runs the command queue
 * afterwards. In this order a poster either sees the flag still set (and
 * its command, queued before it looked, is picked up by that queue run)
 * or sees it clear and writes a byte that wakes the next poll. Clearing
 * first would let a byte written in between be swallowed while the flag
 * stayed set, and no poster would ever write again.
 */
static void loop_drain_wake_pipe(void)
{
    char buf[64];
    while (read(wake_pipe[0], buf, sizeof(buf)) > 0)
        ;
    atomic_store(&wake_pending, false);
}

/* Append a command; if close_queue, nothing more is accepted after it. */
static bool loop_enqueue(spb_command_fn fn, void *ctx, bool close_queue)
{
    spb_command *cmd = snew(spb_command);
    cmd->fn = fn;
    cmd->ctx = ctx;
    cmd->next = NULL;

    pthread_mutex_lock(&queue_lock);
    bool accepted = queue_accepting;
    if (accepted) {
        if (queue_tail)
            queue_tail->next = cmd;
        else
            queue_head = cmd;
        queue_tail = cmd;
        if (close_queue)
            queue_accepting = false;
    }
    pthread_mutex_unlock(&queue_lock);

    if (!accepted) {
        sfree(cmd);
        return false;
    }
    loop_wake();
    return true;
}

bool spb_loop_post(spb_command_fn fn, void *ctx)
{
    return loop_enqueue(fn, ctx, false);
}

/*
 * Run every command queued so far. Commands posted while these run wait
 * for the next iteration, so a command that re-posts itself cannot
 * starve the network.
 */
static void loop_run_commands(void)
{
    pthread_mutex_lock(&queue_lock);
    spb_command *cmd = queue_head;
    queue_head = queue_tail = NULL;
    pthread_mutex_unlock(&queue_lock);

    while (cmd) {
        spb_command *next = cmd->next;
        cmd->fn(cmd->ctx);
        sfree(cmd);
        cmd = next;
    }
}

typedef struct sync_call {
    spb_command_fn fn;
    void *ctx;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    bool done;
} sync_call;

static void sync_call_run(void *vctx)
{
    sync_call *call = (sync_call *)vctx;
    if (call->fn)
        call->fn(call->ctx);
    pthread_mutex_lock(&call->lock);
    call->done = true;
    pthread_cond_signal(&call->cond);
    pthread_mutex_unlock(&call->lock);
}

bool spb_loop_run_sync(spb_command_fn fn, void *ctx)
{
    if (spb_loop_on_core_thread()) {
        if (fn)
            fn(ctx);
        return true;
    }

    sync_call call = { .fn = fn, .ctx = ctx, .done = false };
    pthread_mutex_init(&call.lock, NULL);
    pthread_cond_init(&call.cond, NULL);

    bool posted = spb_loop_post(sync_call_run, &call);
    if (posted) {
        pthread_mutex_lock(&call.lock);
        while (!call.done)
            pthread_cond_wait(&call.cond, &call.lock);
        pthread_mutex_unlock(&call.lock);
    }

    pthread_cond_destroy(&call.cond);
    pthread_mutex_destroy(&call.lock);
    return posted;
}

static void loop_request_stop(void *ctx)
{
    stop_requested = true;
}

/* Read, write and exception sets for every descriptor up to maxfd. */
typedef struct fdsets {
    fd_set *r, *w, *x;
    size_t capacity, used;             /* bytes per set */
} fdsets;

static void fdsets_reset(fdsets *s, int maxfd)
{
    size_t need = ((size_t)maxfd / NFDBITS + 1) * sizeof(fd_mask);
    if (need > s->capacity) {
        s->r = srealloc(s->r, need);
        s->w = srealloc(s->w, need);
        s->x = srealloc(s->x, need);
        s->capacity = need;
    }
    s->used = need;
    memset(s->r, 0, need);
    memset(s->w, 0, need);
    memset(s->x, 0, need);
}

static void fdsets_add(fdsets *s, int fd, int rwx)
{
    if (rwx & SELECT_R) FD_SET(fd, s->r);
    if (rwx & SELECT_W) FD_SET(fd, s->w);
    if (rwx & SELECT_X) FD_SET(fd, s->x);
}

static int fdsets_get(fdsets *s, int fd)
{
    return (FD_ISSET(fd, s->r) ? SELECT_R : 0) |
        (FD_ISSET(fd, s->w) ? SELECT_W : 0) |
        (FD_ISSET(fd, s->x) ? SELECT_X : 0);
}

/* select() with a timeout in milliseconds; < 0 waits without limit. */
static int fdsets_wait(fdsets *s, int maxfd, long ms)
{
    struct timeval tv, *tvp = NULL;
    if (ms >= 0) {
        tv.tv_sec = ms / 1000;
        tv.tv_usec = (ms % 1000) * 1000;
        tvp = &tv;
    }
    return select(maxfd + 1, s->r, s->w, s->x, tvp);
}

/* The loop proper: unix/cliloop.c's cli_main_loop, plus the wake pipe
 * and command queue. */
static void *core_thread_main(void *arg)
{
    pthread_setname_np("org.swiftputty.putty-core");

    unsigned long now = GETTICKCOUNT();
    int *fdlist = NULL;
    size_t fdsize = 0;
    fdsets sets = { 0 };

    while (!stop_requested) {
        int rwx, ret, fdstate;
        unsigned long next;

        size_t nfds = 0;
        int maxfd = wake_pipe[0];
        for (int fd = first_fd(&fdstate, &rwx); fd >= 0;
             fd = next_fd(&fdstate, &rwx)) {
            nfds++;
            if (fd > maxfd)
                maxfd = fd;
        }
        sgrowarray(fdlist, fdsize, nfds);

        /* The sets are rebuilt before every wait: select() overwrites
         * them with its results. */
        fdsets_reset(&sets, maxfd);
        fdsets_add(&sets, wake_pipe[0], SELECT_R);
        size_t fdcount = 0;
        for (int fd = first_fd(&fdstate, &rwx); fd >= 0;
             fd = next_fd(&fdstate, &rwx)) {
            fdlist[fdcount++] = fd;
            fdsets_add(&sets, fd, rwx);
        }

        if (toplevel_callback_pending()) {
            ret = fdsets_wait(&sets, maxfd, 0);
        } else if (run_timers(now, &next)) {
            do {
                unsigned long then;
                long ticks;

                then = now;
                now = GETTICKCOUNT();
                if (now - then > next - then)
                    ticks = 0;
                else
                    ticks = next - now;

                bool overflow = false;
                if (ticks > INT_MAX) {
                    ticks = INT_MAX;
                    overflow = true;
                }

                ret = fdsets_wait(&sets, maxfd, ticks);
                if (ret == 0 && !overflow)
                    now = next;
                else
                    now = GETTICKCOUNT();
                /* Not retried here on EINTR: select() leaves the sets
                 * undefined, and the outer loop rebuilds them. */
            } while (0);
        } else {
            ret = fdsets_wait(&sets, maxfd, -1);
        }

        if (ret < 0 && errno == EINTR)
            continue;
        if (ret < 0)
            modalfatalbox("select: %s", strerror(errno));

        if (FD_ISSET(wake_pipe[0], sets.r))
            loop_drain_wake_pipe();

        for (size_t i = 0; i < fdcount; i++) {
            int fd = fdlist[i];
            int fdrwx = fdsets_get(&sets, fd);
            /* Exceptional before readable, or we may go straight past
             * the urgent marker (as cliloop). */
            if (fdrwx & SELECT_X)
                select_result(fd, SELECT_X);
            if (fdrwx & SELECT_R)
                select_result(fd, SELECT_R);
            if (fdrwx & SELECT_W)
                select_result(fd, SELECT_W);
        }

        loop_run_commands();
        run_toplevel_callbacks();
        spb_sessions_after_iteration();

        atomic_fetch_add(&loop_iterations, 1);
    }

    sfree(sets.r);
    sfree(sets.w);
    sfree(sets.x);
    sfree(fdlist);
    return NULL;
}

static bool make_wake_pipe(char **err_out)
{
    if (pipe(wake_pipe) < 0) {
        spb_set_error(err_out, "pipe: %s", strerror(errno));
        return false;
    }
    for (int i = 0; i < 2; i++) {
        if (fcntl(wake_pipe[i], F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(wake_pipe[i], F_SETFL,
                  fcntl(wake_pipe[i], F_GETFL) | O_NONBLOCK) < 0) {
            spb_set_error(err_out, "fcntl: %s", strerror(errno));
            close(wake_pipe[0]);
            close(wake_pipe[1]);
            wake_pipe[0] = wake_pipe[1] = -1;
            return false;
        }
    }
    return true;
}

bool spb_loop_start(char **err_out)
{
    if (!make_wake_pipe(err_out))
        return false;

    stop_requested = false;
    pthread_mutex_lock(&queue_lock);
    queue_accepting = true;
    pthread_mutex_unlock(&queue_lock);

    /*
     * Set before the thread exists so that spb_loop_on_core_thread() is
     * true from the thread's first instruction; core_thread is written
     * by pthread_create before the new thread can observe it.
     */
    atomic_store(&core_thread_running, true);
    int err = pthread_create(&core_thread, NULL, core_thread_main, NULL);
    if (err) {
        atomic_store(&core_thread_running, false);
        pthread_mutex_lock(&queue_lock);
        queue_accepting = false;
        pthread_mutex_unlock(&queue_lock);
        close(wake_pipe[0]);
        close(wake_pipe[1]);
        wake_pipe[0] = wake_pipe[1] = -1;
        spb_set_error(err_out, "Unable to start the PuTTY core thread: %s",
                      strerror(err));
        return false;
    }
    return true;
}

void spb_loop_stop(void)
{
    /*
     * The stop command is queued behind everything already posted, so
     * pending work (such as session teardown after release) runs first,
     * and the queue is closed in the same step, so nothing can follow it.
     */
    loop_enqueue(loop_request_stop, NULL, true);
    pthread_join(core_thread, NULL);
    atomic_store(&core_thread_running, false);

    close(wake_pipe[0]);
    close(wake_pipe[1]);
    wake_pipe[0] = wake_pipe[1] = -1;
}

static void count_uxsel_fds(void *vctx)
{
    size_t *count = vctx;
    int rwx, fdstate;
    for (int fd = first_fd(&fdstate, &rwx); fd >= 0;
         fd = next_fd(&fdstate, &rwx))
        (*count)++;
}

size_t spb_debug_uxsel_fds(void)
{
    /* Counted on the core thread, after everything queued before. */
    size_t count = 0;
    spb_loop_run_sync(count_uxsel_fds, &count);
    return count;
}

uint64_t spb_debug_loop_iterations(void)
{
    return atomic_load(&loop_iterations);
}

/* ---------- Upstream notification hooks ---------- */

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    return NULL;                       /* the loop rescans uxsel's fd set */
}

void uxsel_input_remove(uxsel_id *id)
{
}

void timer_change_notify(unsigned long next)
{
}
