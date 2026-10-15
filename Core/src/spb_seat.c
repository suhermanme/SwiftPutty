/*
 * spb_seat.c - the Seat and LogPolicy of a SwiftPutty session.
 *
 * Choices follow upstream's GTK frontend (unix/window.c gtk_seat_vt,
 * gtk_logpolicy_vt; unix/dialog.c for the dialogs). Login prompts
 * (user name, password, keyboard-interactive) are answered in the
 * terminal, as GTK PuTTY does. Host key and weak-crypto confirmations are
 * dialogs: the frontend gets a prompt callback and answers later with
 * spb_session_answer_prompt, while PuTTY waits (SPR_INCOMPLETE).
 */

#include <limits.h>
#include <string.h>

#include "spb_internal.h"
#include "terminal/terminal.h"         /* stripctrl_new_term */

static spb_session *seat_session(Seat *seat)
{
    return container_of(seat, spb_session, seat);
}

/* unix/window.c gtk_seat_output: everything goes to the terminal, whose
 * backlog throttles the backend (TermWin unthrottle releases it). */
static size_t spb_seat_output(Seat *seat, SeatOutputType type,
                              const void *data, size_t len)
{
    spb_session *s = seat_session(seat);
    spb_session_emit_output(s, data, len, type == SEAT_OUTPUT_STDERR);
    return term_data(s->term, data, len);
}

static bool spb_seat_eof(Seat *seat)
{
    return true;   /* as GTK PuTTY: respond to incoming EOF with outgoing */
}

/* unix/window.c gtk_seat_get_userpass_input, minus the command line. */
static SeatPromptResult spb_seat_get_userpass_input(Seat *seat, prompts_t *p)
{
    return term_get_userpass_input(seat_session(seat)->term, p);
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

/* ---------- Dialogs ---------- */

struct spb_pending_prompt {
    uint64_t id;
    spb_prompt_kind kind;
    void (*callback)(void *ctx, SeatPromptResult result);
    /* The log file question answers with an int instead (LogPolicy). */
    void (*int_callback)(void *ctx, int result);
    void *callback_ctx;
    /* Host key prompts: what "Accept" stores. */
    char *host, *keytype, *keystr;
    int port;
};

static atomic_uint_fast64_t next_prompt_id = 1;

static void free_prompt(struct spb_pending_prompt *pp)
{
    sfree(pp->host);
    sfree(pp->keytype);
    sfree(pp->keystr);
    sfree(pp);
}

static spb_dialog_item_type dialog_item_type(SeatDialogTextType type,
                                             bool *keep)
{
    *keep = true;
    switch (type) {
      case SDT_PARA:                  return SPB_DIALOG_PARAGRAPH;
      case SDT_DISPLAY:               return SPB_DIALOG_DISPLAY;
      case SDT_SCARY_HEADING:         return SPB_DIALOG_SCARY_HEADING;
      case SDT_TITLE:                 return SPB_DIALOG_TITLE;
      case SDT_PROMPT:                return SPB_DIALOG_PROMPT;
      case SDT_MORE_INFO_KEY:         return SPB_DIALOG_MORE_INFO_KEY;
      case SDT_MORE_INFO_VALUE_SHORT: return SPB_DIALOG_MORE_INFO_SHORT;
      case SDT_MORE_INFO_VALUE_BLOB:  return SPB_DIALOG_MORE_INFO_BLOB;
      default:
        *keep = false;                 /* SDT_BATCH_ABORT: console only */
        return SPB_DIALOG_PARAGRAPH;
    }
}

static void cancel_slot(spb_session *s, struct spb_pending_prompt **slot)
{
    struct spb_pending_prompt *pp = *slot;
    if (!pp)
        return;
    *slot = NULL;
    uint64_t id = pp->id;
    free_prompt(pp);
    if (!atomic_load(&s->released) && s->cb.prompt_cancelled)
        s->cb.prompt_cancelled(s->cb_ctx, id);
}

/*
 * Hand a dialog to the frontend, in the given slot (GTK PuTTY's dialog
 * slots: one question of each kind at a time). Returns false, having
 * freed pp, if there is no frontend to ask.
 */
static bool ask_in_slot(spb_session *s, struct spb_pending_prompt **slot,
                        struct spb_pending_prompt *pp, SeatDialogText *text)
{
    if (atomic_load(&s->released) || !s->cb.prompt) {
        free_prompt(pp);
        return false;
    }
    cancel_slot(s, slot);
    pp->id = atomic_fetch_add(&next_prompt_id, 1);
    *slot = pp;

    spb_dialog_item *items = snewn(text->nitems ? text->nitems : 1,
                                   spb_dialog_item);
    size_t n = 0;
    for (size_t i = 0; i < text->nitems; i++) {
        bool keep;
        spb_dialog_item_type type = dialog_item_type(text->items[i].type,
                                                     &keep);
        if (keep) {
            items[n].type = type;
            items[n].text = text->items[i].text;
            n++;
        }
    }
    spb_prompt prompt = {
        .kind = pp->kind, .id = pp->id, .items = items, .n_items = n,
    };
    s->cb.prompt(s->cb_ctx, &prompt);
    sfree(items);
    return true;
}

/*
 * A connection dialog. Returns SPR_INCOMPLETE (PuTTY waits for the
 * callback) or, with no frontend to ask, an abort.
 */
static SeatPromptResult ask(spb_session *s, struct spb_pending_prompt *pp,
                            SeatDialogText *text)
{
    if (!ask_in_slot(s, &s->prompt, pp, text))
        return SPR_SW_ABORT("No user interface is available to answer "
                            "this question");
    return SPR_INCOMPLETE;
}

/* unix/dialog.c gtk_seat_confirm_ssh_host_key */
static SeatPromptResult spb_seat_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    struct spb_pending_prompt *pp = snew(struct spb_pending_prompt);
    memset(pp, 0, sizeof(*pp));
    pp->kind = SPB_PROMPT_HOST_KEY;
    pp->callback = callback;
    pp->callback_ctx = ctx;
    pp->host = dupstr(host);
    pp->port = port;
    pp->keytype = dupstr(keytype);
    pp->keystr = dupstr(keystr);
    return ask(seat_session(seat), pp, text);
}

