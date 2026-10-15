/*
 * spb_gss.c - which GSSAPI libraries upstream's loader finds (D-043).
 *
 * A diagnostic for tests: a full GSSAPI login needs a Kerberos realm and
 * a server keytab, which a test cannot set up, but whether unix/gss.c
 * (patch 0021) loads macOS's libraries with every function bound can be
 * checked directly.
 */

#include "spb_internal.h"

#ifndef NO_GSSAPI
#include "ssh/pgssapi.h"
#include "ssh/gss.h"
#endif

typedef struct gss_query {
    char **names;
    size_t count;
} gss_query;

static void gss_query_run(void *ctx)
{
    gss_query *q = (gss_query *)ctx;
#ifndef NO_GSSAPI
    Conf *conf = conf_new();
    do_defaults(NULL, conf);
    struct ssh_gss_liblist *list = ssh_gss_setup(conf);
    q->names = snewn(list->nlibraries ? list->nlibraries : 1, char *);
    for (int i = 0; i < list->nlibraries; i++) {
        struct ssh_gss_library *lib = &list->libraries[i];
        const struct gssapi_functions *f = &lib->u.gssapi;
        bool complete = f->delete_sec_context && f->display_status &&
            f->get_mic && f->verify_mic && f->import_name &&
            f->init_sec_context && f->release_buffer && f->release_cred &&
            f->release_name && f->acquire_cred && f->inquire_cred_by_mech;
        if (complete && lib->gsslogmsg)
            q->names[q->count++] = dupstr(lib->gsslogmsg);
    }
    ssh_gss_cleanup(list);
    conf_free(conf);
#endif
}

char **spb_debug_gssapi_libraries(size_t *count)
{
    gss_query q = { NULL, 0 };
    if (!spb_loop_run_sync(gss_query_run, &q))
        q.count = 0;
    *count = q.count;
    return q.names;
}
