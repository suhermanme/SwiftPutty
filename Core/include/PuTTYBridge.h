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

#define SPB_API_VERSION 5

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

/*
 * What PuTTY does to settings just before it connects (upstream
 * prepare_session, as GTK PuTTY's new_session_window): leading
 * whitespace is trimmed from the host name, a "user@" prefix becomes the
 * user name, a single ":suffix" is dropped, and remaining whitespace is
 * removed. spb_session_create applies it itself; frontends call it to
 * show the destination as it will be used. Also normalises.
 */
void spb_settings_prepare_session(spb_settings *settings);

/* ---------- Session ---------- */

typedef struct spb_session spb_session;

/* Clipboards, as PuTTY's Unix frontend has them (see
 * docs/CONFIGURATION_PARITY.md): the general pasteboard, and the "last
 * selected text" that mouse selection and middle-button paste use. */
typedef enum spb_clipboard {
    SPB_CLIPBOARD_SELECTION,  /* PuTTY CLIP_PRIMARY: app-private buffer */
    SPB_CLIPBOARD_SYSTEM,     /* PuTTY CLIP_CLIPBOARD: NSPasteboard.general */
} spb_clipboard;

/* Questions PuTTY asks the user in a dialog box (not in the terminal). */
typedef enum spb_prompt_kind {
    /* The server's host key is not cached, or differs from the cached
     * one. Answers: ACCEPT_AND_STORE ("Accept"), ACCEPT_ONCE ("Connect
     * Once"), CANCEL. */
    SPB_PROMPT_HOST_KEY,
    /* A negotiated algorithm is below the configured warning threshold.
     * Answers: ACCEPT_ONCE ("Yes"), CANCEL ("No"). */
    SPB_PROMPT_WEAK_CRYPTO,
    /* The cached host key's type is below the warning threshold, though
     * a better one is available. Answers as for WEAK_CRYPTO. */
    SPB_PROMPT_WEAK_CACHED_HOST_KEY,
    /* The session log file exists and the settings say to ask (API v5).
     * Answers: LOG_OVERWRITE ("Overwrite"), LOG_APPEND ("Append"), CANCEL
     * ("Disable": no log for this session). Asked independently of the
     * dialogs above, so two prompts can be pending at once; it is not
     * withdrawn when the connection ends, only when the session is
     * released. */
    SPB_PROMPT_LOG_FILE_EXISTS,
} spb_prompt_kind;

/* PuTTY's structured dialog text (SeatDialogText). */
typedef enum spb_dialog_item_type {
    SPB_DIALOG_PARAGRAPH,        /* a paragraph of prose */
    SPB_DIALOG_DISPLAY,          /* a fingerprint etc.: monospaced, own line */
    SPB_DIALOG_SCARY_HEADING,    /* "WARNING - POTENTIAL SECURITY BREACH!" */
    SPB_DIALOG_TITLE,            /* the dialog's title */
    SPB_DIALOG_PROMPT,           /* the question (console wording; may be
                                    omitted by GUIs, as GTK PuTTY does) */
    SPB_DIALOG_MORE_INFO_KEY,    /* "More info": a label ... */
    SPB_DIALOG_MORE_INFO_SHORT,  /* ... and its short value ... */
    SPB_DIALOG_MORE_INFO_BLOB,   /* ... or long value (wrap it) */
} spb_dialog_item_type;

typedef struct spb_dialog_item {
    spb_dialog_item_type type;
    const char *text;
} spb_dialog_item;

typedef struct spb_prompt {
    spb_prompt_kind kind;
    uint64_t id;                 /* pass to spb_session_answer_prompt */
    const spb_dialog_item *items;
    size_t n_items;
} spb_prompt;

