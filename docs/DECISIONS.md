# Architectural Decisions

Format: ID — title. Status, context, decision, consequences. Newest last.

---

## D-001 — Pin to the PuTTY 0.85 release tarball

**Status:** Accepted (M00)
**Context:** The project needs a stable, reviewable upstream. Snapshots
change without release notes.
**Decision:** Vendor the signed 0.85 release archive (git tag `0.85`,
`a3cce3a4…`) unmodified under `Vendor/putty/`. Apply local changes only via
`patches/` at build time.
**Consequences:** Updates are explicit (see `UPSTREAM_PUTTY.md`). The GPG
signature still has to be verified on a host with `gpg`.

## D-002 — Reuse the Unix (POSIX) platform layer, not the Windows one

**Status:** Accepted (M00)
**Context:** Windows PuTTY is the *behavioural* reference, but its platform
code (`windows/handle-*.c`, `windows/network.c`, registry storage) is
Win32-specific. macOS is POSIX, and upstream's `unix/` layer already supports
macOS for its non-GTK parts (verified by building `plink` in M00).
**Decision:** Link upstream `unix/` networking, uxsel, serial, agent-client,
sharing, noise and unicode code. Use none of `windows/` or the GTK frontend.
Behaviour that differs between upstream's Windows and Unix frontends is
resolved in favour of Windows, implemented in the Swift frontend.
**Consequences:** Agent support speaks `SSH_AUTH_SOCK` (OpenSSH/macOS agent)
via `unix/agent-client.c`. Pageant named-pipe support does not apply.

## D-003 — One process-wide PuTTY core thread with a poll() loop

**Status:** Accepted (M00)
**Context:** PuTTY's fd registry (`unix/uxsel.c`), timers (`timing.c`),
toplevel callbacks (`callback.c`), random pool and storage are
process-global and not thread-safe. Upstream frontends drive them from one
thread (`unix/cliloop.c` poll loop; GLib in `unix/gtk-common.c`). The project
forbids blocking the main thread and requires a serialised core.
**Options considered:** (a) run the core on the main thread as GTK PuTTY does.
Rejected: `getaddrinfo` and local-proxy setup block. (b) One thread per
session. Impossible: shared globals. (c) A `DispatchSource`-based serial
queue. Workable, but loses `SELECT_X` (exceptional/urgent data, used by
Telnet) and diverges from upstream's loop.
**Decision:** A single dedicated core thread runs a `poll()` loop modelled on
`unix/cliloop.c`, with a self-pipe for wakeups and a locked command queue.
All bridge calls enqueue. All PuTTY callbacks run on that thread and are
forwarded to Swift, which hops to `@MainActor`.
**Consequences:** Exact upstream event semantics. A slow DNS lookup in one
session can stall others (risk R-2; revisit by M14).

## D-004 — Convert configuration through PuTTY's own settings code

**Status:** Accepted (M00)
**Context:** `Conf` has 211 primary keys declared in `conf.h`, with defaults,
storage enums and legacy-key handling in `settings.c`. A hand-written
Swift ⇄ Conf converter would drift.
**Decision:** The bridge implements `storage.h` (`settings_r`/`settings_w`)
over an in-memory, sorted keyword map. Swift's typed `SessionConfiguration`
maps to and from PuTTY *save keywords* (`HostName`, `PortForwardings`, …),
and C uses `load_open_settings`/`save_open_settings`. Runtime Apply uses a
`conf_key_info[]`-driven overlay that preserves `NOT_SAVED` keys, because
`load_open_settings` resets them (ARCHITECTURE §6.3).
**Consequences:** Upstream-exact parsing and defaults. Deterministic
serialisation. PuTTY session import becomes a keyword-map import. The Swift
persistence schema is our own versioned Codable format (not the registry),
but its field identity is PuTTY's keywords.

## D-005 — Runtime reconfiguration = whole-Conf replacement; Swift stages tunnel edits

