/*
 * PuTTYBridge.h - the only interface between SwiftPutty's Swift code and
 * the PuTTY C core.
 *
 * Rules (see docs/ARCHITECTURE.md section 7):
 *  - Opaque handles only; no PuTTY internal type is visible here.
 *  - Strings are UTF-8, NUL-terminated. Returned strings documented as
 *    "owned" must be released with spb_string_free().
 *
 * Threading (docs/DECISIONS.md D-003): spb_core_init starts one PuTTY core
 * thread for the whole process, and all PuTTY code runs on it. Session
 * operations may be called from any thread; they enqueue a command for
 * the core thread and return without waiting (commands for one session
 * run in the order they were called). Session callbacks are invoked on
 * the core thread; they must return promptly and copy anything they keep,
 * since pointer arguments are valid only during the call.
 *
 * spb_core_init/spb_core_shutdown must not race with each other. A given
 * spb_settings object must not be used from two threads at the same time.
 */

#ifndef SWIFTPUTTY_PUTTYBRIDGE_H
#define SWIFTPUTTY_PUTTYBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SPB_API_VERSION 2

/* ---------- Library information ---------- */

/* Bridge API version (SPB_API_VERSION of the compiled library). */
int32_t spb_api_version(void);

/* PuTTY release string, e.g. "Release 0.85". Static; do not free. */
const char *spb_putty_version(void);

/* PuTTY's SSH version-string suffix, e.g. "-Release-0.85". Static. */
const char *spb_putty_ssh_version(void);

/* Full PuTTY licence text, paragraphs separated by blank lines. Static. */
const char *spb_putty_licence_text(void);

/* Short PuTTY copyright line, e.g. "1997-2026 Simon Tatham". Static. */
const char *spb_putty_copyright(void);

/* Release a string returned as "owned" by this API. NULL is allowed. */
void spb_string_free(char *s);

/* ---------- Core lifecycle ---------- */

typedef struct spb_core_options {
    /*
     * Directory for PuTTY's persistent state: trusted host keys, host
     * CA records and the random seed. Created (mode 0700) if missing.
     * Must be an absolute path.
     */
    const char *state_dir;
} spb_core_options;

/*
 * Initialise process-wide PuTTY state and start the core thread.
 * Idempotent when called again with
 * the same state_dir; fails if called with a different one, or after
 * spb_core_shutdown() (upstream's global state is set up once per
 * process). Points upstream storage ($PUTTYDIR) at state_dir, so the core
 * never touches ~/.putty. On failure returns false and, if err_out is
 * non-NULL, stores an owned error message there.
 */
bool spb_core_init(const spb_core_options *options, char **err_out);

/*
 * Stop the core thread and tear down process-wide state at process exit.
 * Every session must have been released first; returns false (and does
 * nothing) otherwise. Teardown work still queued for released sessions
 * runs before the thread stops. Final: the core cannot be initialised
 * again in the same process. Must not be called from a session callback.
 */
bool spb_core_shutdown(void);

bool spb_core_is_initialised(void);

/* Whether the calling thread is the PuTTY core thread. */
bool spb_core_is_core_thread(void);

/*
 * Block until every command posted to the core thread before this call
 * has run (including teardown of released sessions). Intended for tests
 * and diagnostics; must not be called from a session callback. Returns
 * false if the core is not running.
 */
bool spb_core_barrier(void);

/* ---------- Settings document ----------
 *
 * A sorted map from PuTTY saved-session keywords (conf.h SAVE_KEYWORD,
 * e.g. "HostName", "PortForwardings") to string values, exactly as
 * PuTTY's Unix session files store them. Conversion to and from PuTTY's
 * internal Conf goes through upstream's load_open_settings() and
 * save_open_settings().
 */

typedef struct spb_settings spb_settings;

spb_settings *spb_settings_new_empty(void);

/* PuTTY's built-in defaults ("Default Settings" with nothing saved). */
spb_settings *spb_settings_new_defaults(void);

spb_settings *spb_settings_copy(const spb_settings *settings);
void spb_settings_free(spb_settings *settings);

/* Insert or replace a keyword's value. */
void spb_settings_set(spb_settings *settings,
                      const char *keyword, const char *value);

/* Remove a keyword; returns whether it was present. */
bool spb_settings_remove(spb_settings *settings, const char *keyword);

/* Value for keyword, or NULL. Valid until the settings are modified. */
const char *spb_settings_get(const spb_settings *settings,
                             const char *keyword);

/* Iteration in ascending byte-wise keyword order. */
size_t spb_settings_count(const spb_settings *settings);
const char *spb_settings_key_at(const spb_settings *settings, size_t index);
const char *spb_settings_value_at(const spb_settings *settings,
                                  size_t index);

