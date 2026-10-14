/*
 * Internal declarations shared between the SwiftPutty bridge sources.
 * Never included by Swift.
 */

#ifndef SWIFTPUTTY_SPB_INTERNAL_H
#define SWIFTPUTTY_SPB_INTERNAL_H

#include <stdatomic.h>

#include "putty.h"
#include "storage.h"
#include "tree234.h"

#include "PuTTYBridge.h"

/* spb_settings.c */
struct spb_settings {
    tree234 *entries;                  /* of struct spb_setting, by key */
};

void spb_settings_load_into_conf(const spb_settings *settings, Conf *conf);
void spb_settings_save_from_conf(spb_settings *settings, Conf *conf);

/* spb_storage.c: storage.h session handles backed by an spb_settings */
settings_r *spb_settings_reader(const spb_settings *settings);
settings_w *spb_settings_writer(spb_settings *settings);

/* spb_core.c */
extern atomic_size_t spb_live_sessions;   /* allocated session objects */
extern atomic_size_t spb_open_sessions;   /* handles not yet released */
extern atomic_size_t spb_live_settings;

/* spb_eventloop.c: the core thread (D-003) */
typedef void (*spb_command_fn)(void *ctx);

bool spb_loop_start(char **err_out);
void spb_loop_stop(void);              /* runs queued commands, then joins */
/* Queue fn(ctx) to run on the core thread. Returns false (fn not queued)
 * if the loop is not running. */
bool spb_loop_post(spb_command_fn fn, void *ctx);
/* Run fn(ctx) on the core thread and wait for it (inline if already on
 * the core thread). fn may be NULL (a barrier). */
bool spb_loop_run_sync(spb_command_fn fn, void *ctx);
bool spb_loop_on_core_thread(void);
void spb_loop_assert_core_thread(void);

/* spb_session.c */
struct spb_session {
    uint64_t id;
    spb_session_callbacks cb;
    void *cb_ctx;
    atomic_bool released;              /* set by spb_session_release */

    /* Everything below is used on the core thread only, except that conf
     * is built by spb_session_create and read by copy_settings. */
    Conf *conf;                        /* the CURRENT runtime config */
    Seat seat;
    LogPolicy logpolicy;
    LogContext *logctx;
    Backend *backend;
    spb_session_state state;
    bool exited;                       /* connection gone or going */

    bool active;                       /* in the active-session list */
    spb_session *active_next, *active_prev;
};

static inline bool spb_session_state_is_final(spb_session_state state)
{
    return state == SPB_SESSION_CLOSED || state == SPB_SESSION_FAILED;
}

void spb_sessions_after_iteration(void); /* run by the loop */
void spb_session_set_state(spb_session *s, spb_session_state state,
                           const char *detail);
void spb_session_emit_event_log(spb_session *s, const char *line);
void spb_session_emit_output(spb_session *s, const void *data, size_t len,
                             bool is_stderr);
void spb_session_notify_remote_exit(spb_session *s);
void spb_session_connection_fatal(spb_session *s, const char *message);

/* spb_seat.c: the session's Seat and LogPolicy */
void spb_seat_init(spb_session *s);

void spb_set_error(char **err_out, const char *fmt, ...)
    PRINTF_LIKE(2, 3);

#endif /* SWIFTPUTTY_SPB_INTERNAL_H */