static SeatPromptResult confirm_simple(
    Seat *seat, spb_prompt_kind kind, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    struct spb_pending_prompt *pp = snew(struct spb_pending_prompt);
    memset(pp, 0, sizeof(*pp));
    pp->kind = kind;
    pp->callback = callback;
    pp->callback_ctx = ctx;
    return ask(seat_session(seat), pp, text);
}

static SeatPromptResult spb_seat_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return confirm_simple(seat, SPB_PROMPT_WEAK_CRYPTO, text, callback, ctx);
}

static SeatPromptResult spb_seat_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
    return confirm_simple(seat, SPB_PROMPT_WEAK_CACHED_HOST_KEY, text,
                          callback, ctx);
}

/* unix/dialog.c simple_prompt_result_int_callback, for askappend */
static void answer_log_prompt(spb_session *s, spb_prompt_answer answer)
{
    struct spb_pending_prompt *pp = s->log_prompt;
    s->log_prompt = NULL;
    /* As GTK's buttons: Overwrite 2, Append 1, Disable 0. */
    int mode = answer == SPB_ANSWER_LOG_OVERWRITE ? 2 :
        answer == SPB_ANSWER_LOG_APPEND ? 1 : 0;
    void (*callback)(void *, int) = pp->int_callback;
    void *callback_ctx = pp->callback_ctx;
    free_prompt(pp);
    callback(callback_ctx, mode);
}

/* unix/dialog.c confirm_ssh_host_key_result_callback and
 * simple_prompt_result_spr_callback */
