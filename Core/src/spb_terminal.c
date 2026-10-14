/*
 * spb_terminal.c - a session's PuTTY Terminal and its TermWin.
 *
 * PuTTY's terminal (terminal/terminal.c) runs on the core thread and
 * draws through the TermWin vtable, exactly as it draws into a GTK or
 * Windows window. Here those calls are recorded into a grid of cells
 * whose colours are resolved the way GTK PuTTY resolves them
 * (unix/window.c do_text_internal, draw_cursor). The grid is the
 * published frame: the frontend copies changed rows out of it under the
 * screen lock (docs/ARCHITECTURE.md section 8, D-007, D-021).
 *
 * Frames are coalesced twice over: PuTTY's terminal already batches
 * output into timed updates (term_schedule_update), and the frontend is
 * notified only once until it reads the frame.
 */

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "spb_internal.h"
#include "terminal/terminal.h"

struct spb_screen {
    pthread_mutex_t lock;

    /* Protected by lock: the frame the frontend reads. */
    int cols, rows;
    spb_cell *cells;                   /* rows * cols */
    uint8_t *lattr;                    /* spb_line_attr per row */
    uint8_t *dirty;                    /* per row */
    bool full;                         /* reader must take every row */
    bool changed;                      /* anything since the last read */
    bool notify_armed;                 /* reader wants a notification */
    spb_frame_info info;               /* everything except size/full */

    /* Core thread only. */
    bool painting;                     /* between setup/free_draw_ctx */
    bool info_changed_in_paint;
    rgb palette[OSC4_NCOLOURS];
    int bold_style;                    /* BOLD_STYLE_* bits */
    spb_cursor_style cursor_style;
    int pixel_width, pixel_height;
};

static spb_session *termwin_session(TermWin *tw)
{
    return container_of(tw, spb_session, termwin);
}

static uint32_t rgb_value(rgb c)
{
    return ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | c.b;
}

static uint32_t dimmed(uint32_t c)
{
    /* GTK PuTTY: each component * 2/3 */
    uint32_t r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    return ((r * 2 / 3) << 16) | ((g * 2 / 3) << 8) | (b * 2 / 3);
}

static void blank_cell(struct spb_screen *sc, spb_cell *cell)
{
    memset(cell, 0, sizeof(*cell));
    cell->fg = sc->info.default_fg;
    cell->bg = sc->info.default_bg;
}

/* Called with the lock held. */
static void reallocate(struct spb_screen *sc, int cols, int rows)
{
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    sfree(sc->cells);
    sfree(sc->lattr);
    sfree(sc->dirty);
    sc->cols = cols;
    sc->rows = rows;
    sc->cells = snewn((size_t)cols * rows, spb_cell);
    sc->lattr = snewn(rows, uint8_t);
    sc->dirty = snewn(rows, uint8_t);
    for (size_t i = 0; i < (size_t)cols * rows; i++)
        blank_cell(sc, &sc->cells[i]);
    memset(sc->lattr, SPB_LINE_NORMAL, rows);
    memset(sc->dirty, 1, rows);
    sc->full = true;
    sc->changed = true;
}

/*
 * Mark the frame changed and decide, under the lock, whether to notify;
 * the caller notifies after unlocking (callbacks never run under it).
 */
static bool mark_changed_locked(struct spb_screen *sc)
{
    sc->changed = true;
    if (!sc->notify_armed)
        return false;
    sc->notify_armed = false;
    return true;
}

static void notify_frame(spb_session *s)
{
    if (!atomic_load(&s->released) && s->cb.terminal_updated)
        s->cb.terminal_updated(s->cb_ctx);
}

/*
 * Update published info fields (core thread). PuTTY calls some TermWin
 * methods (set_scrollbar, palette_set, ...) in the middle of a paint,
 * when the lock is already held, so those only record the change, and
 * free_draw_ctx notifies.
 */
