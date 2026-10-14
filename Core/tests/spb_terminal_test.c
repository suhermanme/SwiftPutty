/*
 * C-level tests for the terminal (M03): PuTTY's Terminal driven by a Raw
 * session whose server end the test holds directly, so it can write
 * escape sequences to the terminal and read back exactly what keys,
 * pastes and mouse actions send.
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "PuTTYBridge.h"

static int failures;

#define CHECK(cond) do {                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n",                \
                    __FILE__, __LINE__, #cond);                         \
            failures++;                                                 \
        }                                                               \
    } while (0)

#define CHECK_STR(actual, expected) do {                                \
        const char *a_ = (actual), *e_ = (expected);                    \
        if (strcmp(a_, e_)) {                                           \
            fprintf(stderr, "%s:%d: expected %s == \"%s\", got \"%s\"\n", \
                    __FILE__, __LINE__, #actual, e_, a_);               \
            failures++;                                                 \
        }                                                               \
    } while (0)

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------- Callbacks ---------- */

typedef struct events {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    int updates;
    bool connected, released;
    char title[256];
    int bells;
    char clip_text[256];
    bool clip_has_marker;              /* full text contains clip_marker */
    int clip_which;
    int clip_writes;
    int paste_requests;
    int paste_which;
    int resize_cols, resize_rows;
    spb_settings *exported;
    int reconfigured;
} events;

static events ev = {
    .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER,
};

#define WITH_EVENTS(code) do {                                          \
        pthread_mutex_lock(&ev.lock); code;                             \
        pthread_cond_broadcast(&ev.cond);                               \
        pthread_mutex_unlock(&ev.lock);                                 \
    } while (0)

static void cb_state(void *ctx, spb_session_state st, const char *detail)
{
    WITH_EVENTS(if (st == SPB_SESSION_CONNECTED) ev.connected = true);
}
static void cb_updated(void *ctx) { WITH_EVENTS(ev.updates++); }
static void cb_title(void *ctx, const char *title, bool icon)
{
    if (!icon)
        WITH_EVENTS(snprintf(ev.title, sizeof(ev.title), "%s", title));
}
static void cb_bell(void *ctx, int32_t mode) { WITH_EVENTS(ev.bells++); }
static const char *clip_marker = "select me please";

static void cb_clip(void *ctx, spb_clipboard which, const char *text,
                    size_t len)
{
    char *copy = strndup(text, len);
    WITH_EVENTS(
        snprintf(ev.clip_text, sizeof(ev.clip_text), "%s", copy);
        ev.clip_has_marker = strstr(copy, clip_marker) != NULL;
        ev.clip_which = which; ev.clip_writes++);
    free(copy);
}
static void cb_paste(void *ctx, spb_clipboard which)
{
    WITH_EVENTS(ev.paste_requests++; ev.paste_which = which);
}
static void cb_resize(void *ctx, int32_t cols, int32_t rows)
{
    WITH_EVENTS(ev.resize_cols = cols; ev.resize_rows = rows);
}
static void cb_released(void *ctx) { WITH_EVENTS(ev.released = true); }
static void cb_exported(void *ctx, uint64_t request, spb_settings *settings,
                        int32_t info)
{
    WITH_EVENTS(spb_settings_free(ev.exported); ev.exported = settings);
}
static void cb_reconfigured(void *ctx, uint64_t request, const char *error)
{
    WITH_EVENTS(if (!error) ev.reconfigured++);
}

static const spb_session_callbacks callbacks = {
    .state_changed = cb_state,
    .terminal_updated = cb_updated,
    .title_changed = cb_title,
    .bell = cb_bell,
    .clipboard_write = cb_clip,
    .paste_requested = cb_paste,
    .resize_requested = cb_resize,
    .released = cb_released,
    .settings_exported = cb_exported,
    .reconfigured = cb_reconfigured,
};

typedef bool (*ev_pred)(void);

static bool wait_events(ev_pred pred, double timeout)
{
    double deadline = now_seconds() + timeout;
    pthread_mutex_lock(&ev.lock);
    bool ok;
    while (!(ok = pred()) && now_seconds() < deadline) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 20 * 1000000;
        if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(&ev.cond, &ev.lock, &ts);
    }
    pthread_mutex_unlock(&ev.lock);
    return ok;
}

static bool is_connected(void) { return ev.connected; }
static bool is_released(void) { return ev.released; }

/* ---------- The frontend's copy of the screen ---------- */

