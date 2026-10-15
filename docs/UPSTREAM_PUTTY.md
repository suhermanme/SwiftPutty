# Upstream PuTTY

## Pinned version

| Item | Value |
|---|---|
| Version | **PuTTY 0.85** (`LATEST.VER` = `0.85`, `version.h` `TEXTVER "Release 0.85"`) |
| Git tag | `0.85` |
| Commit | `a3cce3a48d4ab12e0fccb32998b9042d4f7c3ff1` (tag date 2026-08-14) |
| Git repository | `https://git.tartarus.org/simon/putty.git` |
| Source archive | `https://the.earth.li/~sgtatham/putty/0.85/putty-0.85.tar.gz` |
| Archive SHA-256 | `13fd4db2936d03b73812a7bcc2a658e4dd29cc776a56c3670a7fc6f1a0ee8af8`, matching upstream `sha256sums` |
| GPG signature | `putty-0.85.tar.gz.gpg` downloaded. **Not verified in M00** (no `gpg` on the build host); verify with the PuTTY release key before M01 sign-off |
| Vendored at | `Vendor/putty/` (the extracted archive, unmodified) |
| Licence | MIT (`Vendor/putty/LICENCE`) |

The release archive was vendored rather than a git checkout. It is what the
PuTTY team signs, and it includes generated files (`version.h`) that a git
checkout lacks.

## Source subset used (as linked in M01)

Defined in `Core/cmake/SwiftPuttyCore.cmake`. Upstream libraries are used
whole where everything in them is wanted. Where an upstream library bundles
code that SwiftPutty replaces, the needed sources are listed individually.

| Upstream library / files | How | Why |
|---|---|---|
| `utils` (+ `unix/utils/*`), `charset` | whole | Base utilities, Unicode/charsets |
| `crypto` (+ CPU-specific object libraries: AES-NI, SHA-NI, CLMUL / NEON AES, SHA-256/512, PMULL) | whole | All cryptography |
| `sshclient` + `sshcommon` (+ `unix/gss.c`, `unix/agent-client.c`, `unix/sharing.c`, `sshpubk.c`, `sshrand.c`) | whole | SSH client, port forwarding, sharing, agent, GSSAPI, key files |
| `network` (`proxy/*`, `errsock.c`, `x11disp.c`, `unix/network.c`, `unix/fd-socket.c`, `unix/agent-socket.c`, `unix/peerinfo.c`, `unix/local-proxy.c`, `unix/x11.c`) | whole | Sockets, proxies |
| `otherbackends` (`otherbackends/*`, `unix/serial.c`), `all-backends` (`pinger.c`), `logging` | whole | Other backends (M11), keepalives, event log |
| `keygen` (`import.c`, `keygen/*`) | whole | Foreign key-file import (used by `sshpubk.c`) |
| `callback.c`, `timing.c`, `unix/uxsel.c` | individual | Event primitives: upstream `eventloop` **minus** `unix/cliloop.c` (the bridge drives the loop) |
| `settings.c` | individual | Conf ⇄ keyword mapping: upstream `settings` **minus** `unix/storage.c` and `cmdline.c` |
| `unix/storage.c` | individual, session functions renamed via `-D` | Host keys, host CAs, random seed (D-011) |
| `terminal/terminal.c`, `terminal/bidi.c`, `terminal/lineedit.c`, `ldisc.c` | individual | Upstream `guiterminal` **minus** `config.c`/`dialog.c` (native UI instead) |
| `unix/unicode.c`, `unix/no-gtk.c`, `unix/printing.c` | individual | Unix platform pieces GUI frontends link themselves |
| `be_list.c` | individual, `SSH=1 SERIAL=1 OTHERBACKENDS=1 APPNAME=SwiftPutty` | Backend table |

Frontend-provided symbols implemented by the bridge (`Core/src/`):
`platform_default_*`, `x_get_default`, `platform_get_x_display`,
`share_can_be_downstream/upstream`, `nonfatal`, `modalfatalbox`,
`old_keyfile_warning`, `uxsel_input_add/remove`, `timer_change_notify`,
and the session half of `storage.h`. The bridge also does the frontend
initialisation every upstream frontend performs:
`settings_set_default_protocol/port`, `sk_init`, `uxsel_init`.

