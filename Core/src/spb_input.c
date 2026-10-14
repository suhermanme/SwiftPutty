/*
 * spb_input.c - terminal input: keys, text, paste, mouse, scrolling.
 *
 * Every entry point posts a command; the translation runs on the core
 * thread, where the Terminal's modes (cursor/keypad application mode,
 * function key type, bracketed paste, mouse reporting) can be read.
 * Key translation follows GTK PuTTY's key_event (unix/window.c) and uses
 * PuTTY's portable formatters (terminal/terminal.c format_*_key), so the
 * byte sequences match upstream exactly.
 */

#include <string.h>

#include "spb_internal.h"
#include "terminal/terminal.h"

/* Command payload shared by the input entry points. */
typedef struct input_cmd {
    spb_session *s;
    int32_t a, b, c, d;
    uint32_t mods;
    size_t len;
    char data[];
} input_cmd;

static input_cmd *new_cmd(spb_session *s, const void *data, size_t len)
{
    input_cmd *cmd = smalloc(sizeof(input_cmd) + len + 1);
    memset(cmd, 0, sizeof(input_cmd));
    cmd->s = s;
    cmd->len = len;
    if (len)
        memcpy(cmd->data, data, len);
    cmd->data[len] = '\0';
    return cmd;
}

static void free_cmd(input_cmd *cmd)
{
    smemclr(cmd->data, cmd->len);      /* typed text may be a secret */
    sfree(cmd);
}

static void post_cmd(spb_command_fn fn, input_cmd *cmd)
{
    if (!spb_loop_post(fn, cmd))
        modalfatalbox("SwiftPutty internal error: session input after "
                      "core shutdown");
}

/* Keys go to the terminal only while a connection exists (as in GTK
 * PuTTY, where the Ldisc is gone after the session ends). */
static bool can_type(spb_session *s)
{
    return s->term && s->ldisc && !s->exited;
}

/* ---------- Keys: unix/window.c key_event ---------- */

/* unix/window.c return_key; with Meta the Escape is part of the same
 * input, as GTK PuTTY sends it. */
static void send_return(spb_session *s, bool meta)
{
    const char *seq = s->term->cr_lf_return ? "\033\r\n" : "\033\r";
    if (!meta)
        seq++;
    if (s->term->cr_lf_return)
        term_keyinput(s->term, -1, seq, (int)strlen(seq));
    else
        term_keyinput(s->term, -1, seq, -2);    /* special: Ldisc sees CR */
}

static void send_keypad(spb_session *s, char key, uint32_t mods)
{
    Terminal *term = s->term;
    bool shift = mods & SPB_MOD_SHIFT, ctrl = mods & SPB_MOD_CTRL;
    bool numeric = (key >= '0' && key <= '9') || key == '.';
    bool app_keypad_mode = term->app_keypad_keys &&
        !conf_get_bool(s->conf, CONF_no_applic_k);
    bool nethack = conf_get_bool(s->conf, CONF_nethack_keypad);
    char buf[64];
    int n;

    /*
     * The Mac keypad has no Num Lock: its keys are always numeric. GTK
     * PuTTY lets the input method turn numeric keypad keys into digits
     * unless application keypad or NetHack mode claims them.
     */
    if ((app_keypad_mode && (numeric || term->funky_type != FUNKY_XTERM)) ||
        (nethack && key >= '1' && key <= '9')) {
        n = format_numeric_keypad_key(buf, term, key, shift, ctrl);
        if (n > 0)
            term_keyinput(term, -1, buf, n);
        return;
    }
    n = format_numeric_keypad_key(buf, term, key, shift, ctrl);
    if (n > 0) {
        term_keyinput(term, -1, buf, n);
    } else if (key == '\r') {
        send_return(s, false);         /* Keypad Enter = Return */
    } else if (key != 'G') {
        char c = key;
        term_keyinput(term, CS_UTF8, &c, 1);
    }
}

/* Named ("custom") clipboards are an X11 feature; macOS has none, so
 * such settings act as "No action". */
static bool request_shift_insert_paste(spb_session *s)
{
    switch (conf_get_int(s->conf, CONF_ctrlshiftins)) {
      case CLIPUI_IMPLICIT:
        term_request_paste(s->term, CLIP_PRIMARY);
        return true;
      case CLIPUI_EXPLICIT:
        term_request_paste(s->term, CLIP_CLIPBOARD);
        return true;
      default:
        return false;
    }
}

