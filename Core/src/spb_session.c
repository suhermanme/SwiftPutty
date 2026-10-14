/*
 * spb_session.c - sessions, executed on the PuTTY core thread.
 *
 * A session owns the PuTTY objects a frontend window owns upstream
 * (docs/ARCHITECTURE.md section 2.3): its Conf, a LogContext, a
 * Terminal (spb_terminal.c), and while connected a Backend and an Ldisc.
 *
 * Every public entry point except create/id/copy_settings only posts a
 * command; the work happens on the core thread, in call order. The
 * connection lifecycle follows upstream's GTK frontend (unix/window.c:
 * start_backend, exit_callback, connection_fatal_callback,
 * destroy_inst_connection).
 */

#include <stdlib.h>
#include <string.h>

#include "spb_internal.h"

static atomic_uint_fast64_t next_session_id = 1;

/* Sessions with a live connection that may change state by itself;
 * core thread only. */
static spb_session *active_head;

static void active_add(spb_session *s)
{
    s->active_next = active_head;
    s->active_prev = NULL;
    if (active_head)
        active_head->active_prev = s;
    active_head = s;
    s->active = true;
}

static void active_remove(spb_session *s)
{
    if (!s->active)
        return;
    if (s->active_prev)
        s->active_prev->active_next = s->active_next;
    else
        active_head = s->active_next;
    if (s->active_next)
        s->active_next->active_prev = s->active_prev;
    s->active_next = s->active_prev = NULL;
    s->active = false;
}

/* ---------- Callback emission (core thread) ---------- */

static bool callbacks_enabled(spb_session *s)
{
    return !atomic_load(&s->released);
}

void spb_session_set_state(spb_session *s, spb_session_state state,
                           const char *detail)
{
    if (spb_session_state_is_final(s->state) || state <= s->state)
        return;                        /* states only move forward */
    s->state = state;
    if (callbacks_enabled(s) && s->cb.state_changed)
        s->cb.state_changed(s->cb_ctx, state, detail);
}

void spb_session_emit_event_log(spb_session *s, const char *line)
{
    if (callbacks_enabled(s) && s->cb.event_log)
        s->cb.event_log(s->cb_ctx, line);
}

void spb_session_emit_output(spb_session *s, const void *data, size_t len,
                             bool is_stderr)
{
    if (len && callbacks_enabled(s) && s->cb.output)
        s->cb.output(s->cb_ctx, data, len, is_stderr);
}

static void emit_remote_exit(spb_session *s, int exit_code)
{
    if (callbacks_enabled(s) && s->cb.remote_exit)
        s->cb.remote_exit(s->cb_ctx, (int32_t)exit_code);
}

/* ---------- Connection lifecycle (core thread) ---------- */

/* unix/window.c destroy_inst_connection */
static void destroy_connection(spb_session *s)
{
    s->exited = true;
    active_remove(s);
    /* A dialog's answer would call into the backend freed below. */
    spb_seat_cancel_prompt(s);
    if (s->ldisc) {
        ldisc_free(s->ldisc);
        s->ldisc = NULL;
    }
    if (s->backend) {
        backend_free(s->backend);
        s->backend = NULL;
    }
    if (s->term)
        term_provide_backend(s->term, NULL);
    delete_callbacks_for_context(s);
}

/* unix/window.c exit_callback */
static void exit_callback(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    int exit_code;

    if (!s->exited && s->backend &&
        (exit_code = backend_exitcode(s->backend)) >= 0) {
        destroy_connection(s);
        emit_remote_exit(s, exit_code);
        spb_session_set_state(s, SPB_SESSION_CLOSED,
                              exit_code == INT_MAX ?
                              "Connection closed after an error" :
                              "Connection closed by remote host");
    }
}

void spb_session_notify_remote_exit(spb_session *s)
{
    queue_toplevel_callback(exit_callback, s);
}

static void connection_fatal_callback(void *vctx)
{
    destroy_connection((spb_session *)vctx);
}

