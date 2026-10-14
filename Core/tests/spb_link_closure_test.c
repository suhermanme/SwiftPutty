/*
 * Link-closure test: CMake links this program with -force_load of the
 * whole core archive, so the build fails if any member of the archive has
 * an unresolved symbol. Running it checks that static initialisation of
 * the complete core is harmless.
 */

#include <stdio.h>
#include <string.h>

#include "PuTTYBridge.h"

int main(void)
{
    if (strcmp(spb_putty_version(), "Release 0.85") != 0) {
        fprintf(stderr, "unexpected version %s\n", spb_putty_version());
        return 1;
    }
    printf("spb_link_closure_test: all archive members linked\n");
    return 0;
}