static void info_begin(struct spb_screen *sc)
{
    if (!sc->painting)
        pthread_mutex_lock(&sc->lock);
}

static void info_end(spb_session *s)
{
    struct spb_screen *sc = s->screen;
    if (sc->painting) {
        sc->info_changed_in_paint = true;
        return;
    }
    bool notify = mark_changed_locked(sc);
    pthread_mutex_unlock(&sc->lock);
    if (notify)
        notify_frame(s);
}

#define UPDATE_INFO(s, assignments) do {                        \
        struct spb_screen *sc_ = (s)->screen;                   \
        info_begin(sc_);                                        \
        assignments;                                            \
        info_end(s);                                            \
    } while (0)

/* ---------- Colour resolution: unix/window.c do_text_internal ---------- */

static void resolve_colours(struct spb_screen *sc, unsigned long attr,
                            truecolour tc, uint32_t *fg_out,
                            uint32_t *bg_out)
{
    int nfg = (attr & ATTR_FGMASK) >> ATTR_FGSHIFT;
    int nbg = (attr & ATTR_BGMASK) >> ATTR_BGSHIFT;

    if (attr & ATTR_REVERSE) {
        int t = nfg; nfg = nbg; nbg = t;
        optionalrgb trgb = tc.fg; tc.fg = tc.bg; tc.bg = trgb;
    }
    if ((sc->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BOLD)) {
        if (nfg < 16) nfg |= 8;
        else if (nfg >= 256) nfg |= 1;
    }
    if ((sc->bold_style & BOLD_STYLE_COLOUR) && (attr & ATTR_BLINK)) {
        if (nbg < 16) nbg |= 8;
        else if (nbg >= 256) nbg |= 1;
    }
    if (attr & ATTR_ACTCURS) {
        tc.fg = tc.bg = optionalrgb_none;
        nfg = OSC4_COLOUR_cursor_fg;
        nbg = OSC4_COLOUR_cursor_bg;
        attr &= ~ATTR_DIM;             /* don't dim the cursor */
    }

    uint32_t fg = tc.fg.enabled ?
        ((uint32_t)tc.fg.r << 16 | (uint32_t)tc.fg.g << 8 | tc.fg.b) :
        rgb_value(sc->palette[nfg % OSC4_NCOLOURS]);
    uint32_t bg = tc.bg.enabled ?
        ((uint32_t)tc.bg.r << 16 | (uint32_t)tc.bg.g << 8 | tc.bg.b) :
        rgb_value(sc->palette[nbg % OSC4_NCOLOURS]);
    if (attr & ATTR_DIM) {
        fg = dimmed(fg);
        bg = dimmed(bg);
    }
    *fg_out = fg;
    *bg_out = bg;
}

/* Number of addressable cells in a row with these line attributes. */
static int row_width(struct spb_screen *sc, int lattr_mode)
{
    return lattr_mode == LATTR_NORM ? sc->cols : sc->cols / 2;
}

static spb_line_attr line_attr_of(int lattr)
{
    switch (lattr & LATTR_MODE) {
      case LATTR_WIDE: return SPB_LINE_DOUBLE_WIDTH;
      case LATTR_TOP:  return SPB_LINE_DOUBLE_TOP;
      case LATTR_BOT:  return SPB_LINE_DOUBLE_BOTTOM;
      default:         return SPB_LINE_NORMAL;
    }
}

/*
 * Record text drawn at (x, y). For double-width lines x counts logical
 * (double) columns, as in PuTTY; the grid stores them at their logical
 * index and the renderer doubles them. Returns the number of cells
 * written, starting at x. Lock held.
 */
