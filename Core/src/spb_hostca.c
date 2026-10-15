/*
 * spb_hostca.c - PuTTY's trusted host certification authorities (API
 * v10), for a native "Configure host CAs" window.
 *
 * The records are upstream's: unix/storage.c keeps them in the state
 * directory, and the rules for a record are those of upstream's dialog
 * (ssh/ca-config.c, which SwiftPutty does not link): the public key is a
 * base64 blob or a public key file's text, shown by its fingerprint; it
 * may not be a certificate; a record needs a valid "valid hosts"
 * expression. Every function runs on the core thread and waits for it.
 */

#include <string.h>

#include "spb_internal.h"
#include "ssh.h"

static void run(spb_command_fn fn, void *ctx)
{
    if (!spb_loop_run_sync(fn, ctx))
        modalfatalbox("SwiftPutty internal error: host CA store used "
                      "without the core");
}

static spb_host_ca *from_hca(const host_ca *hca)
{
    spb_host_ca *ca = snew(spb_host_ca);
    ca->name = dupstr(hca->name ? hca->name : "");
    ca->public_key = hca->ca_public_key ?
        strbuf_to_str(base64_encode_sb(ptrlen_from_strbuf(hca->ca_public_key), 0)) :
        dupstr("");
    ca->validity = dupstr(hca->validity_expression ?
                          hca->validity_expression : "");
    ca->permit_rsa_sha1 = hca->opts.permit_rsa_sha1;
    ca->permit_rsa_sha256 = hca->opts.permit_rsa_sha256;
    ca->permit_rsa_sha512 = hca->opts.permit_rsa_sha512;
    return ca;
}

void spb_host_ca_free(spb_host_ca *ca)
{
    if (!ca)
        return;
    sfree(ca->name);
    sfree(ca->public_key);
    sfree(ca->validity);
    sfree(ca);
}

/* ---- Defaults ---- */

static void cmd_new(void *vctx)
{
    spb_host_ca **out = vctx;
    host_ca *hca = host_ca_new();
    *out = from_hca(hca);
    host_ca_free(hca);
}

spb_host_ca *spb_host_ca_new_default(void)
{
    spb_host_ca *ca = NULL;
    run(cmd_new, &ca);
    return ca;
}

/* ---- Names ---- */

typedef struct names_cmd {
    char **names;
    size_t count, size;
} names_cmd;

static void cmd_names(void *vctx)
{
    names_cmd *cmd = vctx;
    host_ca_enum *hce = enum_host_ca_start();
    if (hce) {
        strbuf *name = strbuf_new();
        while (strbuf_clear(name), enum_host_ca_next(hce, name)) {
            sgrowarray(cmd->names, cmd->size, cmd->count);
            cmd->names[cmd->count++] = dupstr(name->s);
        }
        strbuf_free(name);
        enum_host_ca_finish(hce);
    }
}

char **spb_host_ca_names(size_t *count)
{
    names_cmd cmd = { 0 };
    run(cmd_names, &cmd);
    *count = cmd.count;
    return cmd.names;
}

void spb_strings_free(char **strings, size_t count)
{
    for (size_t i = 0; i < count; i++)
        sfree(strings[i]);
    sfree(strings);
}

/* ---- Load and delete ---- */

typedef struct name_cmd {
    const char *name;
    spb_host_ca *ca;
    char *error;
} name_cmd;

static void cmd_load(void *vctx)
{
    name_cmd *cmd = vctx;
    host_ca *hca = host_ca_load(cmd->name);
    if (hca) {
        cmd->ca = from_hca(hca);
        host_ca_free(hca);
    }
}

spb_host_ca *spb_host_ca_load(const char *name)
{
    name_cmd cmd = { .name = name };
    run(cmd_load, &cmd);
    return cmd.ca;
}

static void cmd_delete(void *vctx)
{
    name_cmd *cmd = vctx;
    cmd->error = host_ca_delete(cmd->name);
}

char *spb_host_ca_delete(const char *name)
{
    name_cmd cmd = { .name = name };
    run(cmd_delete, &cmd);
    return cmd.error;
}

/* ---- The public key (ca-config.c ca_refresh_pubkey_info) ---- */

typedef struct key_cmd {
    const char *text;
    char *info;                        /* fingerprint, or why not */
    strbuf *blob;                      /* the key, if valid */
} key_cmd;