**Not used:** `windows/*`, all GTK files (`unix/window.c`, `unix/gtk-*.c`,
`unix/unifont.c`, `unix/config-gtk.c`, `unix/dialog.c`, `unix/main-gtk-*.c`,
`unix/columns.c`, XPM icon files), `unix/cliloop.c`, `unix/pty.c`/`pterm`,
`config.c`, `dialog.c`, `cmdline.c`, `pscp.c`, `psftp*.c`, `pageant*.c`,
`cmdgen.c`, server-side SSH (`ssh/*server*.c`, `ssh/sesschan.c`; test
fixtures excepted).

## Build integration

Implemented in M01. See D-006, D-010 and D-012 in `DECISIONS.md`.

1. `scripts/prepare-putty-src.sh build/putty-src` copies `Vendor/putty/`
   and applies `patches/*.patch` in order. Each patch is dry-run first and
   any failure stops the build. The copy is only redone when the vendored
   tree or a patch changes (hash stamp). `Vendor/putty/` stays pristine.
2. `scripts/build-core.sh` configures upstream's own `CMakeLists.txt` once
   **per architecture** (`build/core-arm64`, `build/core-x86_64`) with
   `-DPUTTY_GTK_VERSION=NONE`, `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`, and
   `-DCMAKE_PROJECT_putty_INCLUDE=Core/cmake/SwiftPuttyCore.cmake`, which
   injects the `swiftputty-core` library and the C tests
   (`spb_bridge_test`, `spb_session_test`, `spb_link_closure_test`).
3. A post-build step repacks the archive with unique member names (D-015).
4. The two slices are combined with `lipo` into
   `build/SwiftPuttyCore.xcframework` (one `macos-arm64_x86_64` library,
   plus `PuTTYBridge.h` and the `PuTTYBridgeC` module map).
5. The Swift package (`Package.swift`) and the app
   (`App/SwiftPutty.xcodeproj`) link the xcframework. Only `PuTTYBridge.h`
   is visible to Swift.

Verified in M01: each slice contains its hardware crypto
(`ssh_aes128_sdctr_ni`, `ssh_sha256_ni`, `ssh2_aesgcm_mac_clmul` on x86_64;
`ssh_aes128_sdctr_neon`, `ssh_sha256_neon`, `ssh_sha512_neon`,
`ssh2_aesgcm_mac_neon` on arm64). The build has zero warnings.

## Patches

| Patch | Files | Purpose | Upstream status |
|---|---|---|---|
| `0001-arm-arch-queries-sysctl-fallthrough.patch` | `unix/utils/arm_arch_queries.h` | **Applied (M01).** `test_sysctl_flag()` fell off the end of a non-void function when `sysctlbyname()` failed, so callers could read an indeterminate "CPU feature present" result. Clang reported it as `-Wreturn-type` | Not yet reported; suitable for upstream |
| `0002-pollwrap-hup-wakes-writers.patch` | `unix/utils/pollwrap.c` | **Applied (M02).** On macOS, `poll()` reports a refused non-blocking `connect()` as `POLLHUP` alone, which pollwrap did not treat as "writable", so the failure was never dispatched and the event loop spun at 100% CPU. Reproduced with unpatched upstream `plink -raw` on macOS (100% CPU, never exits). `POLLHUP` now wakes writers, as `select()` does | Not yet reported; suitable for upstream |
| `0003-network-free-connect-error-message.patch` | `unix/network.c` | **Applied (M02).** The error text of a failed asynchronous `connect()` was never freed (one leak per failed attempt). Found by `leaks --atExit` | Not yet reported; suitable for upstream |
| `0004-terminal-free-last-selected-text.patch` | `terminal/terminal.c` | **Applied (M03).** `term_free()` did not free the "last selected text" buffers that `clipme()` hands to the Terminal for `CLIP_LOCAL`. Unnoticed upstream because frontends free a Terminal only at process exit. Found by `leaks --atExit` | Not yet reported; suitable for upstream |
| `0005-ssh-bpp-free-clears-queues.patch` | `ssh/common.c` | **Applied (M04).** `ssh_bpp_free()` did not free packets still queued in the BPP (e.g. while the host key dialog pauses key exchange), so closing such a session leaked them. Found by `leaks --atExit` | Not yet reported; suitable for upstream |
| `0006-portfwd-status-hook.patch` | `defs.h`, `putty.h`, `ssh.h`, `ssh/portfwd.c`, `ssh/connection1-client.c`, `ssh/connection2-client.c` | **Applied (M08).** Optional `LogPolicyVtable.portfwd_status` method (NULL-checked via `lp_portfwd_status`, so other frontends are unaffected). `PortFwdRecord` remembers its `CONF_portfwd` key/value; `portfwdmgr_report_status()` reports listening / listen failed, remote requested / enabled / refused / duplicate, and closed, next to the existing Event Log messages | SwiftPutty-specific; could be offered |
| `0007-rportfwd-cancel-pending-reply.patch` | `ssh.h`, `ssh/connection2.h`, `ssh/connection2.c`, `ssh/connection2-client.c` | **Applied (M08).** Fix H-1: removing a remote forward while its `tcpip-forward` reply is outstanding was a use-after-free in `ssh2_rportfwd_globreq_response` (reproduced under ASan, `spb_ssh_test`). Such records are now marked removed and freed by the reply handler. Also frees the queue of outstanding global requests at connection teardown, which leaked | **Not yet reported; should be** (memory safety) |
| `0008-portfwd-duplicate-rportfwd-free.patch` | `ssh/portfwd.c` | **Applied (M08).** Fix H-2: a duplicate remote forwarding's record was freed but left in the manager's tree; the next `portfwdmgr_config` used it (reproduced under ASan, `spb_ssh_test`). Now removed from the tree first | **Not yet reported; should be** (memory safety) |

