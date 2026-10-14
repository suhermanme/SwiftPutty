/*
 * spb_seat.c - the Seat and LogPolicy of a SwiftPutty session.
 *
 * Choices follow upstream's GTK frontend (unix/window.c gtk_seat_vt,
 * gtk_logpolicy_vt) wherever they do not need a terminal or a dialog.
 * Interactive prompts (passwords, host keys, weak crypto) are refused
 * until the SSH milestone (M04) gives them UI; with the Raw protocol, the
 * only one M02 starts, PuTTY never asks.
 */

#include <limits.h>

#include "spb_internal.h"

static spb_session *seat_session(Seat *seat)
{
    return container_of(seat, spb_session, seat);
}

static size_t spb_seat_output(Seat *seat, SeatOutputType type,
                              const void *data, size_t len)
{
    spb_session_emit_output(seat_session(seat), data, len,
                            type == SEAT_OUTPUT_STDERR);
    return 0;                          /* copied out immediately: no backlog */
}

static bool spb_seat_eof(Seat *seat)
{
    return true;   /* as GTK PuTTY: respond to incoming EOF with outgoing */
}

static SeatPromptResult spb_seat_get_userpass_input(Seat *seat, prompts_t *p)
{
    return SPR_SW_ABORT("Interactive prompts are not available yet in "
                        "this build (milestone M04)");
}

static void spb_seat_notify_remote_exit(Seat *seat)
{
    spb_session_notify_remote_exit(seat_session(seat));
}

static void spb_seat_connection_fatal(Seat *seat, const char *message)
{
    spb_session_connection_fatal(seat_session(seat), message);
}

/* GTK PuTTY shows a message box; until the Event Log UI (M10) the text
 * goes to the session's event log. */
static void spb_seat_nonfatal(Seat *seat, const char *message)
{
    char *line = dupprintf("Error: %s", message);
    spb_session_emit_event_log(seat_session(seat), line);
    sfree(line);
}

static SeatPromptResult spb_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return SPR_SW_ABORT("Host key verification is not available yet in "
                        "this build (milestone M04)");
}

static SeatPromptResult spb_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return SPR_SW_ABORT("Weak cryptography confirmation is not available "
                        "yet in this build (milestone M09)");
}

static SeatPromptResult spb_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return SPR_SW_ABORT("Weak host key confirmation is not available "
                        "yet in this build (milestone M09)");
}

/* SwiftPutty is UTF-8 throughout; the character set setting is applied
 * by the terminal (M03/M06). */
static bool spb_seat_is_utf8(Seat *seat)
{
    return true;
}

static const SeatVtable spb_seat_vt = {
    .output = spb_seat_output,
    .eof = spb_seat_eof,
    .sent = nullseat_sent,
    .banner = nullseat_banner,
    .get_userpass_input = spb_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = spb_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = spb_seat_connection_fatal,
    .nonfatal = spb_seat_nonfatal,
    .update_specials_menu = nullseat_update_specials_menu,
    .get_ttymode = nullseat_get_ttymode,
    .set_busy_status = nullseat_set_busy_status,
    .confirm_ssh_host_key = spb_seat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = spb_seat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = spb_seat_confirm_weak_cached_hostkey,
    .prompt_descriptions = nullseat_prompt_descriptions,
    .is_utf8 = spb_seat_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = nullseat_get_window_pixel_size,
    .stripctrl_new = nullseat_stripctrl_new,
    .set_trust_status = nullseat_set_trust_status,
    .can_set_trust_status = nullseat_can_set_trust_status_no,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = nullseat_get_cursor_position,
};

/* ---------- LogPolicy ---------- */

static spb_session *logpolicy_session(LogPolicy *lp)
{
    return container_of(lp, spb_session, logpolicy);
}

static void spb_eventlog(LogPolicy *lp, const char *event)
{
    spb_session_emit_event_log(logpolicy_session(lp), event);
}

/*
 * Only reached when the session log is set to "Ask the user every time"
 * and the file exists. The question needs UI (M10); until then logging
 * is cancelled for the session, which is what answering "Cancel" does.
 */
static int spb_askappend(LogPolicy *lp, Filename *filename,
                         void (*callback)(void *ctx, int result), void *ctx)
{
    spb_session_emit_event_log(
        logpolicy_session(lp),
        "Session logging disabled: asking whether to overwrite an "
        "existing log file is not available yet in this build");
    return 0;
}

/* GTK PuTTY writes these to the terminal; until the terminal exists
 * (M03) they go to the event log. */
static void spb_logging_error(LogPolicy *lp, const char *event)
{
    spb_session_emit_event_log(logpolicy_session(lp), event);
}

static const LogPolicyVtable spb_logpolicy_vt = {
    .eventlog = spb_eventlog,
    .askappend = spb_askappend,
    .logging_error = spb_logging_error,
    .verbose = null_lp_verbose_yes,
};

void spb_seat_init(spb_session *s)
{
    s->seat.vt = &spb_seat_vt;
    s->logpolicy.vt = &spb_logpolicy_vt;
}