static int put_text(struct spb_screen *sc, int x, int y, const wchar_t *text,
                    int len, unsigned long attr, int lattr, truecolour tc)
{
    if (y < 0 || y >= sc->rows || x < 0)
        return 0;
    int mode = lattr & LATTR_MODE;
    int width = row_width(sc, mode);
    sc->lattr[y] = line_attr_of(lattr);
    sc->dirty[y] = 1;

    uint32_t fg, bg;
    resolve_colours(sc, attr, tc, &fg, &bg);

    uint32_t flags = 0;
    if ((attr & ATTR_BOLD) && (sc->bold_style & BOLD_STYLE_FONT))
        flags |= SPB_CELL_BOLD;
    if (attr & ATTR_UNDER)
        flags |= SPB_CELL_UNDERLINE;
    if (attr & ATTR_STRIKE)
        flags |= SPB_CELL_STRIKE;

    spb_cell *row = sc->cells + (size_t)y * sc->cols;

    if (attr & TATTR_COMBINING) {
        /* One character cell: base plus combining characters. */
        if (x >= width)
            return 0;
        spb_cell *cell = &row[x];
        memset(cell->chars, 0, sizeof(cell->chars));
        for (int i = 0; i < len && i < SPB_CELL_MAX_CHARS; i++)
            cell->chars[i] = (uint32_t)text[i];
        cell->fg = fg;
        cell->bg = bg;
        cell->flags = flags;
        if (attr & ATTR_WIDE) {
            cell->flags |= SPB_CELL_WIDE;
            if (x + 1 < width) {
                row[x + 1] = *cell;
                memset(row[x + 1].chars, 0, sizeof(row[x + 1].chars));
                row[x + 1].flags = SPB_CELL_WIDE_CONT;
            }
            return 2;
        }
        return 1;
    }

    int step = (attr & ATTR_WIDE) ? 2 : 1;
    int written = 0;
    for (int i = 0; i < len; i++) {
        int cx = x + i * step;
        if (cx >= width)
            break;
        spb_cell *cell = &row[cx];
        memset(cell->chars, 0, sizeof(cell->chars));
        wchar_t c = text[i];
        cell->chars[0] = (c == UCSWIDE || c == ' ') ? 0 : (uint32_t)c;
        cell->fg = fg;
        cell->bg = bg;
        cell->flags = flags;
        written = cx - x + 1;
        if (step == 2) {
            cell->flags |= SPB_CELL_WIDE;
            if (cx + 1 < width) {
                spb_cell *cont = &row[cx + 1];
                memset(cont, 0, sizeof(*cont));
                cont->fg = fg;
                cont->bg = bg;
                cont->flags = SPB_CELL_WIDE_CONT;
                written = cx - x + 2;
            }
        }
    }
    return written;
}

/* ---------- TermWin ---------- */

static bool spb_tw_setup_draw_ctx(TermWin *tw)
{
    spb_session *s = termwin_session(tw);
    pthread_mutex_lock(&s->screen->lock);
    s->screen->painting = true;
    s->screen->info_changed_in_paint = false;
    return true;
}

static void spb_tw_draw_text(TermWin *tw, int x, int y, wchar_t *text,
                             int len, unsigned long attrs, int line_attrs,
                             truecolour tc)
{
    spb_session *s = termwin_session(tw);
    put_text(s->screen, x, y, text, len, attrs, line_attrs, tc);
}

/* unix/window.c gtkwin_draw_cursor */
static void spb_tw_draw_cursor(TermWin *tw, int x, int y, wchar_t *text,
                               int len, unsigned long attrs, int line_attrs,
                               truecolour tc)
{
    spb_session *s = termwin_session(tw);
    struct spb_screen *sc = s->screen;
    bool passive = false, active = false;

    if (attrs & ATTR_PASCURS) {
        attrs &= ~ATTR_PASCURS;
        passive = true;
    }
    if ((attrs & ATTR_ACTCURS) && sc->cursor_style != SPB_CURSOR_BLOCK) {
        attrs &= ~ATTR_ACTCURS;
        active = true;
    }
    int n = put_text(sc, x, y, text, len, attrs, line_attrs, tc);
    if (n <= 0)
        return;

    /* An active block cursor is already in the cell colours. */
    if (passive || active) {
        spb_cell *cell = &sc->cells[(size_t)y * sc->cols + x];
        cell->flags |= SPB_CELL_CURSOR;
        if (passive)
            cell->flags |= SPB_CELL_CURSOR_PASSIVE;
        if (attrs & ATTR_RIGHTCURS)
            cell->flags |= SPB_CELL_CURSOR_RIGHT;
    }
}