Each patch carries a header stating its purpose, the upstream version it
was made against, and its upstream status. See also `patches/README.md`.

## Upstream history relevant to this project

- `03e71efc` "Fix linked-list mismanagement in global request queue"
  (2022-05-04, first in **0.77**). It fixed a crash when remote forwards were
  added via Change Settings more than once. Included in 0.85. This is the
  "historical bug around repeated remote-forward reconfiguration" that the
  M08 tests target.
- `8b294eb8` (much older): double free when cancelling a refused remote
  forward. Fixed long ago, but the same code region was involved.
- Changes in upstream `main` after 0.85 to forwarding code (checked during
  M00): only `6a1c058a` "Missing consts in the port forwarding code"
  (cosmetic). H-1 and H-2 are still present in `main`. Both were
  reproduced under AddressSanitizer in M08 (use after free in
  `ssh2_rportfwd_globreq_response`, and in `portfwdmgr_config` after the
  duplicate branch) and are fixed by patches 0007 and 0008.

## Update procedure (to be validated in M16)

1. `git fetch` upstream. Read the release's change log, security advisories
   (`https://www.chiark.greenend.org.uk/~sgtatham/putty/changes.html`,
   `…/wishlist/`), and the diff of `ssh/portfwd.c`, `ssh/connection2*.c`,
   `ssh/ssh.c`, `putty.h`, `conf.h`, `settings.c`, `terminal/terminal.c`.
   Only tagged releases are allowed, never unreviewed snapshots.
2. Download the release tarball and `.gpg`. Verify the signature and the
   SHA-256 against `sha256sums`.
3. Replace `Vendor/putty/` wholesale with the new extracted tree.
   Re-check the hand-picked source lists in `Core/cmake/SwiftPuttyCore.cmake`
   against the new upstream `CMakeLists.txt` files.
   Upstream's own `.gitignore` excludes documentation files that the
   release tarball ships (`doc/*.1`, `doc/putty.chm`, `doc/puttydoc.txt`),
   so stage the new tree with `git add -f Vendor/putty` to keep it
   identical to the tarball.
4. Re-apply `patches/` with `git apply --3way`. Drop any patch upstream has
   absorbed and update its header otherwise.
5. Rebuild both architectures. Check that `conf.h` key-count and keyword
   changes are reflected in `CONFIGURATION_PARITY.md` (a test fails if
   `conf_key_info[]` contains keys the parity table doesn't list).
6. Run the bridge tests, SSH integration tests, tunnel/reconfiguration
   regression suite (including H-1/H-2 ASan tests) and the parity suite.
7. Update this file, `THIRD_PARTY_NOTICES.md` and `DECISIONS.md`.