static spb_session *session;
static int peer = -1;                  /* the server end of the connection */
static spb_frame_info info;
static spb_cell *cells;
static size_t cells_cap;
static uint8_t *lattrs, *dirty;
static size_t rows_cap;

/* Read the latest frame, growing the buffers as the bridge asks. */
static void read_frame(void)
{
    for (;;) {
        if (spb_session_read_frame(session, &info, cells, cells_cap,
                                   lattrs, dirty, rows_cap))
            return;
        size_t need = (size_t)info.cols * info.rows;
        if (!need)
            return;
        cells = realloc(cells, need * sizeof(spb_cell));
        cells_cap = need;
        lattrs = realloc(lattrs, info.rows);
        dirty = realloc(dirty, info.rows);
        rows_cap = info.rows;
    }
}

static spb_cell *cell_at(int x, int y)
{
    return &cells[(size_t)y * info.cols + x];
}

/* Row text as UTF-8, blanks as spaces, trailing spaces removed. */
static const char *row_text(int y)
{
    static char buf[4096];
    size_t n = 0;
    for (int x = 0; x < info.cols && n < sizeof(buf) - 16; x++) {
        spb_cell *c = cell_at(x, y);
        if (c->flags & SPB_CELL_WIDE_CONT)
            continue;
        for (int i = 0; i < SPB_CELL_MAX_CHARS && (i == 0 || c->chars[i]);
             i++) {
            uint32_t u = c->chars[i] ? c->chars[i] : ' ';
            if (u < 0x80) {
                buf[n++] = (char)u;
            } else if (u < 0x800) {
                buf[n++] = (char)(0xC0 | u >> 6);
                buf[n++] = (char)(0x80 | (u & 0x3F));
            } else if (u < 0x10000) {
                buf[n++] = (char)(0xE0 | u >> 12);
                buf[n++] = (char)(0x80 | (u >> 6 & 0x3F));
                buf[n++] = (char)(0x80 | (u & 0x3F));
            } else {
                buf[n++] = (char)(0xF0 | u >> 18);
                buf[n++] = (char)(0x80 | (u >> 12 & 0x3F));
                buf[n++] = (char)(0x80 | (u >> 6 & 0x3F));
                buf[n++] = (char)(0x80 | (u & 0x3F));
            }
        }
    }
    while (n && buf[n - 1] == ' ')
        n--;
    buf[n] = '\0';
    return buf;
}

typedef bool (*frame_pred)(const void *arg);

/* Wait until the frame satisfies pred (reading each new frame). */
static bool wait_frame(frame_pred pred, const void *arg, double timeout)
{
    double deadline = now_seconds() + timeout;
    for (;;) {
        read_frame();
        if (info.cols && pred(arg))
            return true;
        if (now_seconds() >= deadline)
            return false;
        usleep(2000);
    }
}

typedef struct row_is { int y; const char *text; } row_is;

static bool pred_row(const void *arg)
{
    const row_is *r = arg;
    return r->y < info.rows && !strcmp(row_text(r->y), r->text);
}

static bool wait_row(int y, const char *text)
{
    row_is r = { y, text };
    bool ok = wait_frame(pred_row, &r, 10);
    if (!ok)
        fprintf(stderr, "  row %d is \"%s\", expected \"%s\"\n", y,
                y < info.rows ? row_text(y) : "(none)", text);
    return ok;
}

/* ---------- The server end ---------- */

static void peer_write(const char *data)
{
    size_t len = strlen(data);
    while (len) {
        ssize_t n = write(peer, data, len);
        if (n <= 0)
            return;
        data += n;
        len -= n;
    }
}

/* Read what the client sent within `timeout`, stopping early once
 * `expect_len` bytes arrived. */
static size_t peer_read(char *buf, size_t cap, size_t expect_len,
                        double timeout)
{
    size_t n = 0;
    double deadline = now_seconds() + timeout;
    while (n < cap && (expect_len == 0 || n < expect_len)) {
        double left = deadline - now_seconds();
        if (left <= 0)
            break;
        struct pollfd pfd = { .fd = peer, .events = POLLIN };
        if (poll(&pfd, 1, (int)(left * 1000) + 1) <= 0)
            break;
        ssize_t r = read(peer, buf + n, cap - n);
        if (r <= 0)
            break;
        n += r;
    }
    return n;
}