typedef enum spb_prompt_answer {
    SPB_ANSWER_CANCEL,
    SPB_ANSWER_ACCEPT_ONCE,
    SPB_ANSWER_ACCEPT_AND_STORE,
    SPB_ANSWER_LOG_OVERWRITE,    /* API v5 */
    SPB_ANSWER_LOG_APPEND,       /* API v5 */
} spb_prompt_answer;

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
    /* A copy of the data received from the backend, before the terminal
     * interprets it (diagnostics and tests). */
    void (*output)(void *ctx, const void *data, size_t len, bool is_stderr);
    /* The remote end exited; exit_code as PuTTY's backend_exitcode()
     * (INT32_MAX for an unclean exit). Reported before CLOSED. */
    void (*remote_exit)(void *ctx, int32_t exit_code);
    /* Final call; see above. */
    void (*released)(void *ctx);

    /* --- Terminal (M03) --- */

    /* The terminal has a new frame; read it with spb_session_read_frame.
     * Not called again until the frame has been read. */
    void (*terminal_updated)(void *ctx);
    /* Window or icon title set by the terminal (UTF-8). */
    void (*title_changed)(void *ctx, const char *title, bool icon_title);
    /* The terminal rang the bell; mode as CONF_beep (BELL_*). */
    void (*bell)(void *ctx, int32_t mode);
    /* Put text on a clipboard (UTF-8). */
    void (*clipboard_write)(void *ctx, spb_clipboard clipboard,
                            const char *text, size_t len);
    /* The terminal wants a paste: answer with spb_session_paste. */
    void (*paste_requested)(void *ctx, spb_clipboard clipboard);
    /* The remote end asked for a terminal size (e.g. DECCOLM). The
     * request is acknowledged at once; the frontend may resize. */
    void (*resize_requested)(void *ctx, int32_t cols, int32_t rows);

    /* --- Dialogs (M04) --- */

    /* PuTTY needs an answer: show a dialog, then call
     * spb_session_answer_prompt. The connection waits meanwhile. If the
     * connection ends first, prompt_cancelled is called and the answer is
     * no longer wanted. Without this callback, prompts are refused. */
    void (*prompt)(void *ctx, const spb_prompt *prompt);
    void (*prompt_cancelled)(void *ctx, uint64_t id);
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
 * SSH and Raw are supported; other protocols fail with an explanatory
 * message until their milestone (M11). SSH logins (user name, password,
 * keyboard-interactive) are prompted for in the terminal, as in PuTTY;
 * host key confirmation goes through the prompt callback.
 */
void spb_session_start(spb_session *session);

/* Answer a prompt (spb_session_callbacks.prompt). Answers for prompts
 * that are no longer pending are ignored. */
void spb_session_answer_prompt(spb_session *session, uint64_t prompt_id,
                               spb_prompt_answer answer);

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

/* ---------- Terminal ----------
 *
 * Every session has a PuTTY Terminal (terminal/terminal.c) on the core
 * thread. Its drawing is recorded into a grid of resolved cells and
 * published as frames (docs/ARCHITECTURE.md section 8). The terminal is
 * created with the Conf's TermWidth x TermHeight and resized with
 * spb_session_resize.
 */

#define SPB_CELL_MAX_CHARS 4

enum {
    SPB_CELL_BOLD           = 1u << 0,  /* draw with a bold font */
    SPB_CELL_UNDERLINE      = 1u << 1,
    SPB_CELL_STRIKE         = 1u << 2,
    SPB_CELL_WIDE           = 1u << 3,  /* first half of a two-column char */
    SPB_CELL_WIDE_CONT      = 1u << 4,  /* second half: draw nothing */
    SPB_CELL_CURSOR         = 1u << 5,  /* draw the cursor overlay here */
    SPB_CELL_CURSOR_PASSIVE = 1u << 6,  /* ...as the unfocused form */
    SPB_CELL_CURSOR_RIGHT   = 1u << 7,  /* vertical-line cursor at the right */
    SPB_CELL_TRUST_SIGIL    = 1u << 8,  /* PuTTY's trust sigil (2 columns) */
};

