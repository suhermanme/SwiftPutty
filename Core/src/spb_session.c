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

/* unix/window.c gtk_seat_update_specials_menu: the list is the
 * backend's, flattened for the frontend. The final SS_EXITMENU closes
 * the top-level list and is not passed on. */
void spb_session_update_specials(spb_session *s)
{
    const SessionSpecial *list = NULL;
    if (s->backend && !s->exited)
        list = backend_get_specials(s->backend);

    size_t n = 0;
    for (int depth = 1; list && depth > 0; n++) {
        if (list[n].code == SS_SUBMENU)
            depth++;
        else if (list[n].code == SS_EXITMENU)
            depth--;
    }
    if (n)
        n--;                           /* the closing SS_EXITMENU */

    sfree(s->specials);
    s->specials = n ? snewn(n, SessionSpecial) : NULL;
    s->n_specials = n;
    spb_special *out = n ? snewn(n, spb_special) : NULL;
    for (size_t i = 0; i < n; i++) {
        s->specials[i] = list[i];
        s->specials[i].name = NULL;    /* owned by the backend */
        spb_special_kind kind;
        switch (list[i].code) {
          case SS_SEP:      kind = SPB_SPECIAL_SEPARATOR; break;
          case SS_SUBMENU:  kind = SPB_SPECIAL_SUBMENU; break;
          case SS_EXITMENU: kind = SPB_SPECIAL_END_SUBMENU; break;
          default:          kind = SPB_SPECIAL_COMMAND; break;
        }
        out[i] = (spb_special){
            .kind = kind,
            .name = kind == SPB_SPECIAL_COMMAND || kind == SPB_SPECIAL_SUBMENU ?
                list[i].name : NULL,
            .code = list[i].code, .arg = list[i].arg,
        };
    }
    if (callbacks_enabled(s) && s->cb.specials_changed)
        s->cb.specials_changed(s->cb_ctx, out, n);
    sfree(out);
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
    if (s->n_specials)
        spb_session_update_specials(s);  /* as GTK: the menu goes */
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

typedef struct input_special {
    spb_session *s;
    int32_t code, arg;
} input_special;

/* unix/window.c start_backend */
static void start_backend(spb_session *s)
{
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

    atomic_fetch_add(&s->transport_id, 1);
    term_setup_window_titles(s->term, realhost);
    sfree(realhost);
    term_provide_backend(s->term, s->backend);
    s->ldisc = ldisc_create(s->conf, s->term, s->backend, &s->seat);
    active_add(s);
    spb_session_update_specials(s);
}

static void cmd_start(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    if (s->state == SPB_SESSION_CREATED)
        start_backend(s);
}

/* unix/window.c restart_session_menuitem, which GTK PuTTY enables once
 * the connection is gone. */
static void cmd_restart(void *vctx)
{
    spb_session *s = (spb_session *)vctx;
    if (!spb_session_state_is_final(s->state))
        return;
    /* A fatal error drops the connection from a callback that may not
     * have run yet. */
    destroy_connection(s);
    logevent(s->logctx, "----- Session restarted -----");
    term_pwron(s->term, false);
    s->exited = false;
    s->state = SPB_SESSION_CREATED;    /* not reported: CONNECTING follows */
    start_backend(s);
}

/* unix/window.c special_menuitem */
static void cmd_special(void *vctx)
{
    input_special *cmd = vctx;
    spb_session *s = cmd->s;
    bool listed = false;
    for (size_t i = 0; i < s->n_specials && !listed; i++)
        listed = (int32_t)s->specials[i].code == cmd->code &&
            s->specials[i].arg == cmd->arg &&
            cmd->code != SS_SEP && cmd->code != SS_SUBMENU &&
            cmd->code != SS_EXITMENU;
    if (listed && s->backend && !s->exited)
        backend_special(s->backend, (SessionSpecialCode)cmd->code, cmd->arg);
    sfree(cmd);
}

typedef struct close_warning_cmd {
    spb_session *s;
    uint64_t request;
} close_warning_cmd;

/* unix/window.c delete_window: there is something to warn about while
 * the connection has not exited. */
static void cmd_close_warning(void *vctx)
{
    close_warning_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    bool connected = !s->exited && !spb_session_state_is_final(s->state);
    char *text = NULL;
    if (connected && s->backend && s->backend->vt->close_warn_text)
        text = s->backend->vt->close_warn_text(s->backend);
    if (callbacks_enabled(s) && s->cb.close_warning)
        s->cb.close_warning(s->cb_ctx, cmd->request, connected, text);
    sfree(text);
    sfree(cmd);
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

/* ---------- Live reconfiguration (M07) ---------- */

typedef struct reconfig_cmd {
    spb_session *s;
    uint64_t request;
    spb_settings *settings;            /* reconfigure only */
} reconfig_cmd;

/* unix/window.c change_settings_menuitem: a copy of the running Conf,
 * with the live window title (term_pre_reconfig). */
static void cmd_export_settings(void *vctx)
{
    reconfig_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    Conf *copy = conf_copy(s->conf);
    if (s->term)
        term_pre_reconfig(s->term, copy);
    spb_settings *settings = spb_settings_new_empty();
    spb_settings_save_from_conf(settings, copy);
    conf_free(copy);
    int32_t info = s->backend && !s->exited ? backend_cfg_info(s->backend) : 0;
    if (callbacks_enabled(s) && s->cb.settings_exported)
        s->cb.settings_exported(s->cb_ctx, cmd->request, settings, info);
    else
        spb_settings_free(settings);
    sfree(cmd);
}

/*
 * Keys PuTTY does not save (e.g. ssh_nc_host) cannot come from a
 * settings map, and load_open_settings() resets them to their defaults;
 * they keep their running values (docs/ARCHITECTURE.md section 6.3). None
 * of them is a mapping.
 */
static void keep_unsaved_keys(Conf *dst, Conf *src)
{
    for (int key = 0; key < N_CONFIG_OPTIONS; key++) {
        const ConfKeyInfo *info = &conf_key_info[key];
        if (!info->not_saved || info->subkey_type != CONF_TYPE_NONE)
            continue;
        switch (info->value_type) {
          case CONF_TYPE_BOOL:
            conf_set_bool(dst, key, conf_get_bool(src, key));
            break;
          case CONF_TYPE_INT:
            conf_set_int(dst, key, conf_get_int(src, key));
            break;
          case CONF_TYPE_STR:
            conf_set_str(dst, key, conf_get_str(src, key));
            break;
          case CONF_TYPE_UTF8:
            conf_set_utf8(dst, key, conf_get_utf8(src, key));
            break;
          case CONF_TYPE_STR_AMBI: {
            bool utf8;
            const char *value = conf_get_str_ambi(src, key, &utf8);
            if (utf8)
                conf_set_utf8(dst, key, value);
            else
                conf_set_str(dst, key, value);
            break;
          }
          case CONF_TYPE_FILENAME:
            conf_set_filename(dst, key, conf_get_filename(src, key));
            break;
          case CONF_TYPE_FONT:
            conf_set_fontspec(dst, key, conf_get_fontspec(src, key));
            break;
        }
    }
}

Conf *spb_conf_for_reconfigure(const spb_settings *settings, Conf *running)
{
    Conf *conf = conf_new();
    spb_settings_load_into_conf(settings, conf);
    keep_unsaved_keys(conf, running);
    return conf;
}

/* unix/window.c after_change_settings_dialog */
static void cmd_reconfigure(void *vctx)
{
    reconfig_cmd *cmd = vctx;
    spb_session *s = cmd->s;

    Conf *newconf = spb_conf_for_reconfigure(cmd->settings, s->conf);
    Conf *oldconf = s->conf;

    /* log_reconfig closes and reopens the log if its name or type
     * changes; a question about the old file is then moot. */
    if (strcmp(filename_to_str(conf_get_filename(oldconf, CONF_logfilename)),
               filename_to_str(conf_get_filename(newconf, CONF_logfilename))) ||
        conf_get_int(oldconf, CONF_logtype) != conf_get_int(newconf, CONF_logtype))
        spb_seat_cancel_log_prompt(s);

    s->conf = newconf;
    log_reconfig(s->logctx, s->conf);
    if (s->ldisc) {
        ldisc_configure(s->ldisc, s->conf);
        ldisc_echoedit_update(s->ldisc);
    }
    if (s->term)
        term_reconfig(s->term, s->conf);
    if (s->backend && !s->exited)
        backend_reconfig(s->backend, s->conf);
    if (s->term)
        spb_terminal_reconfigure(s, oldconf);
    conf_free(oldconf);

    if (callbacks_enabled(s) && s->cb.reconfigured)
        s->cb.reconfigured(s->cb_ctx, cmd->request, NULL);
    spb_settings_free(cmd->settings);
    sfree(cmd);
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
    sfree(s->specials);
    conf_free(s->conf);
    spb_settings_free(s->created_settings);
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
    atomic_init(&s->transport_id, 0);
    s->state = SPB_SESSION_CREATED;
    spb_seat_init(s);

    /*
     * Building the Conf touches only the Conf and the settings map, so it
     * is done here on the caller's thread. log_init only allocates.
     */
    s->conf = conf_new();
    spb_settings_load_into_conf(settings, s->conf);
    prepare_session(s->conf);          /* as GTK new_session_window */
    s->created_settings = spb_settings_new_empty();
    spb_settings_save_from_conf(s->created_settings, s->conf);
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

void spb_session_restart(spb_session *s)
{
    post(s, cmd_restart, s);
}

void spb_session_special(spb_session *s, int32_t code, int32_t arg)
{
    input_special *cmd = snew(input_special);
    cmd->s = s;
    cmd->code = code;
    cmd->arg = arg;
    post(s, cmd_special, cmd);
}

void spb_session_query_close_warning(spb_session *s, uint64_t request)
{
    close_warning_cmd *cmd = snew(close_warning_cmd);
    cmd->s = s;
    cmd->request = request;
    post(s, cmd_close_warning, cmd);
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

uint64_t spb_session_transport_id(const spb_session *s)
{
    return atomic_load(&((spb_session *)s)->transport_id);
}

void spb_session_export_settings(spb_session *s, uint64_t request)
{
    reconfig_cmd *cmd = snew(reconfig_cmd);
    cmd->s = s;
    cmd->request = request;
    cmd->settings = NULL;
    post(s, cmd_export_settings, cmd);
}

void spb_session_reconfigure(spb_session *s, const spb_settings *settings,
                             uint64_t request)
{
    reconfig_cmd *cmd = snew(reconfig_cmd);
    cmd->s = s;
    cmd->request = request;
    cmd->settings = spb_settings_copy(settings);
    post(s, cmd_reconfigure, cmd);
}

spb_settings *spb_session_copy_settings(const spb_session *s)
{
    /* The settings the session was created with, never changed by
     * reconfiguration; spb_session_export_settings gives the running
     * ones. */
    return spb_settings_copy(s->created_settings);
}

/* ---------- R-3 self-check ---------- */

/* A different, still meaningful, value for key in conf. Keys loaded or
 * saved by custom code, and mappings, keep their defaults (their saved
 * form is still compared). Returns whether the key was changed. */
static bool set_other_value(Conf *conf, int key)
{
    const ConfKeyInfo *info = &conf_key_info[key];
    if (info->subkey_type != CONF_TYPE_NONE ||
        (!info->not_saved && (info->load_custom || info->save_custom)))
        return false;
    switch (info->value_type) {
      case CONF_TYPE_BOOL:
        conf_set_bool(conf, key, !conf_get_bool(conf, key));
        return true;
      case CONF_TYPE_INT: {
        int old = conf_get_int(conf, key);
        if (info->storage_enum) {
            const ConfSaveEnumType *e = info->storage_enum;
            for (size_t i = 0; i < e->nvalues; i++)
                if (!e->values[i].obsolete && e->values[i].confval != old) {
                    conf_set_int(conf, key, e->values[i].confval);
                    return true;
                }
            return false;
        }
        conf_set_int(conf, key, old + 3);
        return true;
      }
      case CONF_TYPE_STR:
      case CONF_TYPE_STR_AMBI: {
        char *value = dupprintf("v%d", key);
        conf_set_str(conf, key, value);
        sfree(value);
        return true;
      }
      case CONF_TYPE_UTF8: {
        char *value = dupprintf("v%d \xc3\xa9", key);
        conf_set_utf8(conf, key, value);
        sfree(value);
        return true;
      }
      case CONF_TYPE_FILENAME: {
        char *path = dupprintf("/tmp/v%d", key);
        Filename *fn = filename_from_str(path);
        conf_set_filename(conf, key, fn);
        filename_free(fn);
        sfree(path);
        return true;
      }
      case CONF_TYPE_FONT: {
        FontSpec *fs = fontspec_new("Menlo-Regular 13");
        conf_set_fontspec(conf, key, fs);
        fontspec_free(fs);
        return true;
      }
    }
    return false;
}

static bool same_unsaved_value(Conf *a, Conf *b, int key)
{
    switch (conf_key_info[key].value_type) {
      case CONF_TYPE_BOOL: return conf_get_bool(a, key) == conf_get_bool(b, key);
      case CONF_TYPE_INT: return conf_get_int(a, key) == conf_get_int(b, key);
      case CONF_TYPE_STR: return !strcmp(conf_get_str(a, key), conf_get_str(b, key));
      case CONF_TYPE_UTF8: return !strcmp(conf_get_utf8(a, key), conf_get_utf8(b, key));
      case CONF_TYPE_STR_AMBI: {
        bool ua, ub;
        const char *va = conf_get_str_ambi(a, key, &ua);
        const char *vb = conf_get_str_ambi(b, key, &ub);
        return ua == ub && !strcmp(va, vb);
      }
      default: return true;
    }
}

bool spb_debug_check_reconfigure_roundtrip(size_t *keys_checked,
                                           char **err_out)
{
    if (err_out)
        *err_out = NULL;
    spb_settings *defaults = spb_settings_new_defaults();
    Conf *running = conf_new();
    spb_settings_load_into_conf(defaults, running);
    spb_settings_free(defaults);

    size_t changed = 0;
    for (int key = 0; key < N_CONFIG_OPTIONS; key++)
        changed += set_other_value(running, key);
    /* Some mappings, and keys with custom storage, by hand. */
    conf_set_str_str(running, CONF_portfwd, "L8080", "localhost:80");
    conf_set_str_str(running, CONF_portfwd, "R2222", "host:22");
    conf_set_str_str(running, CONF_environmt, "SPB_VAR", "value");
    conf_set_int_int(running, CONF_colours, 0, 17);
    conf_set_int_int(running, CONF_wordness, 46, 2);
    conf_set_int(running, CONF_ping_interval, 150);
    conf_set_int(running, CONF_protocol, PROT_RAW);

    /* Export (as cmd_export_settings, minus the window title), then
     * reconfigure with the result. */
    spb_settings *exported = spb_settings_new_empty();
    spb_settings_save_from_conf(exported, running);
    Conf *after = spb_conf_for_reconfigure(exported, running);
    spb_settings *again = spb_settings_new_empty();
    spb_settings_save_from_conf(again, after);

    bool ok = true;
    size_t n = spb_settings_count(exported);
    if (n != spb_settings_count(again)) {
        spb_set_error(err_out, "saved keyword count changed: %zu -> %zu", n,
                      spb_settings_count(again));
        ok = false;
    }
    for (size_t i = 0; ok && i < n; i++) {
        const char *k = spb_settings_key_at(exported, i);
        const char *v1 = spb_settings_value_at(exported, i);
        const char *v2 = spb_settings_get(again, k);
        if (!v2 || strcmp(v1, v2)) {
            spb_set_error(err_out, "saved keyword %s: \"%s\" -> \"%s\"", k, v1,
                          v2 ? v2 : "(missing)");
            ok = false;
        }
    }
    for (int key = 0; ok && key < N_CONFIG_OPTIONS; key++) {
        if (conf_key_info[key].not_saved &&
            !same_unsaved_value(running, after, key)) {
            spb_set_error(err_out, "unsaved key %d lost its value", key);
            ok = false;
        }
    }
    /* The changes must have been made, or the check proves nothing. */
    if (ok && changed < N_CONFIG_OPTIONS / 2) {
        spb_set_error(err_out, "only %zu of %d keys could be changed",
                      changed, (int)N_CONFIG_OPTIONS);
        ok = false;
    }
    if (keys_checked)
        *keys_checked = N_CONFIG_OPTIONS;

    spb_settings_free(exported);
    spb_settings_free(again);
    conf_free(running);
    conf_free(after);
    return ok;
}