static void spb_tw_draw_trust_sigil(TermWin *tw, int x, int y)
{
    spb_session *s = termwin_session(tw);
    struct spb_screen *sc = s->screen;
    if (y < 0 || y >= sc->rows || x < 0 || x + 1 >= sc->cols)
        return;
    spb_cell *cell = &sc->cells[(size_t)y * sc->cols + x];
    blank_cell(sc, &cell[0]);
    blank_cell(sc, &cell[1]);
    cell[0].flags = SPB_CELL_TRUST_SIGIL | SPB_CELL_WIDE;
    cell[1].flags = SPB_CELL_WIDE_CONT;
    sc->dirty[y] = 1;
}

/* Double-width characters are drawn as two cells, so (as in GTK PuTTY)
 * every character is one unit wide here. */
static int spb_tw_char_width(TermWin *tw, int uc)
{
    return 1;
}

static void spb_tw_free_draw_ctx(TermWin *tw)
{
    spb_session *s = termwin_session(tw);
    struct spb_screen *sc = s->screen;
    bool changed = sc->info_changed_in_paint;
    for (int y = 0; y < sc->rows && !changed; y++)
        changed = sc->dirty[y];
    bool notify = changed && mark_changed_locked(sc);
    sc->painting = false;
    pthread_mutex_unlock(&sc->lock);
    if (notify)
        notify_frame(s);
}

static void spb_tw_set_cursor_pos(TermWin *tw, int x, int y)
{
    spb_session *s = termwin_session(tw);
    UPDATE_INFO(s, (sc_->info.cursor_x = x, sc_->info.cursor_y = y));
}

static void spb_tw_set_raw_mouse_mode(TermWin *tw, bool enable)
{
    spb_session *s = termwin_session(tw);
    UPDATE_INFO(s, sc_->info.raw_mouse = enable);
}

static void spb_tw_set_raw_mouse_mode_pointer(TermWin *tw, bool enable)
{
    spb_session *s = termwin_session(tw);
    UPDATE_INFO(s, sc_->info.raw_mouse_pointer = enable);
}

static void spb_tw_set_scrollbar(TermWin *tw, int total, int start, int page)
{
    spb_session *s = termwin_session(tw);
    UPDATE_INFO(s, (sc_->info.scroll_total = total,
                    sc_->info.scroll_start = start,
                    sc_->info.scroll_page = page));
}

static void spb_tw_bell(TermWin *tw, int mode)
{
    spb_session *s = termwin_session(tw);
    if (!atomic_load(&s->released) && s->cb.bell)
        s->cb.bell(s->cb_ctx, mode);
}

static spb_clipboard clipboard_of(int clipboard, bool *ok)
{
    *ok = true;
    switch (clipboard) {
      case CLIP_PRIMARY:   return SPB_CLIPBOARD_SELECTION;
      case CLIP_CLIPBOARD: return SPB_CLIPBOARD_SYSTEM;
      default:
        *ok = false;     /* CLIP_LOCAL is the terminal's own; customs unused */
        return SPB_CLIPBOARD_SELECTION;
    }
}

