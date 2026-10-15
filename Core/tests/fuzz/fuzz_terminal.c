/*
 * fuzz_terminal.c - what a server sends, through the whole terminal path
 * (D-042): one Raw session whose server end the harness holds. Each
 * input is sent as the server's output, followed by a reset and a
 * marker; once the marker is on screen every byte before it has been
 * through PuTTY's terminal and the bridge. The frame is then read and
 * the whole screen copied with "Copy as RTF" on, so the bridge's frame,
 * colour and styled-copy code all see the result.
 *
 * Input: if the first byte is 0, the next two choose a terminal size
 * (resize before the data); the rest is sent as is.
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "PuTTYBridge.h"

const char *const spb_fuzz_dictionary[] = {
    "\x1b[", "\x1b]", "\x1bP", "\x1b\\", "\x07", "\x9b", "\x9d", "\x90",
    ";", "?", ">", "m", "H", "J", "K", "h", "l", "r", "t", "n", "c", "@",
    "P", "L", "M", "X", "S", "T", "1;31m", "38;5;", "48;2;", "0m", "?1049h",
    "?47h", "?1000h", "?1006h", "?2004h", "?3h", "?5h", "?6h", "?7l",
    "\x1b(0", "\x1b(B", "\x1b)0", "\x0e", "\x0f", "\x1b#8", "\x1b#6",
    "\x1b#3", "\x1b%G", "\x1b%@", "\x1b[?2l", "\x1b<", "\x1bY",
    "\x1b" "7", "\x1b" "8", "\x1b" "D", "\x1bM", "\x1b" "E", "\x1b" "c", "\r\n",
    "\x08", "\t", "\xe2\x94\x80", "\xe4\xb8\xad", "\xcc\x81",
    "\xf0\x9f\x98\x80", "\xc0\x80", "\xff", "4294967295",
    "99999", "65535", "0;0", "\x1b[5i", "\x1b[4i", "\x1b]4;", "\x1b]52;",
    NULL,
};

static spb_session *session;
static int peer = -1;
static spb_frame_info info;
static spb_cell *cells;
static uint8_t *lattrs, *dirty;
static size_t cells_cap, rows_cap;
static unsigned long marker_count;
static char state_dir[600];

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static bool connected;

static void cb_state(void *ctx, spb_session_state st, const char *detail)
{
    pthread_mutex_lock(&lock);
    if (st == SPB_SESSION_CONNECTED)
        connected = true;
    pthread_mutex_unlock(&lock);
}

/* The styled copy's runs must be readable in full. */
static volatile uint32_t sink;
static void cb_styled(void *ctx, spb_clipboard which,
                      const spb_style_run *runs, size_t n)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < n; i++)
        for (size_t j = 0; j < runs[i].text_len; j++)
            sum += (uint8_t)runs[i].text[j] + runs[i].fg + runs[i].bg;
    sink = sum;
}

static void cb_clip(void *ctx, spb_clipboard which, const char *text,
                    size_t len)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i++)
        sum += (uint8_t)text[i];
    sink = sum;
}

static const spb_session_callbacks callbacks = {
    .state_changed = cb_state,
    .clipboard_write = cb_clip,
    .clipboard_write_styled = cb_styled,
};

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

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

static bool row0_is(const char *text)
{
    size_t n = strlen(text);
    if (info.rows < 1 || (size_t)info.cols < n)
        return false;
    for (size_t i = 0; i < n; i++)
        if (cells[i].chars[0] != (uint32_t)(unsigned char)text[i])
            return false;
    return true;
}

static void send_all(const void *data, size_t len)
{
    const uint8_t *p = data;
    while (len) {
        ssize_t n = write(peer, p, len);
        if (n <= 0) {
            fprintf(stderr, "fuzz_terminal: the session went away\n");
            abort();
        }
        p += n;
        len -= (size_t)n;
        /* Drain what the terminal answered (device attributes, etc.). */
        char junk[4096];
        while (recv(peer, junk, sizeof(junk), MSG_DONTWAIT) > 0)
            ;
    }
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    char template[] = "/tmp/spb-fuzz-terminal-XXXXXX";
    char *base = mkdtemp(template);
    if (!base)
        abort();
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);
    spb_core_options opts = { .state_dir = state_dir };
    char *err = NULL;
    if (!spb_core_init(&opts, &err)) {
        fprintf(stderr, "init: %s\n", err);
        abort();
    }

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t len = sizeof(addr);
    if (bind(listener, (struct sockaddr *)&addr, len) < 0 ||
        listen(listener, 1) < 0 ||
        getsockname(listener, (struct sockaddr *)&addr, &len) < 0)
        abort();
    char port[16];
    snprintf(port, sizeof(port), "%d", ntohs(addr.sin_port));

    spb_settings *s = spb_settings_new_defaults();
    spb_settings_set(s, "Protocol", "raw");
    spb_settings_set(s, "HostName", "127.0.0.1");
    spb_settings_set(s, "PortNumber", port);
    spb_settings_set(s, "LocalEcho", "1");      /* force off */
    spb_settings_set(s, "LocalEdit", "1");
    spb_settings_set(s, "PasteRTF", "1");
    spb_settings_set(s, "ScrollbackLines", "200");
    session = spb_session_create(s, &callbacks, NULL, &err);
    spb_settings_free(s);
    if (!session)
        abort();
    spb_session_set_focus(session, true);
    spb_session_start(session);
    peer = accept(listener, NULL, NULL);
    close(listener);
    double deadline = now() + 10;
    for (;;) {
        pthread_mutex_lock(&lock);
        bool ok = connected;
        pthread_mutex_unlock(&lock);
        if (ok)
            break;
        if (now() > deadline)
            abort();
        usleep(1000);
    }
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size >= 3 && data[0] == 0) {
        spb_session_resize(session, 1 + data[1] % 160, 1 + data[2] % 60,
                           0, 0);
        data += 3;
        size -= 3;
    }
    send_all(data, size);

    /* Back to 80x24 before the marker, so that it fits on one row. */
    spb_session_resize(session, 80, 24, 0, 0);
    spb_core_barrier();

    /* CAN ends any sequence; ESC < leaves VT52 mode; ST ends a string;
     * ESC [4i ends printing; RIS resets the rest. Then the marker. */
    char marker[64], sync[96];
    snprintf(marker, sizeof(marker), "fuzzsync%lu", ++marker_count);
    int n = snprintf(sync, sizeof(sync),
                     "\x18\x1b<\x1b\\\x1b[4i\x1b" "c%s", marker);
    send_all(sync, (size_t)n);

    double deadline = now() + 30;
    for (;;) {
        read_frame();
        if (row0_is(marker))
            break;
        if (now() > deadline) {
            fprintf(stderr, "fuzz_terminal: the terminal stopped "
                    "processing input\n");
            abort();
        }
        usleep(200);
    }
    spb_session_copy_all(session);
    return 0;
}