/* Expect exactly these bytes from the client. */
static void expect_sent(const char *what, const char *expected, size_t len)
{
    char buf[256];
    size_t n = peer_read(buf, sizeof(buf), len, 5);
    if (n != len || memcmp(buf, expected, len)) {
        fprintf(stderr, "  %s: expected", what);
        for (size_t i = 0; i < len; i++)
            fprintf(stderr, " %02x", (unsigned char)expected[i]);
        fprintf(stderr, ", got");
        for (size_t i = 0; i < n; i++)
            fprintf(stderr, " %02x", (unsigned char)buf[i]);
        fprintf(stderr, "\n");
        failures++;
    }
}

#define EXPECT_SENT(what, lit) expect_sent(what, lit, sizeof(lit) - 1)

/* Make sure every earlier escape sequence has been processed. */
static void sync_terminal(void)
{
    static int n;
    char marker[32], line[32];
    snprintf(marker, sizeof(marker), "\033[%d;1H\033[2Ksync%d", info.rows,
             ++n);
    peer_write(marker);
    snprintf(line, sizeof(line), "sync%d", n);
    CHECK(wait_row(info.rows - 1, line));
    peer_write("\033[2K\033[H");
}

/* extra: NULL-terminated keyword/value pairs applied over the defaults. */
static void open_session(const char *const *extra)
{
    WITH_EVENTS(ev.connected = false; ev.released = false;
                ev.clip_writes = 0; ev.paste_requests = 0; ev.bells = 0);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t len = sizeof(addr);
    if (bind(listener, (struct sockaddr *)&addr, len) < 0 ||
        listen(listener, 1) < 0 ||
        getsockname(listener, (struct sockaddr *)&addr, &len) < 0) {
        perror("listen");
        exit(2);
    }
    char port[16];
    snprintf(port, sizeof(port), "%d", ntohs(addr.sin_port));

    spb_settings *s = spb_settings_new_defaults();
    spb_settings_set(s, "Protocol", "raw");
    spb_settings_set(s, "HostName", "127.0.0.1");
    spb_settings_set(s, "PortNumber", port);
    spb_settings_set(s, "LocalEcho", "1");      /* force off */
    spb_settings_set(s, "LocalEdit", "1");      /* force off */
    spb_settings_set(s, "UTF8linedraw", "1");
    for (; extra && *extra; extra += 2)
        spb_settings_set(s, extra[0], extra[1]);
    char *err = NULL;
    session = spb_session_create(s, &callbacks, NULL, &err);
    spb_settings_free(s);
    if (!session) {
        fprintf(stderr, "create: %s\n", err);
        exit(2);
    }
    spb_session_set_focus(session, true);
    spb_session_start(session);
    peer = accept(listener, NULL, NULL);
    close(listener);
    CHECK(wait_events(is_connected, 10));
}

/* ---------- Tests ---------- */

static bool pred_any(const void *arg) { return true; }

static void test_initial_frame(void)
{
    CHECK(wait_frame(pred_any, NULL, 10));
    CHECK(info.cols == 80 && info.rows == 24);
    CHECK(info.default_fg == 0xBBBBBB);         /* PuTTY default colours */
    CHECK(info.default_bg == 0x000000);
    CHECK(info.cursor_colour == 0x00FF00);
    CHECK(info.cursor_style == SPB_CURSOR_BLOCK);
    CHECK(cell_at(1, 0)->bg == 0x000000);
    CHECK(cell_at(0, 0)->bg == 0x00FF00);      /* active block cursor */
}

static void test_text_and_colours(void)
{
    peer_write("Hello, world\r\n");
    CHECK(wait_row(0, "Hello, world"));

    peer_write("\033[2;1H"
               "\033[31mR\033[0m"               /* red */
               "\033[1;32mG\033[0m"             /* bold green: bold colour */
               "\033[7mV\033[0m"                /* reverse */
               "\033[4mU\033[0m"                /* underline */
               "\033[38;2;10;20;30mT\033[0m"    /* true colour */
               "\033[38;5;196mX\033[0m"         /* 256-colour cube */
               "\033[44mB\033[0m"               /* blue background */
               "\033[9mS\033[0m"                /* strikethrough */
               "\033[2mD\033[0m");              /* dim */
    CHECK(wait_row(1, "RGVUTXBSD"));
    CHECK(cell_at(0, 1)->fg == 0xBB0000);
    CHECK(cell_at(1, 1)->fg == 0x55FF55);
    CHECK(!(cell_at(1, 1)->flags & SPB_CELL_BOLD));   /* BoldAsColour */
    CHECK(cell_at(2, 1)->fg == 0x000000 && cell_at(2, 1)->bg == 0xBBBBBB);
    CHECK(cell_at(3, 1)->flags & SPB_CELL_UNDERLINE);
    CHECK(cell_at(4, 1)->fg == 0x0A141E);
    CHECK(cell_at(5, 1)->fg == 0xFF0000);
    CHECK(cell_at(6, 1)->bg == 0x0000BB);
    CHECK(cell_at(7, 1)->flags & SPB_CELL_STRIKE);
    CHECK(cell_at(8, 1)->fg == 0x7C7C7C);             /* 0xBB * 2/3 */
}

