/*
 * C-level tests for the SwiftPutty bridge (M01: library info, core
 * lifecycle, settings conversion, session object lifecycle). The core
 * thread and connected sessions are covered by spb_session_test.c.
 *
 * Uses only the public PuTTYBridge.h API. Exit status 0 on success.
 * Run under `leaks --atExit` and an AddressSanitizer build by
 * scripts/build-core.sh.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
        if (!a_ || strcmp(a_, e_)) {                                    \
            fprintf(stderr, "%s:%d: expected %s == \"%s\", got %s%s%s\n", \
                    __FILE__, __LINE__, #actual, e_,                    \
                    a_ ? "\"" : "", a_ ? a_ : "NULL", a_ ? "\"" : "");  \
            failures++;                                                 \
        }                                                               \
    } while (0)

static void test_library_info(void)
{
    CHECK(spb_api_version() == SPB_API_VERSION);
    CHECK_STR(spb_putty_version(), "Release 0.85");
    CHECK_STR(spb_putty_ssh_version(), "-Release-0.85");
    CHECK(strstr(spb_putty_licence_text(),
                 "PuTTY is copyright 1997-2026 Simon Tatham.") ==
          spb_putty_licence_text());
    CHECK(strstr(spb_putty_licence_text(),
                 "THE SOFTWARE IS PROVIDED \"AS IS\"") != NULL);
    CHECK(strstr(spb_putty_copyright(), "Simon Tatham") != NULL);
}

static void test_session_requires_core(void)
{
    spb_settings *defaults = spb_settings_new_defaults();
    char *err = NULL;
    spb_session *session = spb_session_create(defaults, NULL, NULL, &err);
    CHECK(session == NULL);
    CHECK(err != NULL && strstr(err, "not initialised") != NULL);
    spb_string_free(err);
    spb_settings_free(defaults);
}

static void test_core_init(const char *state_dir)
{
    char *err = NULL;
    CHECK(!spb_core_is_initialised());

    spb_core_options relative = { .state_dir = "relative/path" };
    CHECK(!spb_core_init(&relative, &err));
    CHECK(err != NULL);
    spb_string_free(err);
    err = NULL;

    spb_core_options opts = { .state_dir = state_dir };
    CHECK(spb_core_init(&opts, &err));
    CHECK(err == NULL);
    CHECK(spb_core_is_initialised());
    CHECK(access(state_dir, R_OK | W_OK | X_OK) == 0);

    /* Idempotent with the same directory... */
    CHECK(spb_core_init(&opts, &err));
    CHECK(err == NULL);

    /* ...but not with a different one. */
    spb_core_options other = { .state_dir = "/tmp/spb-other-state-dir" };
    CHECK(!spb_core_init(&other, &err));
    CHECK(err != NULL && strstr(err, "already initialised") != NULL);
    spb_string_free(err);
}

static void test_defaults(void)
{
    spb_settings *s = spb_settings_new_defaults();

    /* conf.h defaults, as upstream saves them */
    CHECK_STR(spb_settings_get(s, "HostName"), "");
    CHECK_STR(spb_settings_get(s, "Protocol"), "ssh");
    CHECK_STR(spb_settings_get(s, "PortNumber"), "22");
    CHECK_STR(spb_settings_get(s, "TerminalType"), "xterm");
    CHECK_STR(spb_settings_get(s, "PortForwardings"), "");
    CHECK_STR(spb_settings_get(s, "LocalPortAcceptAll"), "0");
    CHECK_STR(spb_settings_get(s, "RemotePortAcceptAll"), "0");
    CHECK_STR(spb_settings_get(s, "ScrollbackLines"), "2000");
    /* platform defaults from spb_platform.c */
    CHECK_STR(spb_settings_get(s, "FontName"), "Menlo-Regular 12");
    CHECK_STR(spb_settings_get(s, "LogFileName"), "putty.log");
    CHECK(spb_settings_get(s, "NoSuchKeyword") == NULL);

    /* Iteration is sorted and complete. */
    size_t n = spb_settings_count(s);
    CHECK(n > 150);
    for (size_t i = 1; i < n; i++)
        CHECK(strcmp(spb_settings_key_at(s, i - 1),
                     spb_settings_key_at(s, i)) < 0);
    CHECK(spb_settings_key_at(s, n) == NULL);
    CHECK(spb_settings_value_at(s, n) == NULL);

    spb_settings_free(s);
}