/*
 * Canonicalise in place by loading into a PuTTY Conf and saving it back:
 * unknown keywords are dropped, missing ones get PuTTY's defaults, and
 * legacy forms are converted to current ones.
 */
void spb_settings_normalise(spb_settings *settings);

/* ---------- Session ---------- */

typedef struct spb_session spb_session;

typedef enum spb_session_state {
    SPB_SESSION_CREATED,      /* not started yet */
    SPB_SESSION_CONNECTING,   /* started; the backend is not ready for input */
    SPB_SESSION_CONNECTED,    /* the backend accepts input */
    SPB_SESSION_CLOSED,       /* ended normally (remote exit or local close) */
    SPB_SESSION_FAILED,       /* ended with an error; see the detail text */
} spb_session_state;

/*
 * Callbacks run on the core thread. Any member may be NULL. After
 * spb_session_release() no callback is started except `released`, which
 * is always the last call made with ctx (it happens after every other
 * callback for the session has returned), so the caller frees ctx there.
 */
typedef struct spb_session_callbacks {
    /* detail: a human-readable reason, or NULL. Each state is reported at
     * most once, in the order above; CLOSED and FAILED are final. */
    void (*state_changed)(void *ctx, spb_session_state state,
                          const char *detail);
    /* One line of PuTTY's Event Log. */
    void (*event_log)(void *ctx, const char *line);
    /* Data received from the backend (raw bytes; no terminal yet). */
    void (*output)(void *ctx, const void *data, size_t len, bool is_stderr);
    /* The remote end exited; exit_code as PuTTY's backend_exitcode()
     * (INT32_MAX for an unclean exit). Reported before CLOSED. */
    void (*remote_exit)(void *ctx, int32_t exit_code);
    /* Final call; see above. */
    void (*released)(void *ctx);
} spb_session_callbacks;

/*
 * Create a session holding a PuTTY Conf built from settings. Requires
 * spb_core_init(). Does not connect. callbacks may be NULL; otherwise it
 * is copied. Returns NULL (and an owned message in err_out, if non-NULL)
 * on failure, in which case no callback is ever made.
 */
spb_session *spb_session_create(const spb_settings *settings,
                                const spb_session_callbacks *callbacks,
                                void *ctx, char **err_out);

/*
 * Connect, as PuTTY does when a session window opens: CONNECTING, then
 * CONNECTED or FAILED. Only meaningful in the CREATED state.
 *
 * M02 supports the Raw protocol only; other protocols fail with an
 * explanatory message until their milestone (SSH: M04).
 */
void spb_session_start(spb_session *session);

/* Send bytes to the backend (as typed input). Ignored unless the session
 * is CONNECTING or CONNECTED. data is copied before return. */
void spb_session_send(spb_session *session, const void *data, size_t len);

/* Send an end-of-file to the backend (PuTTY's SS_EOF special). */
void spb_session_send_eof(spb_session *session);

/* Disconnect without releasing: the session becomes CLOSED. */
void spb_session_close(spb_session *session);

/*
 * Release the caller's handle. Returns at once; the connection (if any)
 * is torn down on the core thread, and then `released` is called. The
 * handle must not be used after this call. NULL is allowed.
 */
void spb_session_release(spb_session *session);

/* Process-unique, never reused identifier (starts at 1). */
uint64_t spb_session_id(const spb_session *session);

/*
 * Snapshot of the session's configuration (owned). The configuration does
 * not change after creation until live reconfiguration (M07), which will
 * replace this with an asynchronous export.
 */
spb_settings *spb_session_copy_settings(const spb_session *session);

/* ---------- Diagnostics ---------- */

/* Number of sessions whose memory has not been freed yet: created and
 * either not released, or released with teardown still pending. */
size_t spb_debug_live_sessions(void);

/* File descriptors PuTTY had registered with uxsel at the start of the
 * core loop's most recent iteration (sockets and listeners; the loop's
 * own wake-up pipe is not counted). */
size_t spb_debug_uxsel_fds(void);

/* Number of completed core loop iterations. */
uint64_t spb_debug_loop_iterations(void);

/*
 * Schedule fn(ctx) on the core thread after delay_ms, using PuTTY's own
 * timer queue (timing.c). Exercises the loop's timer handling in tests.
 */
void spb_debug_after_delay(uint32_t delay_ms, void (*fn)(void *ctx),
                           void *ctx);

/* Number of spb_settings objects allocated and not yet freed. */
size_t spb_debug_live_settings(void);

#ifdef __cplusplus
}
#endif

#endif /* SWIFTPUTTY_PUTTYBRIDGE_H */