static void cmd_key(void *vctx)
{
    key_cmd *cmd = vctx;
    ssh_key *key = NULL;
    strbuf *blob = strbuf_new();
    ptrlen data = ptrlen_from_asciz(cmd->text);

    if (!data.len) {
        cmd->info = dupstr("");
        goto out;
    }
    if (base64_valid(data)) {
        base64_decode_bs(BinarySink_UPCAST(blob), data);
    } else {
        BinarySource src[1];
        BinarySource_BARE_INIT_PL(src, data);
        const char *error;
        if (!ppk_loadpub_s(src, NULL, BinarySink_UPCAST(blob), NULL, &error)) {
            cmd->info = dupprintf("Cannot decode key: %s", error);
            goto out;
        }
    }

    ptrlen alg_name = pubkey_blob_to_alg_name(ptrlen_from_strbuf(blob));
    if (!alg_name.len) {
        cmd->info = dupstr("Invalid key (no key type)");
        goto out;
    }
    const ssh_keyalg *alg = find_pubkey_alg_len(alg_name);
    if (!alg) {
        cmd->info = dupprintf("Unrecognised key type '%.*s'",
                              PTRLEN_PRINTF(alg_name));
        goto out;
    }
    if (alg->is_certificate) {
        cmd->info = dupprintf("CA key may not be a certificate (type is '%.*s')",
                              PTRLEN_PRINTF(alg_name));
        goto out;
    }
    key = ssh_key_new_pub(alg, ptrlen_from_strbuf(blob));
    if (!key) {
        cmd->info = dupprintf("Invalid '%.*s' key data", PTRLEN_PRINTF(alg_name));
        goto out;
    }
    cmd->info = ssh2_fingerprint(key, SSH_FPTYPE_DEFAULT);
    cmd->blob = blob;
    blob = NULL;

  out:
    if (key)
        ssh_key_free(key);
    if (blob)
        strbuf_free(blob);
}

char *spb_host_ca_key_info(const char *text, char **public_key_out)
{
    key_cmd cmd = { .text = text ? text : "" };
    run(cmd_key, &cmd);
    if (public_key_out)
        *public_key_out = cmd.blob ?
            strbuf_to_str(base64_encode_sb(ptrlen_from_strbuf(cmd.blob), 0)) :
            NULL;
    if (cmd.blob)
        strbuf_free(cmd.blob);
    return cmd.info;
}

/* ---- Save (ca-config.c ca_save_handler) ---- */

typedef struct save_cmd {
    const spb_host_ca *ca;
    char *error;
    size_t error_offset, error_length;
} save_cmd;

static void cmd_save(void *vctx)
{
    save_cmd *cmd = vctx;
    const spb_host_ca *ca = cmd->ca;

    if (!ca->validity || !*ca->validity) {
        cmd->error = dupstr("No validity expression configured for this key");
        return;
    }
    char *error_msg;
    ptrlen error_loc;
    if (!cert_expr_valid(ca->validity, &error_msg, &error_loc)) {
        cmd->error = dupprintf("Error in expression: %s", error_msg);
        cmd->error_offset = (const char *)error_loc.ptr - ca->validity;
        cmd->error_length = error_loc.len;
        sfree(error_msg);
        return;
    }

    key_cmd key = { .text = ca->public_key ? ca->public_key : "" };
    cmd_key(&key);
    sfree(key.info);
    if (!key.blob) {
        cmd->error = dupstr("No valid CA public key entered");
        return;
    }

    host_ca *hca = host_ca_new();
    hca->name = dupstr(ca->name ? ca->name : "");
    hca->ca_public_key = key.blob;
    hca->validity_expression = dupstr(ca->validity);
    hca->opts.permit_rsa_sha1 = ca->permit_rsa_sha1;
    hca->opts.permit_rsa_sha256 = ca->permit_rsa_sha256;
    hca->opts.permit_rsa_sha512 = ca->permit_rsa_sha512;
    cmd->error = host_ca_save(hca);
    host_ca_free(hca);
}

char *spb_host_ca_save(const spb_host_ca *ca, size_t *error_offset,
                       size_t *error_length)
{
    save_cmd cmd = { .ca = ca, .error_offset = SIZE_MAX, .error_length = 0 };
    run(cmd_save, &cmd);
    if (error_offset)
        *error_offset = cmd.error_offset;
    if (error_length)
        *error_length = cmd.error_length;
    return cmd.error;
}