static void test_unicode(void)
{
    peer_write("\033[3;1H\xe4\xb8\xad" "e\xcc\x81" "\xf0\x9f\x98\x80" "|");
    CHECK(wait_row(2, "\xe4\xb8\xad" "e\xcc\x81" "\xf0\x9f\x98\x80" "|"));
    CHECK(cell_at(0, 2)->chars[0] == 0x4E2D);
    CHECK(cell_at(0, 2)->flags & SPB_CELL_WIDE);
    CHECK(cell_at(1, 2)->flags & SPB_CELL_WIDE_CONT);
    CHECK(cell_at(2, 2)->chars[0] == 'e' && cell_at(2, 2)->chars[1] == 0x301);
    CHECK(cell_at(3, 2)->chars[0] == 0x1F600);
    CHECK(cell_at(3, 2)->flags & SPB_CELL_WIDE);
    CHECK(cell_at(5, 2)->chars[0] == '|');
}

static void test_line_drawing_and_double_width(void)
{
    /* DEC special graphics: lqk -> box drawing (UTF8linedraw is set,
     * since PuTTY ignores it in UTF-8 mode by default); DECDWL line. */
    peer_write("\033[4;1H\033(0lqk\033(B");
    CHECK(wait_row(3, "\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90"));
    peer_write("\033[5;1H\033#6Wide");
    CHECK(wait_row(4, "Wide"));
    CHECK(lattrs[4] == SPB_LINE_DOUBLE_WIDTH);
    CHECK(lattrs[3] == SPB_LINE_NORMAL);
}

typedef struct cursor_at { int x, y; uint32_t flags; } cursor_at;

static bool pred_cursor(const void *arg)
{
    const cursor_at *c = arg;
    spb_cell *cell = cell_at(c->x, c->y);
    if (c->flags)
        return (cell->flags & c->flags) == c->flags;
    return cell->bg == 0x00FF00 && !(cell->flags & SPB_CELL_CURSOR);
}

static void test_cursor(void)
{
    peer_write("\033[10;20H");
    cursor_at active = { 19, 9, 0 };
    CHECK(wait_frame(pred_cursor, &active, 10));       /* block, active */

    spb_session_set_focus(session, false);
    cursor_at passive = { 19, 9, SPB_CELL_CURSOR | SPB_CELL_CURSOR_PASSIVE };
    CHECK(wait_frame(pred_cursor, &passive, 10));
    spb_session_set_focus(session, true);
    CHECK(wait_frame(pred_cursor, &active, 10));
}

static void test_title_and_bell(void)
{
    peer_write("\033]0;My \xc3\xa9 Title\007");
    peer_write("\007");
    sync_terminal();
    pthread_mutex_lock(&ev.lock);
    CHECK_STR(ev.title, "My \xc3\xa9 Title");
    CHECK(ev.bells == 1);
    pthread_mutex_unlock(&ev.lock);
}

static bool pred_size(const void *arg)
{
    const int *wh = arg;
    return info.cols == wh[0] && info.rows == wh[1];
}

static void test_resize(void)
{
    spb_session_resize(session, 100, 30, 800, 480);
    int wh[2] = { 100, 30 };
    CHECK(wait_frame(pred_size, wh, 10));
    peer_write("\033[30;100Hz");
    CHECK(wait_row(29, "                                                    "
                       "                                               z"));

    /* The application asks for a size (xterm window op 8). */
    peer_write("\033[8;40;120t");
    sync_terminal();
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.resize_cols == 120 && ev.resize_rows == 40);
    pthread_mutex_unlock(&ev.lock);

    spb_session_resize(session, 80, 24, 640, 384);
    int back[2] = { 80, 24 };
    CHECK(wait_frame(pred_size, back, 10));
}

static bool pred_scrolled(const void *arg)
{
    const int *start = arg;
    return info.scroll_start == *start;
}

