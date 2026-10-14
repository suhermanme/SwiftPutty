/*
 * spb_platform.c - functions and constants that PuTTY expects each
 * frontend application to define.
 *
 * Defaults follow Windows PuTTY (windows/utils/defaults.c), the project's
 * behavioural reference, translated to macOS equivalents where the
 * Windows value cannot apply.
 */

#include <os/log.h>
#include <stdarg.h>
#include <stdlib.h>

#include "spb_internal.h"

/* Build information: not a GTK program (as upstream's non-GTK tools). */
const bool buildinfo_gtk_relevant = false;

/* Connection sharing is available in both directions, as in GUI PuTTY. */
const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;

static os_log_t core_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("org.swiftputty.SwiftPutty", "core");
    });
    return log;
}

/* The default terminal font: Menlo is the macOS system monospaced font
 * family available on every supported release (Windows: Courier New 10). */
#define SPB_DEFAULT_FONT "Menlo-Regular 12"

FontSpec *platform_default_fontspec(const char *name)
{
    if (!strcmp(name, "Font"))
        return fontspec_new(SPB_DEFAULT_FONT);
    return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    return filename_from_str("");
}

char *platform_default_s(const char *name)
{
    /* Windows defaults SerialLine to "COM1"; macOS has no fixed first
     * serial device, so leave conf.h's empty default in place. */
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    return def;
}

int platform_default_i(const char *name, int def)
{
    return def;
}

/*
 * Upstream unix/storage.c falls back to X resources for settings missing
 * from a session file. SwiftPutty has no X resources.
 */
char *x_get_default(const char *key)
{
    return NULL;
}

/* X11 forwarding's local display: as GUI PuTTY's fallback, $DISPLAY
 * (set by XQuartz when it is installed). */
char *platform_get_x_display(void)
{
    return dupstr(getenv("DISPLAY"));
}

/*
 * Process-level error reporting, used by PuTTY code that has no Seat to
 * report through. Session-level errors arrive through the Seat instead
 * (M02 onwards). These go to the unified log for now; surfacing them in
 * the UI is part of the event log work (M10).
 */
void nonfatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    os_log_error(core_log(), "%{public}s", msg);
    sfree(msg);
}

/*
 * Unrecoverable internal error. Upstream frontends print and exit(1);
 * SwiftPutty logs and aborts so that the condition produces a crash report
 * containing the message instead of a silent exit.
 */
void modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap);
    va_end(ap);
    os_log_fault(core_log(), "PuTTY fatal error: %{public}s", msg);
    fprintf(stderr, "FATAL ERROR: %s\n", msg);
    abort();
}

/* Text matches upstream unix/console.c. */
void old_keyfile_warning(void)
{
    os_log(core_log(),
           "You are loading an SSH-2 private key which has an old version "
           "of the file format. This means your key file is not fully "
           "tamperproof. Future versions of PuTTY may stop supporting this "
           "private key format, so we recommend you convert your key to "
           "the new format.");
}