static void spb_tw_clip_write(TermWin *tw, int clipboard, wchar_t *text,
                              int *attrs, truecolour *colours, int len,
                              bool must_deselect)
{
    spb_session *s = termwin_session(tw);
    bool ok;
    spb_clipboard which = clipboard_of(clipboard, &ok);
    if (!ok || atomic_load(&s->released) || !s->cb.clipboard_write)
        return;
    size_t outlen;
    char *utf8 = dup_wc_to_mb_c(CP_UTF8, text, len, "", &outlen);
    s->cb.clipboard_write(s->cb_ctx, which, utf8, outlen);
    burnstr(utf8);
}

static void spb_tw_clip_request_paste(TermWin *tw, int clipboard)
{
    spb_session *s = termwin_session(tw);
    bool ok;
    spb_clipboard which = clipboard_of(clipboard, &ok);
    if (ok && !atomic_load(&s->released) && s->cb.paste_requested)
        s->cb.paste_requested(s->cb_ctx, which);
}

static void spb_tw_refresh(TermWin *tw)
{
    spb_session *s = termwin_session(tw);
    if (s->term)
        term_invalidate(s->term);
}

static void spb_tw_request_resize(TermWin *tw, int w, int h)
{
    spb_session *s = termwin_session(tw);
    if (!atomic_load(&s->released) && s->cb.resize_requested)
        s->cb.resize_requested(s->cb_ctx, w, h);
    /* Acknowledged at once: any resize arrives later through
     * spb_session_resize, which upstream permits (putty.h). */
    term_resize_request_completed(s->term);
}

static void emit_title(spb_session *s, const char *title, int codepage,
                       bool icon)
{
    if (atomic_load(&s->released) || !s->cb.title_changed)
        return;
    /* unix/window.c gtkwin_set_title */
    if (codepage != CP_UTF8) {
        wchar_t *title_w = dup_mb_to_wc(codepage, title);
        char *utf8 = encode_wide_string_as_utf8(title_w);
        s->cb.title_changed(s->cb_ctx, utf8, icon);
        sfree(utf8);
        sfree(title_w);
    } else {
        s->cb.title_changed(s->cb_ctx, title, icon);
    }
}

static void spb_tw_set_title(TermWin *tw, const char *title, int codepage)
{
    emit_title(termwin_session(tw), title, codepage, false);
}

static void spb_tw_set_icon_title(TermWin *tw, const char *title,
                                  int codepage)
{
    emit_title(termwin_session(tw), title, codepage, true);
}

/* Window manipulation by the remote end arrives with window management
 * (M06). */
static void spb_tw_set_minimised(TermWin *tw, bool minimised) {}
static void spb_tw_set_maximised(TermWin *tw, bool maximised) {}
static void spb_tw_move(TermWin *tw, int x, int y) {}
static void spb_tw_set_zorder(TermWin *tw, bool top) {}

static void spb_tw_palette_set(TermWin *tw, unsigned start, unsigned ncolours,
                               const rgb *colours)
{
    spb_session *s = termwin_session(tw);
    struct spb_screen *sc = s->screen;
    assert(start <= OSC4_NCOLOURS);
    assert(ncolours <= OSC4_NCOLOURS - start);
    memcpy(sc->palette + start, colours, ncolours * sizeof(rgb));
    UPDATE_INFO(s, (
        sc_->info.default_fg = rgb_value(sc_->palette[OSC4_COLOUR_fg]),
        sc_->info.default_bg = rgb_value(sc_->palette[OSC4_COLOUR_bg]),
        sc_->info.cursor_colour =
            rgb_value(sc_->palette[OSC4_COLOUR_cursor_bg])));
}

/* As GTK PuTTY: no OS-level colour overrides. */
static void spb_tw_palette_get_overrides(TermWin *tw, Terminal *term) {}

static void spb_tw_unthrottle(TermWin *tw, size_t bufsize)
{
    spb_session *s = termwin_session(tw);
    if (s->backend)
        backend_unthrottle(s->backend, bufsize);
}