static bool request_ctrl_insert_copy(spb_session *s)
{
    static const int clips_clipboard[] = { CLIP_CLIPBOARD };
    switch (conf_get_int(s->conf, CONF_ctrlshiftins)) {
      case CLIPUI_IMPLICIT:
        return true;          /* re-copying to the selection is not needed */
      case CLIPUI_EXPLICIT:
        term_request_copy(s->term, clips_clipboard, lenof(clips_clipboard));
        return true;
      default:
        return false;
    }
}

/* Ctrl+Shift+C / Ctrl+Shift+V. Returns false for "No action": then
 * the keys type Ctrl-C / Ctrl-V. */
static bool ctrl_shift_cv(spb_session *s, bool paste)
{
    static const int clips_clipboard[] = { CLIP_CLIPBOARD };
    switch (conf_get_int(s->conf, CONF_ctrlshiftcv)) {
      case CLIPUI_IMPLICIT:
        if (paste)
            term_request_paste(s->term, CLIP_PRIMARY);
        return true;
      case CLIPUI_EXPLICIT:
        if (paste)
            term_request_paste(s->term, CLIP_CLIPBOARD);
        else
            term_request_copy(s->term, clips_clipboard,
                              lenof(clips_clipboard));
        return true;
      default:
        return false;
    }
}

void spb_input_key(spb_session *s, spb_key key, uint32_t mods)
{
    Terminal *term = s->term;
    bool shift = mods & SPB_MOD_SHIFT;
    bool ctrl = mods & SPB_MOD_CTRL;
    bool meta = mods & SPB_MOD_META;
    char buf[64];
    int n = 0;
    bool consumed_meta = false;

    if (!term)
        return;

    /* Scrollback keys work even with no connection (GTK key_event). */
    if (key == SPB_KEY_PAGE_UP || key == SPB_KEY_PAGE_DOWN) {
        int dir = key == SPB_KEY_PAGE_UP ? -1 : +1;
        if (shift && ctrl) {
            term_scroll(term, dir < 0 ? +1 : -1, 0);  /* top / bottom */
            return;
        }
        if (shift) {
            term_scroll(term, 0, dir * (term->rows / 2));
            return;
        }
        if (ctrl) {
            term_scroll(term, 0, dir);
            return;
        }
    }
    if (key == SPB_KEY_INSERT && shift && request_shift_insert_paste(s))
        return;
    if (key == SPB_KEY_INSERT && ctrl && request_ctrl_insert_copy(s))
        return;
    if ((key == SPB_KEY_C || key == SPB_KEY_V) && ctrl && shift &&
        ctrl_shift_cv(s, key == SPB_KEY_V))
        return;

    if (!can_type(s))
        return;

    /* Alt (Meta) prefixes Escape unless a formatter consumes it. */
    char *p = buf;
    *p++ = '\033';

    switch (key) {
      case SPB_KEY_UP: case SPB_KEY_DOWN: case SPB_KEY_RIGHT:
      case SPB_KEY_LEFT: case SPB_KEY_BEGIN: {
        static const char xkeys[] = "ABCDG";
        n = format_arrow_key(p, term, xkeys[key - SPB_KEY_UP], shift, ctrl,
                             meta, &consumed_meta);
        break;
      }
      case SPB_KEY_HOME: case SPB_KEY_END: case SPB_KEY_INSERT:
      case SPB_KEY_DELETE: case SPB_KEY_PAGE_UP: case SPB_KEY_PAGE_DOWN: {
        /* These keys don't generate terminal input with Ctrl. */
        if (ctrl)
            return;
        SmallKeypadKey sk =
            key == SPB_KEY_HOME ? SKK_HOME :
            key == SPB_KEY_END ? SKK_END :
            key == SPB_KEY_INSERT ? SKK_INSERT :
            key == SPB_KEY_DELETE ? SKK_DELETE :
            key == SPB_KEY_PAGE_UP ? SKK_PGUP : SKK_PGDN;
        n = format_small_keypad_key(p, term, sk, shift, ctrl, meta,
                                    &consumed_meta);
        break;
      }
      case SPB_KEY_RETURN:
        send_return(s, meta);
        return;
      case SPB_KEY_BACKSPACE: {
        /* Shift inverts the configured Backspace. */
        bool del = conf_get_bool(s->conf, CONF_bksp_is_delete) != shift;
        *p = del ? '\x7F' : '\x08';
        p[1] = '\0';
        term_keyinput(term, -1, meta ? buf : p, -2);   /* special */
        return;
      }
      case SPB_KEY_TAB:
        if (shift) {
            memcpy(p, "\033[Z", 3);
            n = 3;
        } else {
            *p = '\t';
            n = 1;
        }
        break;
      case SPB_KEY_ESCAPE:
        *p = '\033';
        n = 1;
        break;
      case SPB_KEY_C:
      case SPB_KEY_V:
        /* Not claimed for the clipboard: an ordinary Ctrl-C / Ctrl-V. */
        *p = key == SPB_KEY_C ? '\x03' : '\x16';
        n = 1;
        break;
      case SPB_KEY_KP_NUM_LOCK: send_keypad(s, 'G', mods); return;
      case SPB_KEY_KP_DECIMAL:  send_keypad(s, '.', mods); return;
      case SPB_KEY_KP_ENTER:    send_keypad(s, '\r', mods); return;
      case SPB_KEY_KP_PLUS:     send_keypad(s, '+', mods); return;
      case SPB_KEY_KP_MINUS:    send_keypad(s, '-', mods); return;
      case SPB_KEY_KP_MULTIPLY: send_keypad(s, '*', mods); return;
      case SPB_KEY_KP_DIVIDE:   send_keypad(s, '/', mods); return;
      default:
        if (key >= SPB_KEY_F1 && key <= SPB_KEY_F20) {
            n = format_function_key(p, term, key - SPB_KEY_F1 + 1, shift,
                                    ctrl, meta, &consumed_meta);
        } else if (key >= SPB_KEY_KP_0 && key <= SPB_KEY_KP_9) {
            send_keypad(s, (char)('0' + (key - SPB_KEY_KP_0)), mods);
            return;
        }
        break;
    }

    if (n <= 0)
        return;
    bool prefix = meta && !consumed_meta;
    term_keyinput(term, -1, prefix ? buf : p, prefix ? n + 1 : n);
}

