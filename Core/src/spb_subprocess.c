/*
 * spb_subprocess.c - SubprocessWaiter without SIGCHLD (D-041).
 *
 * Upstream's Unix waiter (unix/utils/subprocess_waiter.c, not linked)
 * installs a process-wide SIGCHLD handler and reaps with waitpid(-1).
 * In an application that would take the exit status of every other
 * child of the process (Foundation's Process, popen in printing) and
 * interrupt system calls on other threads. Here each child gets a
 * detached thread that waits for that pid alone, then hands the exit to
 * the core thread, where the callback runs as upstream expects.
 *
 * A waiter is shared by its owner (freed with subproc_waiter_free, on
 * the core thread) and its reaper thread; the last to let go frees it,
 * so freeing before the child exits still reaps it.
 */

#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <sys/wait.h>

#include "spb_internal.h"

struct SubprocessWaiter {
    pid_t pid;
    SubprocessWaiterCallback callback;     /* core thread only */
    void *cbctx;
    int refs;                              /* under refs_lock */
    int exittype;
    uint32_t exitdata;
};

static pthread_mutex_t refs_lock = PTHREAD_MUTEX_INITIALIZER;

static void waiter_unref(SubprocessWaiter *w)
{
    pthread_mutex_lock(&refs_lock);
    bool last = --w->refs == 0;
    pthread_mutex_unlock(&refs_lock);
    if (last)
        sfree(w);
}

/* Core thread, holding the reaper's reference. */
static void waiter_deliver(void *ctx)
{
    SubprocessWaiter *w = (SubprocessWaiter *)ctx;
    pthread_mutex_lock(&refs_lock);
    bool owned = w->refs == 2;             /* the owner has not freed it */
    pthread_mutex_unlock(&refs_lock);
    if (owned && w->callback)
        w->callback(w->cbctx, w->exittype, w->exitdata);
    waiter_unref(w);
}

static void *waiter_thread(void *ctx)
{
    SubprocessWaiter *w = (SubprocessWaiter *)ctx;
    int status;
    pid_t ret;
    for (;;) {
        ret = waitpid(w->pid, &status, 0);
        if (ret == w->pid && !WIFEXITED(status) && !WIFSIGNALED(status))
            continue;                      /* stopped or continued */
        if (ret < 0 && errno == EINTR)
            continue;
        break;
    }
    if (ret == w->pid && WIFSIGNALED(status)) {
        w->exittype = EXITTYPE_SIGNAL;
        w->exitdata = WTERMSIG(status);
    } else {
        /* Exited, or (ECHILD) reaped by someone else: report status 0
         * then, rather than never reporting at all. */
        w->exittype = EXITTYPE_NORMAL;
        w->exitdata = ret == w->pid ? WEXITSTATUS(status) : 0;
    }
    if (!spb_loop_post(waiter_deliver, w))
        waiter_unref(w);                   /* the core has stopped */
    return NULL;
}

SubprocessWaiter *subproc_waiter_from_pid(pid_t pid)
{
    SubprocessWaiter *w = snew(SubprocessWaiter);
    w->pid = pid;
    w->callback = NULL;
    w->cbctx = NULL;
    w->refs = 2;
    w->exittype = EXITTYPE_NORMAL;
    w->exitdata = 0;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 64 * 1024);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, waiter_thread, w);
    pthread_attr_destroy(&attr);
    if (err != 0)
        modalfatalbox("SwiftPutty: unable to start a thread to wait for "
                      "a local command: %s", strerror(err));
    return w;
}

void subproc_waiter_set_callback(
    SubprocessWaiter *waiter, SubprocessWaiterCallback cb, void *cbctx)
{
    waiter->callback = cb;
    waiter->cbctx = cbctx;
}

void subproc_waiter_free(SubprocessWaiter *waiter)
{
    waiter_unref(waiter);
}

/* Upstream's pty backend calls these; SwiftPutty does not link it, and
 * no other child of the process is ever reaped here. */
void subproc_waiter_force_setup(void) {}
void subproc_waiter_force_wait(void) {}