static void test_normalise(void)
{
    /* Upstream reads PortNumber only when Protocol names a backend
     * (settings.c load_open_settings), falling back to the default
     * protocol's port otherwise. */
    spb_settings *noproto = spb_settings_new_empty();
    spb_settings_set(noproto, "PortNumber", "2222");
    spb_settings_normalise(noproto);
    CHECK_STR(spb_settings_get(noproto, "Protocol"), "ssh");
    CHECK_STR(spb_settings_get(noproto, "PortNumber"), "22");
    spb_settings_free(noproto);

    spb_settings *s = spb_settings_new_empty();
    spb_settings_set(s, "HostName", "example.invalid");
    spb_settings_set(s, "Protocol", "ssh");
    spb_settings_set(s, "PortNumber", "2222");
    spb_settings_set(s, "UserName", "alice");
    spb_settings_set(s, "PortForwardings",
                     "L5432=10.0.0.15:5432,R8080=localhost:80,L1080=D");
    spb_settings_set(s, "NoSuchKeyword", "dropped");
    spb_settings_normalise(s);

    CHECK_STR(spb_settings_get(s, "HostName"), "example.invalid");
    CHECK_STR(spb_settings_get(s, "PortNumber"), "2222");
    CHECK_STR(spb_settings_get(s, "UserName"), "alice");
    /* Upstream re-serialises forwardings in Conf (sorted subkey) order
     * and writes dynamic ones in its legacy storage form "D<port>="
     * (settings.c wmap()). */
    CHECK_STR(spb_settings_get(s, "PortForwardings"),
              "D1080=,L5432=10.0.0.15:5432,R8080=localhost:80");
    CHECK(spb_settings_get(s, "NoSuchKeyword") == NULL);

    /* Normalisation is idempotent. */
    spb_settings *again = spb_settings_copy(s);
    spb_settings_normalise(again);
    CHECK(spb_settings_count(again) == spb_settings_count(s));
    for (size_t i = 0; i < spb_settings_count(s); i++) {
        CHECK_STR(spb_settings_key_at(again, i), spb_settings_key_at(s, i));
        CHECK_STR(spb_settings_value_at(again, i),
                  spb_settings_value_at(s, i));
    }
    spb_settings_free(again);

    /* Map editing */
    CHECK(spb_settings_remove(s, "UserName"));
    CHECK(!spb_settings_remove(s, "UserName"));
    CHECK(spb_settings_get(s, "UserName") == NULL);
    spb_settings_set(s, "HostName", "other.invalid");
    CHECK_STR(spb_settings_get(s, "HostName"), "other.invalid");

    spb_settings_free(s);
}

/* PuTTY's character set list (M06). */
static void test_charsets(void)
{
    size_t n = 0;
    bool utf8 = false, latin1 = false;
    for (const char *name; (name = spb_charset_name(n)) != NULL; n++) {
        if (!strcmp(name, "UTF-8"))
            utf8 = true;
        if (!strcmp(name, "ISO-8859-1"))
            latin1 = true;
    }
    CHECK(n > 20);
    CHECK(utf8 && latin1);
    CHECK(spb_charset_name(100000) == NULL);
    /* As config.c's codepage_handler shows them. */
    CHECK(!strcmp(spb_charset_canonical_name(""), "UTF-8"));
    CHECK(!strcmp(spb_charset_canonical_name("ISO-8859-1"), "ISO-8859-1"));
    CHECK(!strcmp(spb_charset_canonical_name("CP1252"), "CP1252"));
    /* An unknown name falls back to the font's encoding, as on Unix. */
    CHECK(!strcmp(spb_charset_canonical_name("no such charset"),
                  "Use font encoding"));
}