/* One terminal cell, with colours already resolved (reverse video, bold
 * as colour, dim, true colour, active block cursor). */
typedef struct spb_cell {
    /* Base character then combining characters, Unicode; unused slots
     * are 0. chars[0] == 0 means blank. */
    uint32_t chars[SPB_CELL_MAX_CHARS];
    uint32_t fg, bg;                     /* 0xRRGGBB */
    uint32_t flags;                      /* SPB_CELL_* */
} spb_cell;

typedef enum spb_line_attr {
    SPB_LINE_NORMAL,
    SPB_LINE_DOUBLE_WIDTH,     /* DECDWL: cells are 2 columns wide */
    SPB_LINE_DOUBLE_TOP,       /* DECDHL top half */
    SPB_LINE_DOUBLE_BOTTOM,    /* DECDHL bottom half */
} spb_line_attr;

typedef enum spb_cursor_style {
    SPB_CURSOR_BLOCK,          /* active block: in the cell colours */
    SPB_CURSOR_UNDERLINE,
    SPB_CURSOR_VERTICAL_LINE,
} spb_cursor_style;

typedef struct spb_frame_info {
    int32_t cols, rows;
    /* All rows must be treated as changed (first read, or a resize). */
    bool full;
    spb_cursor_style cursor_style;
    uint32_t cursor_colour;              /* overlay cursors, 0xRRGGBB */
    uint32_t default_fg, default_bg;     /* window background etc. */
    int32_t cursor_x, cursor_y;          /* text cursor (input methods) */
    /* Scrollback, as PuTTY's set_scrollbar: lines in total, first
     * visible line, visible lines. */
    int32_t scroll_total, scroll_start, scroll_page;
    bool raw_mouse;                      /* the application wants mouse events */
    bool raw_mouse_pointer;              /* show the mouse-reporting pointer */
} spb_frame_info;

/*
 * Copy the latest frame. `cells` holds rows * cols cells (row-major) and
 * persists between calls: only rows marked in `dirty_rows` (one byte per
 * row) are written, unless info->full. `line_attrs` (one per row) is
 * always written. Returns false without copying cells if a capacity is
 * too small (info still says the required size), or if the terminal does
 * not exist yet (info->cols == 0). May be called from any thread.
 */
bool spb_session_read_frame(spb_session *session, spb_frame_info *info,
                            spb_cell *cells, size_t cells_capacity,
                            uint8_t *line_attrs, uint8_t *dirty_rows,
                            size_t rows_capacity);

/* Terminal size in character cells, plus the pixel size reported to
 * applications that ask. Resizes the terminal and tells the backend. */
void spb_session_resize(spb_session *session, int32_t cols, int32_t rows,
                        int32_t pixel_width, int32_t pixel_height);

/* Keyboard focus (cursor becomes passive without it). */
void spb_session_set_focus(spb_session *session, bool focused);

/* Modifiers for key, text and mouse input. META is the frontend's
 * resolved Meta key (Option or Command, per OSXOptionMeta and
 * OSXCommandMeta). */
enum {
    SPB_MOD_SHIFT = 1u << 0,
    SPB_MOD_CTRL  = 1u << 1,
    SPB_MOD_META  = 1u << 2,
};