**Status:** Accepted (M00)
**Context:** PuTTY reconfigures a live session with `backend_reconfig(be,
conf)`. `portfwdmgr_config` diffs forwardings internally (destroy pass, then
create pass).
**Decision:** The single C entry point is
`spb_session_reconfigure(session, settings)`. It runs the same sequence as
the GTK/Windows frontends. There is no C-level add/remove-tunnel API. To avoid
"neither forwarding" after a failed edit, Swift sequences reconfigure calls
(make-before-break when the source differs; break-before-make with rollback
when it is the same) based on structured status events (ARCHITECTURE §6.4).
A preference can disable staging for strict upstream parity.
**Consequences:** Forwarding semantics are PuTTY's. One small upstream patch
(`0004`) is needed for structured status.

## D-006 — Build PuTTY per architecture, then lipo

**Status:** Accepted (M00, observed)
**Context:** Configuring upstream CMake with
`CMAKE_OSX_ARCHITECTURES="arm64;x86_64"` makes `HAVE_WMMINTRIN_H`,
`HAVE_SHAINTRIN_H`, `HAVE_ARM_NEON_H` and `HAVE_ARM_DIT` probes fail. That
compiles out AES-NI/SHA-NI/NEON crypto and the ARM DIT
(data-independent-timing) protection. Per-arch configures detect them
correctly.
**Decision:** Configure and build `swiftputty-core` once per architecture
and combine the slices with `lipo`.
**Consequences:** Slightly more build plumbing. The full security and
performance properties are kept.

## D-007 — Terminal state stays in C; Swift renders immutable frames

**Status:** Proposed (M00; confirm in M03)
**Context:** PuTTY's `Terminal` must be touched only on the core thread, and
it draws through `TermWin` callbacks during `term_paint`. AppKit draws on the
main thread.
**Decision:** The bridge's `TermWin` records draw calls into a per-session
shadow grid and publishes coalesced dirty-row frames, paced by display
refresh. `TerminalNSView` (CoreText/CoreGraphics) renders them. Selection,
scrollback, mouse reporting and key formatting stay PuTTY's.
**Consequences:** No per-character SwiftUI updates. One thread hop on input
and output, which M03/M14 must measure.

## D-008 — Fix upstream forwarding memory-safety bugs locally and report upstream

**Status:** Accepted (M00)
**Context:** Code reading found two lifetime bugs in 0.85, still present in
upstream `main`. H-1: removing a remote forward with a pending
`tcpip-forward` reply. H-2: a duplicate remote listen address leaves a freed
record in the manager tree. Both sit on the release-blocking live-tunnel
path.
**Decision:** Carry minimal patches `0005`/`0006`, prove each with an ASan
regression test in M08, and offer them upstream. Add defence in depth in
Swift: serialise remote-forward changes per port, and reject duplicate
listen addresses during validation.
**Consequences:** Two extra patches to rebase until upstream absorbs them.

## D-009 — Test servers: system OpenSSH sshd plus PuTTY's own test server

**Status:** Proposed (M00; confirm in M04/M08)
**Context:** Tests must not reach the Internet. Docker is not installed on
the development host. `/usr/sbin/sshd` (OpenSSH 10.3p1) is, and it can run
unprivileged on a high port with a generated config and keys. Upstream also
ships `uppity` (`unix/uppity.c`), a test SSH server built from PuTTY's server
code that supports `tcpip-forward`/`cancel-tcpip-forward`.
**Decision:** Primary integration fixture: an ephemeral, unprivileged
`sshd -D -f <generated config>` on 127.0.0.1 with generated host/user keys.
Secondary: `uppity` for deterministic or fault-injected cases. Docker
OpenSSH stays optional.
**Consequences:** Self-contained tests on a stock macOS host.

## D-010 — Build integration: inject a target into upstream's own CMake build