/* Risk R-3: Change Settings loses nothing (M07). */
static void test_reconfigure_roundtrip(void)
{
    size_t keys = 0;
    char *err = NULL;
    bool ok = spb_debug_check_reconfigure_roundtrip(&keys, &err);
    if (!ok)
        fprintf(stderr, "round trip: %s\n", err ? err : "?");
    CHECK(ok);
    CHECK(keys > 200);
    spb_string_free(err);
    CHECK(spb_debug_live_settings() == 0);
}

static void test_session_lifecycle(void)
{
    spb_settings *s = spb_settings_new_defaults();
    spb_settings_set(s, "HostName", "host.invalid");
    spb_settings_set(s, "PortForwardings", "4L127.0.0.1:8080=web:80");

    uint64_t last_id = 0;
    for (int i = 0; i < 20000; i++) {
        char *err = NULL;
        spb_session *session = spb_session_create(s, NULL, NULL, &err);
        CHECK(session != NULL);
        CHECK(err == NULL);
        if (!session)
            break;
        uint64_t id = spb_session_id(session);
        CHECK(id > last_id);
        last_id = id;
        if (i % 1000 == 0) {
            spb_settings *copy = spb_session_copy_settings(session);
            CHECK_STR(spb_settings_get(copy, "HostName"), "host.invalid");
            CHECK_STR(spb_settings_get(copy, "PortForwardings"),
                      "4L127.0.0.1:8080=web:80");
            spb_settings_free(copy);
        }
        spb_session_release(session);
    }
    /* Release is asynchronous: teardown runs on the core thread. */
    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);

    /* Many sessions alive at once, released in a different order. */
    enum { N = 256 };
    spb_session *sessions[N];
    for (int i = 0; i < N; i++)
        sessions[i] = spb_session_create(s, NULL, NULL, NULL);
    CHECK(spb_debug_live_sessions() == N);
    for (int i = 0; i < N; i += 2)
        spb_session_release(sessions[i]);
    for (int i = N - 1; i > 0; i -= 2)
        spb_session_release(sessions[i]);
    CHECK(spb_core_barrier());
    CHECK(spb_debug_live_sessions() == 0);

    spb_session_release(NULL);
    spb_settings_free(s);
    spb_settings_free(NULL);
}

static void test_shutdown(void)
{
    spb_settings *s = spb_settings_new_defaults();
    spb_session *session = spb_session_create(s, NULL, NULL, NULL);
    CHECK(!spb_core_shutdown());       /* refused: live session */
    CHECK(spb_core_is_initialised());
    spb_session_release(session);
    spb_settings_free(s);

    CHECK(spb_core_shutdown());
    CHECK(!spb_core_is_initialised());
    CHECK(spb_core_shutdown());        /* idempotent */

    char *err = NULL;
    spb_core_options opts = { .state_dir = "/tmp" };
    CHECK(!spb_core_init(&opts, &err)); /* shutdown is final */
    CHECK(err != NULL);
    spb_string_free(err);
}

int main(void)
{
    char template[] = "/tmp/spb-bridge-test-XXXXXX";
    char *base = mkdtemp(template);
    if (!base) {
        perror("mkdtemp");
        return 2;
    }
    char state_dir[512];
    snprintf(state_dir, sizeof(state_dir), "%s/state", base);

    test_library_info();
    test_session_requires_core();
    test_core_init(state_dir);
    test_defaults();
    test_normalise();
    test_charsets();
    test_reconfigure_roundtrip();
    test_session_lifecycle();
    CHECK(spb_debug_live_settings() == 0);
    test_shutdown();
    CHECK(spb_debug_live_settings() == 0);

    rmdir(state_dir);
    rmdir(base);

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("spb_bridge_test: all checks passed\n");
    return 0;
}