static void answer_prompt(spb_session *s, uint64_t id,
                          spb_prompt_answer answer)
{
    /* The log file question outlives the connection: the session's
     * LogContext may still hold output queued while it was asked. */
    if (s->log_prompt && s->log_prompt->id == id) {
        answer_log_prompt(s, answer);
        return;
    }

    struct spb_pending_prompt *pp = s->prompt;
    if (!pp || pp->id != id || s->exited)
        return;                        /* stale: already answered or gone */
    s->prompt = NULL;

    SeatPromptResult result;
    if (answer != SPB_ANSWER_ACCEPT_ONCE &&
        answer != SPB_ANSWER_ACCEPT_AND_STORE) {
        result = SPR_USER_ABORT;
    } else {
        if (pp->kind == SPB_PROMPT_HOST_KEY &&
            answer == SPB_ANSWER_ACCEPT_AND_STORE)
            store_host_key(&s->seat, pp->host, pp->port, pp->keytype,
                           pp->keystr);
        result = SPR_OK;
    }
    void (*callback)(void *, SeatPromptResult) = pp->callback;
    void *callback_ctx = pp->callback_ctx;
    free_prompt(pp);
    callback(callback_ctx, result);
}

void spb_seat_cancel_prompt(spb_session *s)
{
    cancel_slot(s, &s->prompt);
}

/* Without an answer the LogContext stays in its "opening" state; it is
 * freed right after this, which discards anything it queued. */
void spb_seat_cancel_log_prompt(spb_session *s)
{
    cancel_slot(s, &s->log_prompt);
}

typedef struct answer_cmd {
    spb_session *s;
    uint64_t id;
    spb_prompt_answer answer;
} answer_cmd;

static void cmd_answer(void *vctx)
{
    answer_cmd *cmd = vctx;
    answer_prompt(cmd->s, cmd->id, cmd->answer);
    sfree(cmd);
}

void spb_session_answer_prompt(spb_session *s, uint64_t prompt_id,
                               spb_prompt_answer answer)
{
    answer_cmd *cmd = snew(answer_cmd);
    cmd->s = s;
    cmd->id = prompt_id;
    cmd->answer = answer;
    if (!spb_loop_post(cmd_answer, cmd))
        modalfatalbox("SwiftPutty internal error: prompt answered after "
                      "core shutdown");
}

/* unix/dialog.c gtk_seat_prompt_descriptions: the wording PuTTY's
 * dialog text uses for the buttons. */
static const SeatDialogPromptDescriptions *spb_seat_prompt_descriptions(
    Seat *seat)
{
    static const SeatDialogPromptDescriptions descs = {
        .hk_accept_action = "press \"Accept\"",
        .hk_connect_once_action = "press \"Connect Once\"",
        .hk_cancel_action = "press \"Cancel\"",
        .hk_cancel_action_Participle = "Pressing \"Cancel\"",
        .weak_accept_action = "press \"Yes\"",
        .weak_cancel_action = "press \"No\"",
    };
    return &descs;
}

static bool spb_seat_is_utf8(Seat *seat)
{
    return seat_session(seat)->ucsdata.line_codepage == CS_UTF8;
}

static char *spb_seat_get_ttymode(Seat *seat, const char *mode)
{
    return term_get_ttymode(seat_session(seat)->term, mode);
}

static bool spb_seat_get_window_pixel_size(Seat *seat, int *w, int *h)
{
    return spb_terminal_window_pixel_size(seat_session(seat), w, h);
}

static StripCtrlChars *spb_seat_stripctrl_new(
    Seat *seat, BinarySink *bs_out, SeatInteractionContext sic)
{
    return stripctrl_new_term(bs_out, false, 0, seat_session(seat)->term);
}

static void spb_seat_set_trust_status(Seat *seat, bool trusted)
{
    term_set_trust_status(seat_session(seat)->term, trusted);
}

static bool spb_seat_get_cursor_position(Seat *seat, int *x, int *y)
{
    term_get_cursor_position(seat_session(seat)->term, x, y);
    return true;
}