static const TermWinVtable spb_termwin_vt = {
    .setup_draw_ctx = spb_tw_setup_draw_ctx,
    .draw_text = spb_tw_draw_text,
    .draw_cursor = spb_tw_draw_cursor,
    .draw_trust_sigil = spb_tw_draw_trust_sigil,
    .char_width = spb_tw_char_width,
    .free_draw_ctx = spb_tw_free_draw_ctx,
    .set_cursor_pos = spb_tw_set_cursor_pos,
    .set_raw_mouse_mode = spb_tw_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = spb_tw_set_raw_mouse_mode_pointer,
    .set_scrollbar = spb_tw_set_scrollbar,
    .bell = spb_tw_bell,
    .clip_write = spb_tw_clip_write,
    .clip_request_paste = spb_tw_clip_request_paste,
    .refresh = spb_tw_refresh,
    .request_resize = spb_tw_request_resize,
    .set_title = spb_tw_set_title,
    .set_icon_title = spb_tw_set_icon_title,
    .set_minimised = spb_tw_set_minimised,
    .set_maximised = spb_tw_set_maximised,
    .move = spb_tw_move,
    .set_zorder = spb_tw_set_zorder,
    .palette_set = spb_tw_palette_set,
    .palette_get_overrides = spb_tw_palette_get_overrides,
    .unthrottle = spb_tw_unthrottle,
};

/* ---------- Lifecycle ---------- */

/*
 * unix/window.c setup_clipboards: which clipboards mouse selection writes
 * and mouse paste reads. Named X11 clipboards (CLIPUI_CUSTOM) have no
 * macOS equivalent and act as "none".
 */
static void setup_clipboards(Terminal *term, Conf *conf)
{
    assert(term->mouse_select_clipboards[0] == CLIP_LOCAL);
    term->n_mouse_select_clipboards = 1;
    term->mouse_select_clipboards[
        term->n_mouse_select_clipboards++] = MOUSE_SELECT_CLIPBOARD;
    if (conf_get_bool(conf, CONF_mouseautocopy))
        term->mouse_select_clipboards[
            term->n_mouse_select_clipboards++] = CLIP_CLIPBOARD;

    switch (conf_get_int(conf, CONF_mousepaste)) {
      case CLIPUI_IMPLICIT:
        term->mouse_paste_clipboard = MOUSE_PASTE_CLIPBOARD;
        break;
      case CLIPUI_EXPLICIT:
        term->mouse_paste_clipboard = CLIP_CLIPBOARD;
        break;
      default:
        term->mouse_paste_clipboard = CLIP_NULL;
        break;
    }
}

static void apply_conf(spb_session *s)
{
    struct spb_screen *sc = s->screen;
    sc->bold_style = conf_get_int(s->conf, CONF_bold_style);
    switch (conf_get_int(s->conf, CONF_cursor_type)) {
      case CURSOR_UNDERLINE:     sc->cursor_style = SPB_CURSOR_UNDERLINE; break;
      case CURSOR_VERTICAL_LINE: sc->cursor_style = SPB_CURSOR_VERTICAL_LINE; break;
      default:                   sc->cursor_style = SPB_CURSOR_BLOCK; break;
    }
    spb_cursor_style style = sc->cursor_style;
    UPDATE_INFO(s, sc_->info.cursor_style = style);
}

struct spb_screen *spb_screen_new(void)
{
    struct spb_screen *sc = snew(struct spb_screen);
    memset(sc, 0, sizeof(*sc));
    pthread_mutex_init(&sc->lock, NULL);
    sc->notify_armed = true;
    return sc;
}