**Status:** Accepted (M01)
**Context:** The core must be compiled with exactly upstream's
configuration (feature probes, generated headers, compile definitions), and
`Vendor/putty` must stay pristine. Using upstream as a CMake subdirectory
does not work, because its build scripts use `CMAKE_SOURCE_DIR` in about
100 places.
**Decision:** Configure upstream's top-level `CMakeLists.txt` directly and
inject `Core/cmake/SwiftPuttyCore.cmake` with
`-DCMAKE_PROJECT_putty_INCLUDE=…`, CMake's documented code-injection hook.
The file defers (`cmake_language(DEFER)`) the definition of the
`swiftputty-core` static library and the C bridge test until upstream's
targets exist. The library combines bridge sources, an explicit list of
upstream sources where upstream libraries bundle code the bridge replaces
(`eventloop` → `unix/cliloop.c`; `settings` → `unix/storage.c`;
`guiterminal` → `config.c`/`dialog.c`), and the objects of the upstream
libraries used whole. Those objects are collected generically, including
the CPU-specific crypto object libraries.
**Consequences:** No upstream build files are modified. Upstream source
moves mostly propagate automatically. The upstream object list is
re-checked by the M16 update procedure.

## D-011 — Split storage: upstream Unix storage for host keys, bridge for sessions

**Status:** Accepted (M01)
**Context:** PuTTY's `storage.h` covers named sessions, trusted host keys,
host CAs and the random seed. SwiftPutty keeps named sessions in its own
versioned store (D-004). The other three should use upstream's
implementation and file formats.
**Decision:** Compile upstream `unix/storage.c` **unmodified**, with
`-D` renames that move its session functions and handle types out of the
way (`open_settings_r` → `upstream_open_settings_r`, …).
`Core/src/spb_storage.c` provides the session half over in-memory
`spb_settings` maps, encoding values exactly as upstream's Unix session
files do. Upstream locates the remaining files via `$PUTTYDIR`, which
`spb_core_init` points at the app's state directory
(`~/Library/Application Support/SwiftPutty/PuTTY`, mode 0700). Inherited
`PUTTY*` overrides are cleared so the app never touches `~/.putty`.
Opening a session by name in C fails cleanly with "managed by SwiftPutty".
**Consequences:** Host-key files use upstream's exact format, which keeps
M04 small and makes import/export trivial. `setenv` happens once, under the
core lock, at init.

## D-012 — Packaging: xcframework + Swift package + thin Xcode app project

**Status:** Accepted (M01)
**Context:** SwiftPM cannot run CMake, and SwiftPM alone cannot produce a
signed `.app` bundle with Info.plist, entitlements and hardened runtime.
**Decision:** `scripts/build-core.sh` produces
`build/SwiftPuttyCore.xcframework`: one universal static library plus
`PuTTYBridge.h` and a module map exposing the C module `PuTTYBridgeC`. The
root `Package.swift` (SwiftPuttyKit) wraps it as a binary target and holds
the Swift `PuTTYBridge` module and its tests (`swift test`). The app lives
in `App/SwiftPutty.xcodeproj`, which uses a folder-synchronised source
group and a local package reference to the repository root.
**Consequences:** `scripts/build-core.sh` must run before `swift test` or
an Xcode build (`scripts/build-app.sh` does both). Only `PuTTYBridge.h` is
visible to Swift.

## D-013 — Core lifecycle is once per process

**Status:** Accepted (M01)
**Context:** Upstream's `sk_init()`/`uxsel_init()` allocate global trees.
`sk_cleanup()` only closes sockets and is meant for process exit, and
re-running the init functions would leak.
**Decision:** `spb_core_init` is idempotent for the same state directory.
`spb_core_shutdown` is refused while sessions are alive, and is final:
re-initialisation in the same process returns an error instead of leaking.
**Consequences:** Swift tests share one initialised core per test process.
Shutdown is covered by the C test, which runs in its own process.

## D-014 — Upstream code is compiled with upstream's warnings; bridge code with strict warnings

**Status:** Accepted (M01)
**Decision:** Bridge sources and C tests compile with
`-Wall -Wextra -Werror` (except `-Wno-unused-parameter`, since vtable
callbacks often ignore arguments). Upstream sources keep upstream's flags.
The one exception is the macOS SDK's `sprintf` deprecation, which is
silenced for upstream code only. It appears only at `-O0`, and upstream's
uses are bounded. Real upstream defects found via warnings are fixed with
patches (e.g. `0001`), not suppressed.
**Consequences:** The full build (both architectures, sanitizer build
included) has zero warnings.

## D-015 — Unique archive member names