void spb_session_connection_fatal(spb_session *s, const char *message)
{
    /* As GTK PuTTY: report, suppress normal exit handling, and drop the
     * connection from top level (we may be deep inside the backend). */
    s->exited = true;
    spb_session_set_state(s, SPB_SESSION_FAILED, message);
    queue_toplevel_callback(connection_fatal_callback, s);
}

/* Protocols whose frontend requirements exist so far. */
static const char *unsupported_protocol_reason(int protocol)
{
    switch (protocol) {
      case PROT_RAW:
      case PROT_SSH:
      case PROT_SSHCONN:
        return NULL;
      default:
        return "This connection type is not available yet in this build "
            "(milestone M11)";
    }
}

/* unix/window.c start_backend */
static void cmd_start(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    if (s->state != SPB_SESSION_CREATED)
        return;

    int protocol = conf_get_int(s->conf, CONF_protocol);
    const char *reason = unsupported_protocol_reason(protocol);
    const BackendVtable *vt = backend_vt_from_proto(protocol);
    if (!reason && !vt)
        reason = "Unknown connection type";
    if (reason) {
        s->exited = true;
        spb_session_set_state(s, SPB_SESSION_FAILED, reason);
        return;
    }

    spb_session_set_state(s, SPB_SESSION_CONNECTING, NULL);

    /* As GTK start_backend: PuTTY's own output is trusted until the
     * backend says otherwise (the trust sigil marks it after that). */
    seat_set_trust_status(&s->seat, true);

    char *realhost = NULL;
    char *error = backend_init(
        vt, &s->seat, &s->backend, s->logctx, s->conf,
        conf_get_str(s->conf, CONF_host), conf_get_int(s->conf, CONF_port),
        &realhost, conf_get_bool(s->conf, CONF_tcp_nodelay),
        conf_get_bool(s->conf, CONF_tcp_keepalives));

    if (error) {
        sfree(realhost);
        char *msg = dupprintf("Unable to open connection to %s:\n%s",
                              conf_dest(s->conf), error);
        sfree(error);
        /* A failed init still hands back a backend for the frontend to
         * free (GTK PuTTY frees it in destroy_inst_connection). */
        destroy_connection(s);
        spb_session_set_state(s, SPB_SESSION_FAILED, msg);
        sfree(msg);
        return;
    }

    term_setup_window_titles(s->term, realhost);
    sfree(realhost);
    term_provide_backend(s->term, s->backend);
    s->ldisc = ldisc_create(s->conf, s->term, s->backend, &s->seat);
    active_add(s);
}

/*
 * PuTTY has no "connected" notification for frontends; GUI PuTTY simply
 * lets the user type, and the backend's sendok() says whether input is
 * accepted yet. So the loop asks each connecting backend once per
 * iteration.
 */
void spb_sessions_after_iteration(void)
{
    for (spb_session *s = active_head, *next; s; s = next) {
        next = s->active_next;
        if (s->state == SPB_SESSION_CONNECTING && s->backend &&
            !s->exited && backend_sendok(s->backend))
            spb_session_set_state(s, SPB_SESSION_CONNECTED, NULL);
    }
}

typedef struct send_cmd {
    spb_session *s;
    size_t len;
    char data[];
} send_cmd;

static void cmd_send(void *vctx)
{
    send_cmd *cmd = (send_cmd *)vctx;
    spb_session *s = cmd->s;
    if (s->backend && !s->exited)
        backend_send(s->backend, cmd->data, cmd->len);
    smemclr(cmd->data, cmd->len);      /* may be typed secrets */
    sfree(cmd);
}

static void cmd_send_eof(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    if (s->backend && !s->exited)
        backend_special(s->backend, SS_EOF, 0);
}

static void cmd_close(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    if (spb_session_state_is_final(s->state))
        return;
    if (s->backend)
        logevent(s->logctx, "Session closed by user");
    destroy_connection(s);
    spb_session_set_state(s, SPB_SESSION_CLOSED, "Session closed by user");
}