static void test_scrollback(void)
{
    peer_write("\033[2J\033[H");
    for (int i = 1; i <= 100; i++) {
        char line[32];
        snprintf(line, sizeof(line), "line %d\r\n", i);
        peer_write(line);
    }
    CHECK(wait_row(22, "line 100"));
    CHECK(info.scroll_page == 24);
    CHECK(info.scroll_total >= 100);
    int bottom = info.scroll_total - info.scroll_page;
    CHECK(info.scroll_start == bottom);

    spb_session_scroll(session, SPB_SCROLL_RELATIVE, -10);
    int up10 = bottom - 10;
    CHECK(wait_frame(pred_scrolled, &up10, 10));
    CHECK_STR(row_text(22), "line 90");

    spb_session_wheel(session, 1, 0, 0, 0);            /* 5 lines up */
    int up15 = bottom - 15;
    CHECK(wait_frame(pred_scrolled, &up15, 10));

    spb_session_key(session, SPB_KEY_PAGE_UP, SPB_MOD_SHIFT);  /* half page */
    int up27 = bottom - 27;
    CHECK(wait_frame(pred_scrolled, &up27, 10));

    spb_session_scroll(session, SPB_SCROLL_TO_BOTTOM, 0);
    CHECK(wait_frame(pred_scrolled, &bottom, 10));
    CHECK_STR(row_text(22), "line 100");
    peer_write("\033[2J\033[H");
}

static void test_keys(void)
{
    spb_session_key(session, SPB_KEY_UP, 0);
    EXPECT_SENT("Up", "\033[A");
    spb_session_key(session, SPB_KEY_LEFT, SPB_MOD_CTRL);
    EXPECT_SENT("Ctrl-Left", "\033OD");
    peer_write("\033[?1h");                            /* DECCKM */
    sync_terminal();
    spb_session_key(session, SPB_KEY_UP, 0);
    EXPECT_SENT("Up (application)", "\033OA");
    peer_write("\033[?1l");
    sync_terminal();

    spb_session_key(session, SPB_KEY_F1, 0);
    EXPECT_SENT("F1", "\033[11~");
    spb_session_key(session, SPB_KEY_F1 + 9, 0);
    EXPECT_SENT("F10", "\033[21~");
    spb_session_key(session, SPB_KEY_HOME, 0);
    EXPECT_SENT("Home", "\033[1~");
    spb_session_key(session, SPB_KEY_DELETE, 0);
    EXPECT_SENT("Delete", "\033[3~");
    spb_session_key(session, SPB_KEY_PAGE_DOWN, 0);
    EXPECT_SENT("PageDown", "\033[6~");
    spb_session_key(session, SPB_KEY_BACKSPACE, 0);
    EXPECT_SENT("Backspace", "\177");
    spb_session_key(session, SPB_KEY_BACKSPACE, SPB_MOD_SHIFT);
    EXPECT_SENT("Shift-Backspace", "\010");
    spb_session_key(session, SPB_KEY_RETURN, 0);
    EXPECT_SENT("Return", "\r");
    spb_session_key(session, SPB_KEY_RETURN, SPB_MOD_META);
    EXPECT_SENT("Meta-Return", "\033\r");
    spb_session_key(session, SPB_KEY_TAB, 0);
    EXPECT_SENT("Tab", "\t");
    spb_session_key(session, SPB_KEY_TAB, SPB_MOD_SHIFT);
    EXPECT_SENT("Shift-Tab", "\033[Z");
    spb_session_key(session, SPB_KEY_ESCAPE, 0);
    EXPECT_SENT("Escape", "\033");
    spb_session_key(session, SPB_KEY_UP, SPB_MOD_META);
    EXPECT_SENT("Meta-Up", "\033\033[A");

    spb_session_key(session, SPB_KEY_KP_0 + 5, 0);
    EXPECT_SENT("Keypad 5", "5");
    spb_session_key(session, SPB_KEY_KP_ENTER, 0);
    EXPECT_SENT("Keypad Enter", "\r");
    peer_write("\033=");                               /* DECKPAM */
    sync_terminal();
    spb_session_key(session, SPB_KEY_KP_0 + 5, 0);
    EXPECT_SENT("Keypad 5 (application)", "\033Ou");
    spb_session_key(session, SPB_KEY_KP_ENTER, 0);
    EXPECT_SENT("Keypad Enter (application)", "\033OM");
    peer_write("\033>");
    sync_terminal();

    spb_session_text(session, "h\xc3\xa9llo", 6, 0);
    EXPECT_SENT("text", "h\xc3\xa9llo");
    spb_session_text(session, "x", 1, SPB_MOD_META);
    EXPECT_SENT("Meta-x", "\033x");
    spb_session_text(session, "\003", 1, 0);
    EXPECT_SENT("Ctrl-C", "\003");

    /* "Ctrl + Shift + {C,V}" is "No action" by default: they type. */
    spb_session_key(session, SPB_KEY_C, SPB_MOD_CTRL | SPB_MOD_SHIFT);
    EXPECT_SENT("Ctrl-Shift-C (no action)", "\003");
    spb_session_key(session, SPB_KEY_V, SPB_MOD_CTRL | SPB_MOD_SHIFT | SPB_MOD_META);
    EXPECT_SENT("Meta-Ctrl-Shift-V (no action)", "\033\026");
}

