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
    Ldisc *ldisc;

    /* Terminal (spb_terminal.c); term is created on the core thread. */
    Terminal *term;
    TermWin termwin;
    struct unicode_data ucsdata;
    struct spb_screen *screen;         /* drawing grid + published frame */
    spb_session_state state;
    bool exited;                       /* connection gone or going */

    /* Dialogs awaiting an answer, one per slot as GTK PuTTY has them:
     * the connection's (host key, weak crypto) and the log file's. */
    struct spb_pending_prompt *prompt;
    struct spb_pending_prompt *log_prompt;

    /* The Special Commands last reported (code and arg of each entry),
     * which spb_session_special accepts. */
    SessionSpecial *specials;
    size_t n_specials;

    atomic_uint_fast64_t transport_id; /* bumped by each backend_init */
    spb_settings *created_settings;    /* as created; immutable, any thread */

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
/* Report the backend's Special Commands (none without a connection). */
void spb_session_update_specials(spb_session *s);

/* The Conf a reconfiguration installs: every saved keyword from
 * settings, unsaved keys from the running Conf (ARCHITECTURE 6.3). */
Conf *spb_conf_for_reconfigure(const spb_settings *settings, Conf *running);

/* spb_seat.c: the session's Seat and LogPolicy */
void spb_seat_init(spb_session *s);
/* Forget the connection's pending dialog without answering (the
 * connection is gone). */
void spb_seat_cancel_prompt(spb_session *s);
/* Forget the log file dialog (the session is being released). */
void spb_seat_cancel_log_prompt(spb_session *s);

/* spb_terminal.c */
struct spb_screen *spb_screen_new(void);         /* any thread */
void spb_screen_free(struct spb_screen *screen); /* after the terminal */
void spb_terminal_create(spb_session *s);        /* core thread */
void spb_terminal_free(spb_session *s);          /* core thread */
/* After term_reconfig and backend_reconfig: what GTK PuTTY's frontend
 * does next (character set, cached values, clipboards, scrollback size,
 * redraw). oldconf is the configuration before the change. */
void spb_terminal_reconfigure(spb_session *s, Conf *oldconf);
void spb_terminal_resize(spb_session *s, int cols, int rows,
                         int pixel_width, int pixel_height);
bool spb_terminal_window_pixel_size(spb_session *s, int *w, int *h);
bool spb_terminal_raw_mouse(spb_session *s);     /* core thread */

/* spb_input.c: keyboard, mouse and paste translation (core thread) */
void spb_input_key(spb_session *s, spb_key key, uint32_t mods);

void spb_set_error(char **err_out, const char *fmt, ...)
    PRINTF_LIKE(2, 3);

#endif /* SWIFTPUTTY_SPB_INTERNAL_H */