**Status:** Accepted (M01)
**Context:** Upstream has same-named sources in different directories
(`ssh/sharing.c` and `unix/sharing.c`; `crypto/rsa.c` and `keygen/rsa.c`;
`dsa.c`; `telnet.c`). Static archives store only basenames with zeroed
timestamps, so `dsymutil` silently dropped the debug info of the
duplicates when linking the app.
**Decision:** A post-build step (`Core/cmake/RepackArchive.cmake`) rebuilds
the archive with `libtool -static -D`, naming members after their
checkout-independent build path. It fails the build on any collision.
**Consequences:** Complete debug symbols, and deterministic archives
without user paths embedded in member names.

## D-016 — Platform baseline and identity

**Status:** Accepted (M01; revisit in M15)
**Decision:** The minimum deployment target is macOS 14 (needed for the
Observation framework; matches the Swift 6 toolchain baseline). Swift 6
language mode applies everywhere, and warnings are errors in the app
target. The bundle identifier `org.swiftputty.SwiftPutty` is a placeholder
to replace before any distribution. Hardened runtime is on and signing is
ad hoc. The App Sandbox is off pending the M15 evaluation. The default
terminal font is Menlo-Regular 12 (Windows PuTTY: Courier New 10).

## D-017 — Session release is asynchronous and ends with a `released` callback

**Status:** Accepted (M02)
**Context:** A session's teardown (`backend_free`, `log_free`, dropping
its toplevel callbacks) must run on the core thread. A synchronous release
would block the caller, usually the main thread, behind whatever the core
thread is doing, including a slow `getaddrinfo` (R-2).
**Decision:** `spb_session_release` sets a flag that suppresses every
callback not yet started, queues the teardown and returns. The teardown
ends with `released(ctx)`, the last call ever made with `ctx`, where the
owner frees it. The open-handle count is decremented only after the
teardown is queued, so `spb_core_shutdown` (which queues its stop command
behind all pending work) always runs pending teardowns first.
**Consequences:** The main thread never waits on the core thread. Swift
retains its callback context until `released`; `PuTTYSession.events`
finishes there. `spb_debug_live_sessions` drops only after teardown, so
tests call `spb_core_barrier` before asserting on it.

## D-018 — "Connected" means the backend accepts input

**Status:** Accepted (M02)
**Context:** PuTTY gives frontends no "connection established"
notification. GUI PuTTY simply lets the user type, and each backend's
`sendok()` reports whether input is accepted (Raw: TCP connected; SSH: the
connection layer wants user input, i.e. after authentication).
**Decision:** After each loop iteration the core thread checks
`backend_sendok` for sessions still `CONNECTING` and reports `CONNECTED`
when it turns true. Input sent earlier is passed to the backend
immediately, as in PuTTY (Raw buffers it until the socket connects).
**Consequences:** One cheap check per connecting session per iteration.
`CONNECTED` has the same meaning for every protocol.

## D-019 — Protocols are enabled milestone by milestone

**Status:** Accepted (M02)
**Decision:** `spb_session_start` starts only protocols whose frontend
requirements exist. M02 enables Raw, which needs no prompts and no
terminal. Others fail at once with a message naming their milestone (SSH:
M04; Telnet, Rlogin, SUPDUP, serial: M11). The Seat refuses interactive
prompts (passwords, host keys, weak crypto) with a clear message until M04
and M09 give them UI.
**Consequences:** No protocol runs with a half-implemented frontend. Raw
sessions against local servers exercise the whole executor (sockets,
DNS, failure paths, teardown) in M02.

## D-020 — One serialized Swift test target

**Status:** Accepted (M02)
**Context:** The PuTTY core is per process, and many tests assert on
process-wide diagnostics (live sessions, watched descriptors, loop
iterations). Swift Testing runs suites from different test targets in
parallel in the same process, which made such assertions flaky.
**Decision:** All Swift tests live in the `SwiftPuttyKitTests` target,
under one `.serialized` root suite (`KitTests`). Test-only helpers that
are not tests (loopback servers) live in the non-product `TestServers`
target.
**Consequences:** Deterministic diagnostics assertions; the whole Swift
suite takes a few seconds.
