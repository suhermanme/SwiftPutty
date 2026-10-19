/*
 * spb_core.c - library information and process-wide core lifecycle.
 */

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "spb_internal.h"
#include "ssh.h"                         /* sshver */
#include "licence.h"

atomic_size_t spb_live_sessions;
atomic_size_t spb_open_sessions;
atomic_size_t spb_live_settings;

/*
 * Upstream's process-global state (sk_init, uxsel_init) is designed to be
 * set up once per process and torn down only at exit: sk_cleanup() closes
 * sockets but does not free the socket tree, and calling the init
 * functions again would leak. So the core has three states, and
 * SHUT_DOWN is final. The core thread (spb_eventloop.c) runs exactly
 * while the state is RUNNING.
 */
enum core_state { CORE_UNINITIALISED, CORE_RUNNING, CORE_SHUT_DOWN };

static pthread_mutex_t core_lock = PTHREAD_MUTEX_INITIALIZER;
static enum core_state core_state = CORE_UNINITIALISED;
static char *core_state_dir;           /* set while CORE_RUNNING */

static const char licence_text[] = LICENCE_TEXT("\n\n");
static const char copyright_text[] = SHORT_COPYRIGHT_DETAILS;

int32_t spb_api_version(void)
{
    return SPB_API_VERSION;
}

const char *spb_putty_version(void)
{
    return ver;
}

const char *spb_putty_ssh_version(void)
{
    return sshver;
}

const char *spb_putty_licence_text(void)
{
    return licence_text;
}

const char *spb_putty_copyright(void)
{
    return copyright_text;
}

void spb_string_free(char *s)
{
    sfree(s);
}

void spb_set_error(char **err_out, const char *fmt, ...)
{
    if (!err_out)
        return;
    va_list ap;
    va_start(ap, fmt);
    *err_out = dupvprintf(fmt, ap);
    va_end(ap);
}

static bool ensure_private_dir(const char *path, char **err_out)
{
    char *err = make_dir_path(path, 0700);
    if (err) {
        spb_set_error(err_out, "Unable to create state directory: %s", err);
        sfree(err);
        return false;
    }
    struct stat st;
    if (stat(path, &st) < 0 || !S_ISDIR(st.st_mode)) {
        spb_set_error(err_out, "State directory \"%s\" is not a directory",
                      path);
        return false;
    }
    return true;
}

bool spb_core_init(const spb_core_options *options, char **err_out)
{
    if (err_out)
        *err_out = NULL;
    if (!options || !options->state_dir || options->state_dir[0] != '/') {
        spb_set_error(err_out, "state_dir must be an absolute path");
        return false;
    }

    pthread_mutex_lock(&core_lock);
    bool ok = false;

    if (core_state == CORE_RUNNING) {
        if (!strcmp(core_state_dir, options->state_dir))
            ok = true;
        else
            spb_set_error(err_out, "Core already initialised with state "
                          "directory \"%s\"", core_state_dir);
        goto out;
    }
    if (core_state == CORE_SHUT_DOWN) {
        spb_set_error(err_out, "Core cannot be re-initialised after "
                      "spb_core_shutdown() in the same process");
        goto out;
    }

    if (!ensure_private_dir(options->state_dir, err_out))
        goto out;

    /*
     * Upstream unix/storage.c locates host keys, host CAs and the random
     * seed under $PUTTYDIR. Point it at our state directory, overriding
     * anything inherited from the environment so that SwiftPutty never
     * reads or writes ~/.putty.
     */
    if (setenv("PUTTYDIR", options->state_dir, 1) != 0) {
        spb_set_error(err_out, "setenv(PUTTYDIR) failed: %s",
                      strerror(errno));
        goto out;
    }
    unsetenv("PUTTYSSHHOSTKEYS");
    unsetenv("PUTTYSSHHOSTCAS");
    unsetenv("PUTTYRANDOMSEED");
    unsetenv("PUTTYSESSIONS");

    /*
     * Every upstream Unix frontend (plink, pageant, uppity,
     * main-gtk-simple) ignores SIGPIPE at startup so that a socket write
     * racing with the peer resetting the connection returns EPIPE to the
     * caller instead of killing the whole process. SwiftPutty has no
     * frontend main() of its own to do this, so the bridge does it here,
     * once, before any socket exists.
     */
    putty_signal(SIGPIPE, SIG_IGN);

    /* Upstream's global trees must exist before the loop first scans
     * them. The thread is created afterwards, which orders these writes
     * before anything it does. */
    sk_init();
    uxsel_init();

    if (!spb_loop_start(err_out)) {
        /* Upstream state cannot be set up twice, so this is final. */
        sk_cleanup();
        core_state = CORE_SHUT_DOWN;
        goto out;
    }

    core_state_dir = dupstr(options->state_dir);
    core_state = CORE_RUNNING;
    ok = true;

  out:
    pthread_mutex_unlock(&core_lock);
    return ok;
}

bool spb_core_shutdown(void)
{
    pthread_mutex_lock(&core_lock);
    bool ok = false;
    if (core_state != CORE_RUNNING) {
        ok = true;                     /* nothing to do */
    } else if (atomic_load(&spb_open_sessions) == 0 &&
               !spb_loop_on_core_thread()) {
        spb_loop_stop();               /* finishes pending teardowns */
        sk_cleanup();
        sfree(core_state_dir);
        core_state_dir = NULL;
        core_state = CORE_SHUT_DOWN;
        ok = true;
    }
    pthread_mutex_unlock(&core_lock);
    return ok;
}

bool spb_core_is_initialised(void)
{
    pthread_mutex_lock(&core_lock);
    bool ret = core_state == CORE_RUNNING;
    pthread_mutex_unlock(&core_lock);
    return ret;
}

bool spb_core_is_core_thread(void)
{
    return spb_loop_on_core_thread();
}

bool spb_core_barrier(void)
{
    if (spb_loop_on_core_thread())
        return false;                  /* would wait for itself */
    return spb_loop_run_sync(NULL, NULL);
}

typedef struct debug_delay {
    void (*fn)(void *ctx);
    void *ctx;
    uint32_t delay_ms;
} debug_delay;

static void debug_delay_fire(void *vctx, unsigned long now)
{
    debug_delay *d = (debug_delay *)vctx;
    d->fn(d->ctx);
    sfree(d);
}

static void debug_delay_schedule(void *vctx)
{
    debug_delay *d = (debug_delay *)vctx;
    schedule_timer((int)d->delay_ms, debug_delay_fire, d);
}

void spb_debug_after_delay(uint32_t delay_ms, void (*fn)(void *ctx),
                           void *ctx)
{
    debug_delay *d = snew(debug_delay);
    d->fn = fn;
    d->ctx = ctx;
    d->delay_ms = delay_ms > INT_MAX ? INT_MAX : delay_ms;
    if (!spb_loop_post(debug_delay_schedule, d))
        sfree(d);
}

size_t spb_debug_live_sessions(void)
{
    return atomic_load(&spb_live_sessions);
}

size_t spb_debug_live_settings(void)
{
    return atomic_load(&spb_live_settings);
}