static const SeatVtable spb_seat_vt = {
    .output = spb_seat_output,
    .eof = spb_seat_eof,
    .sent = nullseat_sent,
    .banner = nullseat_banner_to_stderr,
    .get_userpass_input = spb_seat_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = spb_seat_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = spb_seat_connection_fatal,
    .nonfatal = spb_seat_nonfatal,
    .update_specials_menu = nullseat_update_specials_menu,
    .get_ttymode = spb_seat_get_ttymode,
    .set_busy_status = nullseat_set_busy_status,
    .confirm_ssh_host_key = spb_seat_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = spb_seat_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = spb_seat_confirm_weak_cached_hostkey,
    .prompt_descriptions = spb_seat_prompt_descriptions,
    .is_utf8 = spb_seat_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = spb_seat_get_window_pixel_size,
    .stripctrl_new = spb_seat_stripctrl_new,
    .set_trust_status = spb_seat_set_trust_status,
    .can_set_trust_status = nullseat_can_set_trust_status_yes,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = spb_seat_get_cursor_position,
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
 * unix/dialog.c gtkdlg_askappend: reached when the session log is set to
 * "Ask the user every time" and the file exists. Returns -1 (PuTTY
 * queues log data until the callback) or, with no frontend to ask, 0
 * (logging disabled, as GTK's "Disable").
 */
static int spb_askappend(LogPolicy *lp, Filename *filename,
                         void (*callback)(void *ctx, int result), void *ctx)
{
    static const char msgtemplate[] =
        "The session log file \"%.*s\" already exists. "
        "You can overwrite it with a new session log, "
        "append your session log to the end of it, "
        "or disable session logging for this session.";
    spb_session *s = logpolicy_session(lp);

    struct spb_pending_prompt *pp = snew(struct spb_pending_prompt);
    memset(pp, 0, sizeof(*pp));
    pp->kind = SPB_PROMPT_LOG_FILE_EXISTS;
    pp->int_callback = callback;
    pp->callback_ctx = ctx;

    char *title = dupprintf("%s Log to File", appname);
    char *message = dupprintf(msgtemplate, FILENAME_MAX, filename->path);
    SeatDialogText *text = seat_dialog_text_new();
    seat_dialog_text_append(text, SDT_TITLE, "%s", title);
    seat_dialog_text_append(text, SDT_PARA, "%s", message);
    bool asked = ask_in_slot(s, &s->log_prompt, pp, text);
    seat_dialog_text_free(text);
    sfree(message);
    sfree(title);
    return asked ? -1 : 0;
}

/* unix/window.c gtk_logging_error: shown in the terminal window. */
static void spb_logging_error(LogPolicy *lp, const char *event)
{
    spb_session *s = logpolicy_session(lp);
    seat_stderr_pl(&s->seat, ptrlen_from_asciz(event));
    seat_stderr_pl(&s->seat, PTRLEN_LITERAL("\r\n"));
}

/* Patch 0006: structured port forwarding status. */
static void spb_lp_portfwd_status(LogPolicy *lp, const PortFwdStatus *st)
{
    spb_session *s = logpolicy_session(lp);
    if (atomic_load(&s->released) || !s->cb.portfwd_status)
        return;
    spb_portfwd_state state;
    switch (st->kind) {
      case PFS_LISTENING:        state = SPB_PORTFWD_LISTENING; break;
      case PFS_LISTEN_FAILED:    state = SPB_PORTFWD_LISTEN_FAILED; break;
      case PFS_REMOTE_REQUESTED: state = SPB_PORTFWD_REMOTE_REQUESTED; break;
      case PFS_REMOTE_ENABLED:   state = SPB_PORTFWD_REMOTE_ENABLED; break;
      case PFS_REMOTE_REFUSED:   state = SPB_PORTFWD_REMOTE_REFUSED; break;
      case PFS_DUPLICATE:        state = SPB_PORTFWD_DUPLICATE; break;
      default:                   state = SPB_PORTFWD_CLOSED; break;
    }
    spb_portfwd_status status = {
        .state = state, .key = st->key, .value = st->value,
        .message = st->message,
    };
    s->cb.portfwd_status(s->cb_ctx, &status);
}

static const LogPolicyVtable spb_logpolicy_vt = {
    .eventlog = spb_eventlog,
    .askappend = spb_askappend,
    .logging_error = spb_logging_error,
    .verbose = null_lp_verbose_yes,
    .portfwd_status = spb_lp_portfwd_status,
};

void spb_seat_init(spb_session *s)
{
    s->seat.vt = &spb_seat_vt;
    s->logpolicy.vt = &spb_logpolicy_vt;
}