static void cmd_key(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_input_key(cmd->s, (spb_key)cmd->a, cmd->mods);
    free_cmd(cmd);
}

void spb_session_key(spb_session *s, spb_key key, uint32_t mods)
{
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = key;
    cmd->mods = mods;
    post_cmd(cmd_key, cmd);
}

/* unix/window.c input_method_commit_event, plus Meta's Escape prefix. */
static void cmd_text(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    if (can_type(s) && cmd->len) {
        if (cmd->mods & SPB_MOD_META)
            term_keyinput(s->term, -1, "\033", 1);
        term_keyinput(s->term, CS_UTF8, cmd->data, (int)cmd->len);
    }
    free_cmd(cmd);
}

void spb_session_text(spb_session *s, const char *utf8, size_t len,
                      uint32_t mods)
{
    input_cmd *cmd = new_cmd(s, utf8, len);
    cmd->mods = mods;
    post_cmd(cmd_text, cmd);
}

static void cmd_paste(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    if (can_type(s) && cmd->len) {
        size_t wlen;
        wchar_t *wide = dup_mb_to_wc_c(CP_UTF8, cmd->data, cmd->len, &wlen);
        term_do_paste(s->term, wide, wlen);
        smemclr(wide, wlen * sizeof(wchar_t));
        sfree(wide);
    }
    free_cmd(cmd);
}

void spb_session_paste(spb_session *s, const char *utf8, size_t len)
{
    post_cmd(cmd_paste, new_cmd(s, utf8, len));
}

/* unix/window.c input_method_preedit_changed_event / _end_event */
static void cmd_preedit(void *vctx)
{
    input_cmd *cmd = vctx;
    if (cmd->s->term)
        term_set_preedit_text(cmd->s->term, cmd->len ? cmd->data : NULL);
    free_cmd(cmd);
}

void spb_session_set_preedit(spb_session *s, const char *utf8)
{
    post_cmd(cmd_preedit, new_cmd(s, utf8, utf8 ? strlen(utf8) : 0));
}

/* ---------- Mouse ---------- */

/* windows/window.c translate_button */
static Mouse_Button cooked_button(spb_session *s, Mouse_Button raw)
{
    bool xterm = conf_get_int(s->conf, CONF_mouse_is_xterm) == MOUSE_XTERM;
    switch (raw) {
      case MBT_LEFT:   return MBT_SELECT;
      case MBT_MIDDLE: return xterm ? MBT_PASTE : MBT_EXTEND;
      case MBT_RIGHT:  return xterm ? MBT_EXTEND : MBT_PASTE;
      default:         return MBT_NOTHING;
    }
}

static void cmd_mouse(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    if (s->term) {
        static const Mouse_Button raw_buttons[] = {
            MBT_LEFT, MBT_MIDDLE, MBT_RIGHT };
        static const Mouse_Action actions[] = {
            MA_CLICK, MA_2CLK, MA_3CLK, MA_DRAG, MA_RELEASE, MA_MOVE };
        Mouse_Button raw = raw_buttons[cmd->a];
        Mouse_Action action = actions[cmd->b];
        Mouse_Button cooked = action == MA_MOVE ? MBT_NOTHING :
            cooked_button(s, raw);
        term_mouse(s->term, action == MA_MOVE ? MBT_NOTHING : raw, cooked,
                   action, cmd->c, cmd->d, cmd->mods & SPB_MOD_SHIFT,
                   cmd->mods & SPB_MOD_CTRL, cmd->mods & SPB_MOD_META);
    }
    free_cmd(cmd);
}

