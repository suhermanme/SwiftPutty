/*
 * spb_storage.c - the saved-session half of PuTTY's storage.h API.
 *
 * SwiftPutty keeps named sessions in its own versioned store on the Swift
 * side (docs/DECISIONS.md D-004), so the C core never writes one, and
 * reads one by name only through the frontend's lookup (API v10; PuTTY
 * does that for SSH proxies). Otherwise the bridge hands PuTTY's
 * load_open_settings() and save_open_settings() handles that read and
 * write an spb_settings keyword map. Values are encoded exactly as upstream's Unix session
 * files encode them (unix/storage.c), so a map is interchangeable with a
 * PuTTY ~/.putty/sessions file.
 *
 * The host-key, host-CA and random-seed halves of storage.h are upstream's
 * unix/storage.c, compiled unmodified with its session functions renamed
 * out of the way (Core/cmake/SwiftPuttyCore.cmake).
 */

#include <stdlib.h>

#include "spb_internal.h"

struct settings_r {
    const spb_settings *settings;
    spb_settings *owned;               /* freed on close (named sessions) */
};

static _Atomic(spb_saved_session_lookup) lookup_fn;
static _Atomic(void *) lookup_ctx;

void spb_core_set_saved_session_lookup(spb_saved_session_lookup lookup,
                                       void *ctx)
{
    atomic_store(&lookup_ctx, ctx);
    atomic_store(&lookup_fn, lookup);
}

struct settings_w {
    spb_settings *settings;
};

struct settings_e {
    int unused;
};

settings_r *spb_settings_reader(const spb_settings *settings)
{
    settings_r *handle = snew(settings_r);
    handle->settings = settings;
    handle->owned = NULL;
    return handle;
}

settings_w *spb_settings_writer(spb_settings *settings)
{
    settings_w *handle = snew(settings_w);
    handle->settings = settings;
    return handle;
}

/* ---- Named sessions: owned by the Swift side, never by the core ---- */

settings_w *open_settings_w(const char *sessionname, char **errmsg)
{
    *errmsg = dupstr("Saved sessions are managed by SwiftPutty, "
                     "not by the PuTTY core");
    return NULL;
}

/* PuTTY's NULL or empty name means "Default Settings" (unix/storage.c). */
settings_r *open_settings_r(const char *sessionname)
{
    spb_saved_session_lookup lookup = atomic_load(&lookup_fn);
    if (!lookup)
        return NULL;                   /* behaves as "no such session" */
    spb_settings *found = lookup(atomic_load(&lookup_ctx),
                                 sessionname && *sessionname ?
                                 sessionname : "Default Settings");
    if (!found)
        return NULL;
    settings_r *handle = spb_settings_reader(found);
    handle->owned = found;
    return handle;
}

void del_settings(const char *sessionname)
{
}

settings_e *enum_settings_start(void)
{
    settings_e *handle = snew(settings_e);
    handle->unused = 0;
    return handle;
}

bool enum_settings_next(settings_e *handle, strbuf *out)
{
    return false;
}

void enum_settings_finish(settings_e *handle)
{
    sfree(handle);
}

/* ---- Writing ---- */

void write_setting_s(settings_w *handle, const char *key, const char *value)
{
    spb_settings_set(handle->settings, key, value);
}

void write_setting_i(settings_w *handle, const char *key, int value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", value);
    spb_settings_set(handle->settings, key, buf);
}

void write_setting_filename(settings_w *handle, const char *key,
                            Filename *value)
{
    write_setting_s(handle, key, value->path);
}

void write_setting_fontspec(settings_w *handle, const char *key,
                            FontSpec *font)
{
    /* As upstream Unix: always written under the suffixed key. */
    char *suffixed = dupcat(key, "Name");
    write_setting_s(handle, suffixed, font->name);
    sfree(suffixed);
}

void close_settings_w(settings_w *handle)
{
    sfree(handle);
}

/* ---- Reading ---- */

char *read_setting_s(settings_r *handle, const char *key)
{
    if (!handle)
        return NULL;
    const char *value = spb_settings_get(handle->settings, key);
    return value ? dupstr(value) : NULL;
}

int read_setting_i(settings_r *handle, const char *key, int defvalue)
{
    if (!handle)
        return defvalue;
    const char *value = spb_settings_get(handle->settings, key);
    return value ? atoi(value) : defvalue;
}

Filename *read_setting_filename(settings_r *handle, const char *key)
{
    char *value = read_setting_s(handle, key);
    if (!value)
        return NULL;
    Filename *ret = filename_from_str(value);
    sfree(value);
    return ret;
}

FontSpec *read_setting_fontspec(settings_r *handle, const char *key)
{
    /*
     * As upstream Unix: prefer the suffixed key ("FontName"); fall back
     * to an old-style bare key ("Font"), which denoted a server-side X
     * font.
     */
    char *suffixed = dupcat(key, "Name");
    char *value = read_setting_s(handle, suffixed);
    sfree(suffixed);
    if (value) {
        FontSpec *fs = fontspec_new(value);
        sfree(value);
        return fs;
    }

    value = read_setting_s(handle, key);
    if (value && *value) {
        char *prefixed = dupcat("server:", value);
        FontSpec *fs = fontspec_new(prefixed);
        sfree(prefixed);
        sfree(value);
        return fs;
    }
    sfree(value);
    return NULL;
}

void close_settings_r(settings_r *handle)
{
    if (handle)
        spb_settings_free(handle->owned);
    sfree(handle);                     /* sfree(NULL) is a no-op */
}