void spb_terminal_create(spb_session *s)
{
    struct spb_screen *sc = s->screen;
    s->termwin.vt = &spb_termwin_vt;

    /* As GTK PuTTY with a Unicode (Pango) font: unix/window.c
     * setup_fonts_ucs. */
    init_ucs(&s->ucsdata, conf_get_str(s->conf, CONF_line_codepage),
             conf_get_bool(s->conf, CONF_utf8_override), CS_UTF8,
             conf_get_int(s->conf, CONF_vtmode));

    int cols = conf_get_int(s->conf, CONF_width);
    int rows = conf_get_int(s->conf, CONF_height);
    pthread_mutex_lock(&sc->lock);
    reallocate(sc, cols, rows);
    pthread_mutex_unlock(&sc->lock);
    apply_conf(s);

    /* term_init sets the palette (palette_set) before returning. */
    s->term = term_init(s->conf, &s->ucsdata, &s->termwin);
    term_provide_logctx(s->term, s->logctx);
    setup_clipboards(s->term, s->conf);
    term_size(s->term, rows, cols, conf_get_int(s->conf, CONF_savelines));

    /* Cells allocated before the palette existed get its colours. */
    pthread_mutex_lock(&sc->lock);
    reallocate(sc, sc->cols, sc->rows);
    pthread_mutex_unlock(&sc->lock);
}

void spb_terminal_free(spb_session *s)
{
    if (s->term) {
        term_free(s->term);
        s->term = NULL;
    }
}

void spb_screen_free(struct spb_screen *sc)
{
    if (!sc)
        return;
    pthread_mutex_destroy(&sc->lock);
    sfree(sc->cells);
    sfree(sc->lattr);
    sfree(sc->dirty);
    sfree(sc);
}

void spb_terminal_resize(spb_session *s, int cols, int rows,
                         int pixel_width, int pixel_height)
{
    struct spb_screen *sc = s->screen;
    if (!s->term || cols < 1 || rows < 1)
        return;
    sc->pixel_width = pixel_width;
    sc->pixel_height = pixel_height;
    if (cols != sc->cols || rows != sc->rows) {
        pthread_mutex_lock(&sc->lock);
        reallocate(sc, cols, rows);
        bool notify = mark_changed_locked(sc);
        pthread_mutex_unlock(&sc->lock);
        term_size(s->term, rows, cols,
                  conf_get_int(s->conf, CONF_savelines));
        if (notify)
            notify_frame(s);
    }
    if (pixel_width > 0 && pixel_height > 0)
        term_notify_window_size_pixels(s->term, pixel_width, pixel_height);
}

bool spb_terminal_raw_mouse(spb_session *s)
{
    return s->screen->info.raw_mouse;  /* written on the core thread only */
}

bool spb_terminal_window_pixel_size(spb_session *s, int *w, int *h)
{
    struct spb_screen *sc = s->screen;
    if (!sc || sc->pixel_width <= 0)
        return false;
    *w = sc->pixel_width;
    *h = sc->pixel_height;
    return true;
}

/* ---------- Frame reading (any thread) ---------- */

bool spb_session_read_frame(spb_session *s, spb_frame_info *info,
                            spb_cell *cells, size_t cells_capacity,
                            uint8_t *line_attrs, uint8_t *dirty_rows,
                            size_t rows_capacity)
{
    struct spb_screen *sc = s->screen;
    pthread_mutex_lock(&sc->lock);
    *info = sc->info;
    info->cols = sc->cols;
    info->rows = sc->rows;
    info->full = sc->full;

    bool ok = sc->cells && cells &&
        cells_capacity >= (size_t)sc->cols * sc->rows &&
        rows_capacity >= (size_t)sc->rows && line_attrs && dirty_rows;
    if (ok) {
        for (int y = 0; y < sc->rows; y++) {
            bool take = sc->full || sc->dirty[y];
            dirty_rows[y] = take;
            if (take)
                memcpy(cells + (size_t)y * sc->cols,
                       sc->cells + (size_t)y * sc->cols,
                       sc->cols * sizeof(spb_cell));
            sc->dirty[y] = 0;
        }
        memcpy(line_attrs, sc->lattr, sc->rows);
        sc->full = false;
        sc->changed = false;
        sc->notify_armed = true;
    }
    pthread_mutex_unlock(&sc->lock);
    return ok;
}