static void test_paste(void)
{
    spb_session_paste(session, "one\ntwo", 7);
    EXPECT_SENT("paste", "one\rtwo");
    peer_write("\033[?2004h");                         /* bracketed paste */
    sync_terminal();
    spb_session_paste(session, "a\xc3\xa9", 3);
    EXPECT_SENT("bracketed paste", "\033[200~a\xc3\xa9\033[201~");
    peer_write("\033[?2004l");
    sync_terminal();
}

static bool clip_written(void) { return ev.clip_writes > 0; }
static bool paste_requested(void) { return ev.paste_requests > 0; }

static void test_selection_and_clipboard(void)
{
    peer_write("\033[2J\033[1;1Hselect me please");
    CHECK(wait_row(0, "select me please"));

    /* Drag-select "select me" and release: copied to the selection. */
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_CLICK, 0, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_DRAG, 8, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_RELEASE, 8, 0, 0);
    CHECK(wait_events(clip_written, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK_STR(ev.clip_text, "select me");
    CHECK(ev.clip_which == SPB_CLIPBOARD_SELECTION);
    ev.clip_writes = 0;
    pthread_mutex_unlock(&ev.lock);

    /* Double-click selects a word. */
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_DOUBLE_CLICK, 11, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_RELEASE, 11, 0, 0);
    CHECK(wait_events(clip_written, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK_STR(ev.clip_text, "please");
    ev.clip_writes = 0;
    pthread_mutex_unlock(&ev.lock);

    /* Right button pastes (Windows mouse mode) from the selection. */
    spb_session_mouse(session, SPB_MOUSE_RIGHT, SPB_MOUSE_CLICK, 0, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_RIGHT, SPB_MOUSE_RELEASE, 0, 0, 0);
    CHECK(wait_events(paste_requested, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.paste_which == SPB_CLIPBOARD_SELECTION);
    pthread_mutex_unlock(&ev.lock);

    /* Copy All goes to the system clipboard. */
    spb_session_copy_all(session);
    CHECK(wait_events(clip_written, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.clip_which == SPB_CLIPBOARD_SYSTEM);
    CHECK(ev.clip_has_marker);           /* scrollback comes first */
    pthread_mutex_unlock(&ev.lock);
}

static bool pred_raw_mouse(const void *arg)
{
    return info.raw_mouse == *(const bool *)arg;
}

static void test_mouse_reporting(void)
{
    peer_write("\033[?1000h");                         /* X11 mouse reporting */
    bool on = true;
    CHECK(wait_frame(pred_raw_mouse, &on, 10));
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_CLICK, 2, 3, 0);
    EXPECT_SENT("mouse press", "\033[M #$");
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_RELEASE, 2, 3, 0);
    EXPECT_SENT("mouse release", "\033[M##$");
    spb_session_wheel(session, 1, 4, 5, 0);
    EXPECT_SENT("wheel up", "\033[M`%&");
    peer_write("\033[?1000l");
    bool off = false;
    CHECK(wait_frame(pred_raw_mouse, &off, 10));
}

static bool pred_counter_row(const void *arg)
{
    return !strcmp(row_text(info.rows - 2), (const char *)arg);
}

static void test_output_is_coalesced(void)
{
    pthread_mutex_lock(&ev.lock);
    int before = ev.updates;
    pthread_mutex_unlock(&ev.lock);

    /* 20,000 lines in one burst; the frontend reads as it is told. */
    size_t cap = 20000 * 16 + 1, n = 0;
    char *burst = malloc(cap);
    for (int i = 1; i <= 20000; i++)
        n += snprintf(burst + n, cap - n, "burst %d\r\n", i);
    double start = now_seconds();
    peer_write(burst);
    free(burst);
    CHECK(wait_frame(pred_counter_row, "burst 20000", 30));
    double elapsed = now_seconds() - start;

    pthread_mutex_lock(&ev.lock);
    int frames = ev.updates - before;
    pthread_mutex_unlock(&ev.lock);
    printf("  20,000 lines: %.3f s, %d frame notifications\n", elapsed,
           frames);
    CHECK(frames > 0 && frames < 2000);
}

static void test_close_and_release(void);

static bool is_exported(void) { return ev.exported != NULL; }
static int want_reconfigured;
static bool is_reconfigured(void) { return ev.reconfigured >= want_reconfigured; }

/* Change Settings on the running session: export, edit, apply. */
static spb_settings *export_running(void)
{
    WITH_EVENTS(spb_settings_free(ev.exported); ev.exported = NULL);
    spb_session_export_settings(session, 1);
    CHECK(wait_events(is_exported, 10));
    pthread_mutex_lock(&ev.lock);
    spb_settings *s = ev.exported;
    ev.exported = NULL;
    pthread_mutex_unlock(&ev.lock);
    return s;
}

static void apply(spb_settings *s)
{
    pthread_mutex_lock(&ev.lock);
    want_reconfigured = ev.reconfigured + 1;
    pthread_mutex_unlock(&ev.lock);
    spb_session_reconfigure(session, s, 2);
    CHECK(wait_events(is_reconfigured, 10));
}

static bool pred_default_fg(const void *arg)
{
    return info.default_fg == *(const uint32_t *)arg;
}

static bool pred_scroll_total(const void *arg)
{
    return info.scroll_total == *(const int *)arg;
}

/* M07: settings changed while connected take effect at once. */
static void test_live_reconfigure(void)
{
    /* The live window title becomes the configured one (term_pre_reconfig),
     * so an untouched title field keeps it. */
    int size[2] = { 90, 25 };
    spb_session_resize(session, 90, 25, 720, 400);
    CHECK(wait_frame(pred_size, size, 10));
    peer_write("\033]0;Live Title\007");
    sync_terminal();
    spb_settings *s = export_running();
    CHECK(s && !strcmp(spb_settings_get(s, "WinTitle"), "Live Title"));
    CHECK(s && !strcmp(spb_settings_get(s, "BackspaceIsDelete"), "0"));
    /* The size is the window's, not the one configured at the start. */
    char cols[16], rows[16];
    snprintf(cols, sizeof(cols), "%d", info.cols);
    snprintf(rows, sizeof(rows), "%d", info.rows);
    CHECK(s && !strcmp(spb_settings_get(s, "TermWidth"), cols));
    CHECK(s && !strcmp(spb_settings_get(s, "TermHeight"), rows));

    /* Keyboard: back to ^? and ESC[n~ function keys. */
    spb_settings_set(s, "BackspaceIsDelete", "1");
    spb_settings_set(s, "LinuxFunctionKeys", "0");
    /* Colours: a new default foreground. */
    spb_settings_set(s, "Colour0", "10,20,30");
    /* Scrollback: fewer lines kept. */
    spb_settings_set(s, "ScrollbackLines", "10");
    apply(s);
    spb_settings_free(s);

    spb_session_key(session, SPB_KEY_BACKSPACE, 0);
    EXPECT_SENT("Backspace after reconfigure", "\177");
    spb_session_key(session, SPB_KEY_F1, 0);
    EXPECT_SENT("F1 after reconfigure", "\033[11~");
    uint32_t fg = 0x0A141E;
    CHECK(wait_frame(pred_default_fg, &fg, 10));
    for (int i = 0; i < 60; i++)
        peer_write("line\r\n");
    sync_terminal();
    int limit = 10 + info.rows;         /* exactly 10 lines of scrollback */
    CHECK(wait_frame(pred_scroll_total, &limit, 10));

    /* The running settings now read back as applied. */
    s = export_running();
    CHECK(s && !strcmp(spb_settings_get(s, "Colour0"), "10,20,30"));
    CHECK(s && !strcmp(spb_settings_get(s, "ScrollbackLines"), "10"));
    spb_settings_free(s);
}

/* ---------- A second session with non-default settings (M06) ---------- */

static const char *const configured[] = {
    "CtrlShiftCV", "explicit",
    "CtrlShiftIns", "explicit",
    "LinuxFunctionKeys", "1",          /* Linux */
    "RXVTHomeEnd", "1",
    "BackspaceIsDelete", "0",
    "BlinkCur", "1",
    NULL,
};

static bool pred_cursor_shown(const void *arg)
{
    bool want = *(const bool *)arg;
    spb_cell *cell = cell_at(19, 9);
    bool shown = cell->bg == 0x00FF00 && !(cell->flags & SPB_CELL_CURSOR);
    return shown == want;
}

static void test_configured_session(void)
{
    open_session(configured);

    /* Keyboard settings reach PuTTY's formatters. */
    spb_session_key(session, SPB_KEY_F1, 0);
    EXPECT_SENT("F1 (Linux)", "\033[[A");
    spb_session_key(session, SPB_KEY_HOME, 0);
    EXPECT_SENT("Home (rxvt)", "\033[H");
    spb_session_key(session, SPB_KEY_END, 0);
    EXPECT_SENT("End (rxvt)", "\033Ow");
    spb_session_key(session, SPB_KEY_BACKSPACE, 0);
    EXPECT_SENT("Backspace (^H)", "\010");

    /* Ctrl+Shift+C copies the selection to the system clipboard. */
    peer_write("\033[2J\033[1;1Hcopy this");
    CHECK(wait_row(0, "copy this"));
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_CLICK, 0, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_DRAG, 3, 0, 0);
    spb_session_mouse(session, SPB_MOUSE_LEFT, SPB_MOUSE_RELEASE, 3, 0, 0);
    CHECK(wait_events(clip_written, 10));
    WITH_EVENTS(ev.clip_writes = 0);
    spb_session_key(session, SPB_KEY_C, SPB_MOD_CTRL | SPB_MOD_SHIFT);
    CHECK(wait_events(clip_written, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.clip_which == SPB_CLIPBOARD_SYSTEM);
    CHECK_STR(ev.clip_text, "copy");
    ev.clip_writes = 0;
    pthread_mutex_unlock(&ev.lock);

    /* Ctrl+Insert does the same with "{Ctrl,Shift} + Ins" explicit. */
    spb_session_key(session, SPB_KEY_INSERT, SPB_MOD_CTRL);
    CHECK(wait_events(clip_written, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.clip_which == SPB_CLIPBOARD_SYSTEM);
    pthread_mutex_unlock(&ev.lock);

    /* Ctrl+Shift+V and Shift+Insert paste from the system clipboard. */
    spb_session_key(session, SPB_KEY_V, SPB_MOD_CTRL | SPB_MOD_SHIFT);
    CHECK(wait_events(paste_requested, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.paste_which == SPB_CLIPBOARD_SYSTEM);
    ev.paste_requests = 0;
    pthread_mutex_unlock(&ev.lock);
    spb_session_key(session, SPB_KEY_INSERT, SPB_MOD_SHIFT);
    CHECK(wait_events(paste_requested, 10));
    pthread_mutex_lock(&ev.lock);
    CHECK(ev.paste_which == SPB_CLIPBOARD_SYSTEM);
    pthread_mutex_unlock(&ev.lock);

    /* "Cursor blinks": PuTTY's terminal shows and hides the cursor. */
    peer_write("\033[10;20H");
    bool hidden = false, shown = true;
    CHECK(wait_frame(pred_cursor_shown, &hidden, 5));
    CHECK(wait_frame(pred_cursor_shown, &shown, 5));
    CHECK(wait_frame(pred_cursor_shown, &hidden, 5));

    test_live_reconfigure();
    test_close_and_release();
}

static void test_close_and_release(void)
{
    close(peer);                                       /* remote end goes */
    spb_session_release(session);
    CHECK(wait_events(is_released, 10));
    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);
}

int main(void)
{
    char template[] = "/tmp/spb-terminal-test-XXXXXX";
    char *base = mkdtemp(template);
    char state_dir[512];
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);
    char *err = NULL;
    spb_core_options opts = { .state_dir = state_dir };
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "init: %s\n", err);
        return 2;
    }

    open_session(NULL);
    test_initial_frame();
    test_text_and_colours();
    test_unicode();
    test_line_drawing_and_double_width();
    test_cursor();
    test_title_and_bell();
    test_resize();
    test_scrollback();
    test_keys();
    test_paste();
    test_selection_and_clipboard();
    test_mouse_reporting();
    test_output_is_coalesced();
    test_close_and_release();
    test_configured_session();

    CHECK(spb_core_shutdown());
    free(cells);
    free(lattrs);
    free(dirty);
    char seed[600];
    snprintf(seed, sizeof(seed), "%s/randomseed", state_dir);
    unlink(seed);
    rmdir(state_dir);
    rmdir(base);

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("spb_terminal_test: all checks passed\n");
    return 0;
}
