/*
 * spb_settings.c - the settings document: a sorted map from PuTTY
 * saved-session keywords to string values, converted to and from Conf
 * through upstream's load_open_settings() / save_open_settings().
 */

#include <pthread.h>
#include <limits.h>
#include <string.h>

#include "spb_internal.h"

/*
 * Every upstream frontend tells settings.c which protocol and port to
 * assume when a saved session does not name one (windows/putty.c,
 * unix/putty.c). Without this, such sessions load as protocol "raw",
 * port 0.
 */
static void init_settings_defaults(void)
{
    settings_set_default_protocol(be_default_protocol);
    const struct BackendVtable *vt =
        backend_vt_from_proto(be_default_protocol);
    settings_set_default_port(vt ? vt->default_port : 0);
}

static pthread_once_t settings_defaults_once = PTHREAD_ONCE_INIT;

struct spb_setting {
    char *key;
    char *value;
};

static int setting_cmp(void *av, void *bv)
{
    const struct spb_setting *a = av, *b = bv;
    return strcmp(a->key, b->key);
}

static int setting_find(void *av, void *bv)
{
    const char *key = av;
    const struct spb_setting *b = bv;
    return strcmp(key, b->key);
}

static void setting_free(struct spb_setting *s)
{
    sfree(s->key);
    sfree(s->value);
    sfree(s);
}

static void clear_entries(spb_settings *settings)
{
    struct spb_setting *s;
    while ((s = delpos234(settings->entries, 0)) != NULL)
        setting_free(s);
}

spb_settings *spb_settings_new_empty(void)
{
    spb_settings *settings = snew(spb_settings);
    settings->entries = newtree234(setting_cmp);
    atomic_fetch_add(&spb_live_settings, 1);
    return settings;
}

spb_settings *spb_settings_new_defaults(void)
{
    spb_settings *settings = spb_settings_new_empty();
    spb_settings_normalise(settings);
    return settings;
}

spb_settings *spb_settings_copy(const spb_settings *src)
{
    spb_settings *dst = spb_settings_new_empty();
    struct spb_setting *s;
    for (int i = 0; (s = index234(src->entries, i)) != NULL; i++)
        spb_settings_set(dst, s->key, s->value);
    return dst;
}

void spb_settings_free(spb_settings *settings)
{
    if (!settings)
        return;
    clear_entries(settings);
    freetree234(settings->entries);
    sfree(settings);
    atomic_fetch_sub(&spb_live_settings, 1);
}

void spb_settings_set(spb_settings *settings,
                      const char *keyword, const char *value)
{
    struct spb_setting *existing =
        find234(settings->entries, (void *)keyword, setting_find);
    if (existing) {
        char *old = existing->value;
        existing->value = dupstr(value);
        sfree(old);
        return;
    }
    struct spb_setting *s = snew(struct spb_setting);
    s->key = dupstr(keyword);
    s->value = dupstr(value);
    add234(settings->entries, s);
}

bool spb_settings_remove(spb_settings *settings, const char *keyword)
{
    struct spb_setting *s =
        find234(settings->entries, (void *)keyword, setting_find);
    if (!s)
        return false;
    del234(settings->entries, s);
    setting_free(s);
    return true;
}

const char *spb_settings_get(const spb_settings *settings,
                             const char *keyword)
{
    struct spb_setting *s =
        find234(settings->entries, (void *)keyword, setting_find);
    return s ? s->value : NULL;
}

size_t spb_settings_count(const spb_settings *settings)
{
    return count234(settings->entries);
}

const char *spb_settings_key_at(const spb_settings *settings, size_t index)
{
    if (index >= (size_t)count234(settings->entries))
        return NULL;
    struct spb_setting *s = index234(settings->entries, (int)index);
    return s->key;
}

const char *spb_settings_value_at(const spb_settings *settings,
                                  size_t index)
{
    if (index >= (size_t)count234(settings->entries))
        return NULL;
    struct spb_setting *s = index234(settings->entries, (int)index);
    return s->value;
}

void spb_settings_load_into_conf(const spb_settings *settings, Conf *conf)
{
    pthread_once(&settings_defaults_once, init_settings_defaults);
    settings_r *reader = spb_settings_reader(settings);
    load_open_settings(reader, conf);
    close_settings_r(reader);
}

void spb_settings_save_from_conf(spb_settings *settings, Conf *conf)
{
    clear_entries(settings);
    settings_w *writer = spb_settings_writer(settings);
    save_open_settings(writer, conf);
    close_settings_w(writer);
}

void spb_settings_prepare_session(spb_settings *settings)
{
    Conf *conf = conf_new();
    spb_settings_load_into_conf(settings, conf);
    prepare_session(conf);
    spb_settings_save_from_conf(settings, conf);
    conf_free(conf);
}

const char *spb_charset_name(size_t index)
{
    return index > INT_MAX ? NULL : cp_enumerate((int)index);
}

/* config.c codepage_handler */
const char *spb_charset_canonical_name(const char *line_codepage)
{
    return cp_name(decode_codepage(line_codepage ? line_codepage : ""));
}

void spb_settings_normalise(spb_settings *settings)
{
    Conf *conf = conf_new();
    spb_settings_load_into_conf(settings, conf);
    spb_settings_save_from_conf(settings, conf);
    conf_free(conf);
}