static void cmd_setup_terminal(void *vctx)
{
    spb_terminal_create((spb_session *)vctx);
}

static void cmd_release(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    destroy_connection(s);
    spb_terminal_free(s);
    spb_seat_cancel_log_prompt(s);
    log_free(s->logctx);
    conf_free(s->conf);
    spb_screen_free(s->screen);

    if (s->cb.released)
        s->cb.released(s->cb_ctx);
    sfree(s);
    atomic_fetch_sub(&spb_live_sessions, 1);
}

/* ---------- Public API ---------- */

static void post(spb_session *s, spb_command_fn fn, void *ctx);

spb_session *spb_session_create(const spb_settings *settings,
                                const spb_session_callbacks *callbacks,
                                void *ctx, char **err_out)
{
    if (err_out)
        *err_out = NULL;
    if (!spb_core_is_initialised()) {
        spb_set_error(err_out, "PuTTY core is not initialised");
        return NULL;
    }
    if (!settings) {
        spb_set_error(err_out, "No settings supplied");
        return NULL;
    }

    spb_session *s = snew(spb_session);
    memset(s, 0, sizeof(*s));
    s->id = atomic_fetch_add(&next_session_id, 1);
    if (callbacks)
        s->cb = *callbacks;
    s->cb_ctx = ctx;
    atomic_init(&s->released, false);
    s->state = SPB_SESSION_CREATED;
    spb_seat_init(s);

    /*
     * Building the Conf touches only the Conf and the settings map, so it
     * is done here on the caller's thread. log_init only allocates.
     */
    s->conf = conf_new();
    spb_settings_load_into_conf(settings, s->conf);
    prepare_session(s->conf);          /* as GTK new_session_window */
    s->logctx = log_init(&s->logpolicy, s->conf);
    s->screen = spb_screen_new();

    atomic_fetch_add(&spb_live_sessions, 1);
    atomic_fetch_add(&spb_open_sessions, 1);
    /* The Terminal is built on the core thread, before anything else the
     * caller can queue for this session. */
    post(s, cmd_setup_terminal, s);
    return s;
}

/*
 * Post a command for a session. The caller holds the handle, so the
 * session is alive; the core is running because shutdown is refused
 * while any handle is open.
 */
static void post(spb_session *s, spb_command_fn fn, void *ctx)
{
    if (!spb_loop_post(fn, ctx))
        modalfatalbox("SwiftPutty internal error: session %llu used "
                      "after core shutdown", (unsigned long long)s->id);
}

void spb_session_start(spb_session *s)
{
    post(s, cmd_start, s);
}

void spb_session_send(spb_session *s, const void *data, size_t len)
{
    if (!len)
        return;
    send_cmd *cmd = smalloc(sizeof(send_cmd) + len);
    cmd->s = s;
    cmd->len = len;
    memcpy(cmd->data, data, len);
    post(s, cmd_send, cmd);
}

void spb_session_send_eof(spb_session *s)
{
    post(s, cmd_send_eof, s);
}

void spb_session_close(spb_session *s)
{
    post(s, cmd_close, s);
}

void spb_session_release(spb_session *s)
{
    if (!s)
        return;
    /* From here on, callbacks that have not started are suppressed. */
    atomic_store(&s->released, true);
    post(s, cmd_release, s);
    /* Only now may spb_core_shutdown() proceed: the teardown is queued
     * ahead of its stop command. */
    atomic_fetch_sub(&spb_open_sessions, 1);
}

uint64_t spb_session_id(const spb_session *s)
{
    return s->id;
}

spb_settings *spb_session_copy_settings(const spb_session *s)
{
    /* s->conf is not modified after creation (until M07). */
    spb_settings *settings = spb_settings_new_empty();
    spb_settings_save_from_conf(settings, s->conf);
    return settings;
}