typedef enum spb_key {
    SPB_KEY_UP, SPB_KEY_DOWN, SPB_KEY_RIGHT, SPB_KEY_LEFT, SPB_KEY_BEGIN,
    SPB_KEY_HOME, SPB_KEY_END, SPB_KEY_INSERT, SPB_KEY_DELETE,
    SPB_KEY_PAGE_UP, SPB_KEY_PAGE_DOWN,
    SPB_KEY_RETURN, SPB_KEY_BACKSPACE, SPB_KEY_TAB, SPB_KEY_ESCAPE,
    SPB_KEY_F1,                /* F1 ... F20 are SPB_KEY_F1 + 0 ... 19 */
    SPB_KEY_F20 = SPB_KEY_F1 + 19,
    SPB_KEY_KP_0,              /* keypad 0 ... 9 are SPB_KEY_KP_0 + n */
    SPB_KEY_KP_9 = SPB_KEY_KP_0 + 9,
    SPB_KEY_KP_DECIMAL, SPB_KEY_KP_ENTER, SPB_KEY_KP_PLUS, SPB_KEY_KP_MINUS,
    SPB_KEY_KP_MULTIPLY, SPB_KEY_KP_DIVIDE,
    SPB_KEY_KP_NUM_LOCK,       /* the Mac keypad's Clear key */
} spb_key;

/*
 * A non-text key, translated as GTK PuTTY does (unix/window.c key_event)
 * with PuTTY's own formatters: cursor and keypad modes, function key
 * type, Backspace and Return settings, Shift-PageUp scrollback, and
 * Shift-Insert paste.
 */
void spb_session_key(spb_session *session, spb_key key, uint32_t mods);

/* Typed or input-method text (UTF-8). With SPB_MOD_META it is sent
 * prefixed with Escape, as PuTTY does for Alt. */
void spb_session_text(spb_session *session, const char *utf8, size_t len,
                      uint32_t mods);

/* Input-method composition text (UTF-8), drawn by the terminal at the
 * cursor as GTK PuTTY does; NULL or "" ends the composition. */
void spb_session_set_preedit(spb_session *session, const char *utf8);

/* Paste text (UTF-8): bracketed-paste aware, as term_do_paste. */
void spb_session_paste(spb_session *session, const char *utf8, size_t len);

typedef enum spb_mouse_button {
    SPB_MOUSE_LEFT, SPB_MOUSE_MIDDLE, SPB_MOUSE_RIGHT,
} spb_mouse_button;

typedef enum spb_mouse_action {
    SPB_MOUSE_CLICK, SPB_MOUSE_DOUBLE_CLICK, SPB_MOUSE_TRIPLE_CLICK,
    SPB_MOUSE_DRAG, SPB_MOUSE_RELEASE, SPB_MOUSE_MOVE,
} spb_mouse_action;

/* A mouse event at a cell position (may be outside the terminal while
 * dragging). Buttons are mapped to select/extend/paste as Windows PuTTY
 * does, according to MouseIsXterm. */
void spb_session_mouse(spb_session *session, spb_mouse_button button,
                       spb_mouse_action action, int32_t x, int32_t y,
                       uint32_t mods);

/* Scroll-wheel notches (positive = towards the top). Sent to the
 * application in raw mouse mode (unless Shift is held), otherwise
 * scrolls the scrollback. */
void spb_session_wheel(spb_session *session, int32_t notches, int32_t x,
                       int32_t y, uint32_t mods);

typedef enum spb_scroll_mode {
    SPB_SCROLL_RELATIVE,       /* by `lines` (negative = up) */
    SPB_SCROLL_TO_LINE,        /* first visible line = scroll_start value */
    SPB_SCROLL_TO_BOTTOM,
} spb_scroll_mode;

/* Move the view over the scrollback (scrollbar, keyboard). */
void spb_session_scroll(spb_session *session, spb_scroll_mode mode,
                        int32_t lines);

/* Copy the whole scrollback and screen to the system clipboard (PuTTY's
 * "Copy All to Clipboard"). */
void spb_session_copy_all(spb_session *session);

/* ---------- Diagnostics ---------- */

/* Number of sessions whose memory has not been freed yet: created and
 * either not released, or released with teardown still pending. */
size_t spb_debug_live_sessions(void);

/* File descriptors PuTTY has registered with uxsel (sockets and
 * listeners; the loop's own wake-up pipe is not counted), counted on the
 * core thread after all previously queued work. Waits for the core thread
 * (like spb_core_barrier); 0 if the core is not running. */
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