void spb_session_mouse(spb_session *s, spb_mouse_button button,
                       spb_mouse_action action, int32_t x, int32_t y,
                       uint32_t mods)
{
    if ((unsigned)button > SPB_MOUSE_RIGHT ||
        (unsigned)action > SPB_MOUSE_MOVE)
        return;
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = button;
    cmd->b = action;
    cmd->c = x;
    cmd->d = y;
    cmd->mods = mods;
    post_cmd(cmd_mouse, cmd);
}

/* unix/window.c scroll_internal: wheel events go to the application in
 * raw mouse mode (unless Shift overrides it, per MouseOverride), and
 * otherwise scroll the scrollback. */
#define SCROLL_INCREMENT_LINES 5

static void cmd_wheel(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_session *s = cmd->s;
    Terminal *term = s->term;
    if (term && cmd->a) {
        bool shift = cmd->mods & SPB_MOD_SHIFT;
        bool raw_mouse = spb_terminal_raw_mouse(s) &&
            !(shift && conf_get_bool(s->conf, CONF_mouse_override));
        if (raw_mouse) {
            Mouse_Button b = cmd->a > 0 ? MBT_WHEEL_UP : MBT_WHEEL_DOWN;
            int count = cmd->a > 0 ? cmd->a : -cmd->a;
            for (int i = 0; i < count; i++)
                term_mouse(term, b, b, MA_CLICK, cmd->c, cmd->d, shift,
                           cmd->mods & SPB_MOD_CTRL,
                           cmd->mods & SPB_MOD_META);
        } else {
            term_scroll(term, 0, -cmd->a * SCROLL_INCREMENT_LINES);
        }
    }
    free_cmd(cmd);
}

void spb_session_wheel(spb_session *s, int32_t notches, int32_t x,
                       int32_t y, uint32_t mods)
{
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = notches;
    cmd->c = x;
    cmd->d = y;
    cmd->mods = mods;
    post_cmd(cmd_wheel, cmd);
}

/* ---------- Scrolling, size, focus, copy ---------- */

static void cmd_scroll(void *vctx)
{
    input_cmd *cmd = vctx;
    Terminal *term = cmd->s->term;
    if (term) {
        switch ((spb_scroll_mode)cmd->a) {
          case SPB_SCROLL_RELATIVE:  term_scroll(term, 0, cmd->b); break;
          case SPB_SCROLL_TO_LINE:   term_scroll(term, +1, cmd->b); break;
          case SPB_SCROLL_TO_BOTTOM: term_scroll(term, -1, 0); break;
        }
    }
    free_cmd(cmd);
}

void spb_session_scroll(spb_session *s, spb_scroll_mode mode, int32_t lines)
{
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = mode;
    cmd->b = lines;
    post_cmd(cmd_scroll, cmd);
}

static void cmd_resize(void *vctx)
{
    input_cmd *cmd = vctx;
    spb_terminal_resize(cmd->s, cmd->a, cmd->b, cmd->c, cmd->d);
    free_cmd(cmd);
}

void spb_session_resize(spb_session *s, int32_t cols, int32_t rows,
                        int32_t pixel_width, int32_t pixel_height)
{
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = cols;
    cmd->b = rows;
    cmd->c = pixel_width;
    cmd->d = pixel_height;
    post_cmd(cmd_resize, cmd);
}

static void cmd_focus(void *vctx)
{
    input_cmd *cmd = vctx;
    /* unix/window.c focus_event */
    if (cmd->s->term) {
        term_set_focus(cmd->s->term, cmd->a != 0);
        term_update(cmd->s->term);
    }
    free_cmd(cmd);
}

void spb_session_set_focus(spb_session *s, bool focused)
{
    input_cmd *cmd = new_cmd(s, NULL, 0);
    cmd->a = focused;
    post_cmd(cmd_focus, cmd);
}

static void cmd_copy_all(void *vctx)
{
    input_cmd *cmd = vctx;
    if (cmd->s->term) {
        static const int clips[] = { CLIP_CLIPBOARD };
        term_copyall(cmd->s->term, clips, lenof(clips));
    }
    free_cmd(cmd);
}

void spb_session_copy_all(spb_session *s)
{
    post_cmd(cmd_copy_all, new_cmd(s, NULL, 0));
}
