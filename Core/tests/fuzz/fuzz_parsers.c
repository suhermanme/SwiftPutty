/*
 * fuzz_parsers.c - text the user pastes or saved settings hold (D-042):
 * manually configured host keys, host CA public keys and "valid hosts"
 * expressions, and every saved-session keyword through upstream's
 * load_open_settings (session creation) and save_open_settings
 * (normalisation).
 *
 * Input: the first byte chooses the target, the rest is its text:
 *   0  spb_canonical_manual_host_key
 *   1  spb_host_ca_key_info
 *   2  spb_host_ca_save with a valid key and the text as the expression
 *   3  settings: records of [keyword index byte][value bytes][NUL],
 *      applied over the defaults, normalised, and used to create (and
 *      release) a session
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "PuTTYBridge.h"

const char *const spb_fuzz_dictionary[] = {
    "ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-nistp256 ", "ssh-dss ",
    "ssh-ed25519-cert-v01@openssh.com ", "AAAAC3NzaC1lZDI1NTE5AAAAI",
    "AAAAB3NzaC1yc2EAAAADAQAB", "SHA256:", "MD5:", "=", "==", ":", "@",
    "@cert-authority ", "---- BEGIN SSH2 PUBLIC KEY ----\n",
    "---- END SSH2 PUBLIC KEY ----\n", "Comment: \"", "\\\n",
    "*.example.com", " || ", " && ", "!", "(", ")", "port:22", "port:1-65535",
    "\x00", "\x01", "\x02", "\x03",
    "L8080\tlocalhost:80", "R2222\thost:22", "D1080", ",", "\t", "%",
    "255,255,255", "0,0,0", "TERM=", "\\", "4R", "6L", "[::1]:",
    NULL,
};

static const char ca_key[] =
    "AAAAC3NzaC1lZDI1NTE5AAAAICClyXAUffn4w6RDfFZckjnkQ9HHOgVUQXPaMz+Xque/";

/* Keywords settings.c reads that are not saved any more (older
 * formats it converts), so a hand-edited file can still hold them. */
static const char *const legacy_keywords[] = {
    "AuthGSSAPI", "AuthGSSAPIKEX", "BugDHGEx2", "BuggyMAC", "GssapiRekey",
    "KEX", "NoRemoteQTitle", "OSXCommandMeta", "OSXOptionMeta",
    "PingInterval", "ProxySOCKSVersion", "ProxyType", "BellOverloadS",
    "BellOverloadT", NULL,
};

static char **keywords;
static size_t n_keywords;
static char state_dir[600];

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    char template[] = "/tmp/spb-fuzz-parsers-XXXXXX";
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
    spb_settings *d = spb_settings_new_defaults();
    size_t n_defaults = spb_settings_count(d);
    keywords = malloc((n_defaults + 32) * sizeof(char *));
    for (size_t i = 0; i < n_defaults; i++)
        keywords[n_keywords++] = strdup(spb_settings_key_at(d, i));
    for (const char *const *k = legacy_keywords; *k; k++)
        if (!spb_settings_get(d, *k))
            keywords[n_keywords++] = strdup(*k);
    spb_settings_free(d);
    if (n_keywords > 256) {
        fprintf(stderr, "fuzz_parsers: more than 256 keywords\n");
        abort();
    }
    return 0;
}

static void settings_target(const uint8_t *data, size_t size)
{
    spb_settings *s = spb_settings_new_defaults();
    spb_settings_set(s, "Protocol", "raw");      /* never connects */
    char value[1024];
    size_t i = 0;
    while (i < size) {
        size_t k = data[i++] % n_keywords;
        size_t n = 0;
        while (i < size && data[i] && n < sizeof(value) - 1)
            value[n++] = (char)data[i++];
        value[n] = 0;
        i++;                                      /* the NUL */
        if (!strcmp(keywords[k], "Protocol") || !strcmp(keywords[k], "HostName"))
            continue;                             /* stay offline */
        spb_settings_set(s, keywords[k], value);
    }
    spb_settings *copy = spb_settings_copy(s);
    spb_settings_normalise(copy);
    spb_settings_free(copy);

    char *err = NULL;
    spb_session *session = spb_session_create(s, NULL, NULL, &err);
    if (session)
        spb_session_release(session);
    else
        spb_string_free(err);
    spb_settings_free(s);
    /* Let the core finish with the session, so that anything going
     * wrong there is blamed on this input. */
    spb_core_barrier();
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 1)
        return 0;
    uint8_t which = data[0] % 4;
    data++;
    size--;

    if (which == 3) {
        settings_target(data, size);
        return 0;
    }

    char *text = malloc(size + 1);
    memcpy(text, data, size);
    text[size] = 0;                     /* text APIs stop at the first NUL */

    switch (which) {
      case 0:
        spb_string_free(spb_canonical_manual_host_key(text));
        break;
      case 1: {
        char *blob = NULL;
        spb_string_free(spb_host_ca_key_info(text, &blob));
        spb_string_free(blob);
        break;
      }
      case 2: {
        spb_host_ca *ca = spb_host_ca_new_default();
        spb_string_free(ca->name);
        ca->name = strdup("fuzz");
        spb_string_free(ca->public_key);
        ca->public_key = strdup(ca_key);
        spb_string_free(ca->validity);
        ca->validity = text;
        text = NULL;
        size_t offset = 0, length = 0;
        spb_string_free(spb_host_ca_save(ca, &offset, &length));
        spb_host_ca_free(ca);
        break;
      }
    }
    free(text);
    return 0;
}
