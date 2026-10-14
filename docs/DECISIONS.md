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
(`0006`) is needed for structured status.

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
**Decision:** Carry minimal patches `0007`/`0008`, prove each with an ASan
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

## D-021 — Terminal frames: resolved cells, published under a paint lock, pulled on notification

**Status:** Accepted (M03); refines D-007
**Context:** PuTTY's Terminal draws through `TermWin` on the core thread;
AppKit draws on the main thread. Copying per character, or per call,
would be slow. Redrawing from raw PuTTY attributes in Swift would mean
re-implementing GTK's colour rules there.
**Decision:** The TermWin writes into one grid of cells per session,
with colours resolved as GTK PuTTY resolves them. The grid is the
published frame: a mutex is held from `setup_draw_ctx` to
`free_draw_ctx`, so a reader never sees half a paint. TermWin calls that
PuTTY makes in the middle of a paint (scrollbar, palette) record their
change under the held lock. After a change, `terminal_updated` fires once
and is re-armed only when the frontend reads the frame, which copies only
the dirty rows into the frontend's own buffer.
**Consequences:** Rendering in Swift is "fill backgrounds, draw glyphs,
decorate". Frame traffic is bounded by how fast the main thread reads,
and PuTTY's own update timer batches output first: 20,000 lines produce
single-digit notifications. The paint holds the lock briefly; readers
copy only changed rows.

## D-022 — Clipboards follow PuTTY's Unix model

**Status:** Accepted (M03)
**Context:** The core is built with upstream's Unix (X11) clipboard
definitions: mouse selection goes to `CLIP_PRIMARY`, explicit copy and
paste to `CLIP_CLIPBOARD`. macOS has no primary selection.
**Decision:** `CLIP_PRIMARY` is an app-private "last selected text"
buffer, shared by all session windows (as X's PRIMARY is shared).
`CLIP_CLIPBOARD` is the general pasteboard. The bridge registers both
with each Terminal as GTK's `setup_clipboards` does, honouring
`MouseAutocopy` and `MousePaste`. Edit > Copy (⌘C) puts the window's
latest selection on the general pasteboard; Edit > Paste (⌘V) pastes
from it. Named X11 clipboards (`CLIPUI_CUSTOM`) behave as "none".
**Consequences:** PuTTY's selection, paste and Copy All semantics are
upstream's. Windows PuTTY's default of auto-copying selections to the
system clipboard is available through the existing `MouseAutocopy`
setting (configuration UI in M05/M12).

## D-023 — Keyboard: Swift classifies, PuTTY translates

**Status:** Accepted (M03)
**Context:** Key translation depends on terminal modes (cursor/keypad
application mode, function key type, Backspace setting), which live on
the core thread. macOS key events carry layout-dependent text and
layout-independent key codes.
**Decision:** `TerminalKeyMapper` (Swift) recognises the keys PuTTY
translates by key code and passes them as `spb_key` + modifiers. C
translates them with GTK PuTTY's `key_event` logic and PuTTY's own
`format_*_key` functions. Ordinary text goes through the macOS input
method (`NSTextInputClient`), so dead keys and IMEs work; composition
text is drawn by PuTTY at the cursor. Control combinations are sent as
control characters. Option is Meta when `OSXOptionMeta` is set
(upstream's default is on); Command is Meta only with `OSXCommandMeta`,
otherwise Command shortcuts go to the menus.
**Consequences:** Byte sequences match upstream exactly and follow
terminal modes. With Option as Meta, Option-layer characters need
`OSXOptionMeta` off (configuration UI in M05).

## D-024 — SSH logins in the terminal; dialogs through an asynchronous prompt API

**Status:** Accepted (M04)
**Context:** PuTTY asks for user names, passwords and keyboard-interactive
responses through `seat_get_userpass_input`, and for host-key and
weak-crypto confirmation through `seat_confirm_*` with a completion
callback. GTK PuTTY answers the first in the terminal
(`term_get_userpass_input`) and shows dialog boxes for the second.
**Decision:** The same. Login prompts are handled by PuTTY's terminal, so
they look and behave as upstream's (echo rules, trust sigil, "Access
denied" and retry). Dialogs reach the frontend as one generic `prompt`
callback carrying PuTTY's structured `SeatDialogText` and an id; the
frontend answers with `spb_session_answer_prompt`. "Accept" stores the
key with upstream's `store_host_key` (in the private state directory). If
the connection ends while a dialog is up, the bridge forgets the
callback (it would call into a freed backend) and tells the frontend with
`prompt_cancelled`; stale answers are ignored. The macOS sheet lays the
text out as GTK PuTTY does; a changed-key warning has no default button.
**Consequences:** No password ever passes through Swift or the UI layer;
it goes from keystrokes to PuTTY's prompt buffer on the core thread. Any
future PuTTY dialog maps onto the same API.

## D-025 — SSH test fixture: upstream's uppity behind a loopback relay

**Status:** Accepted (M04); refines D-009
**Context:** Automated SSH tests need a deterministic local server.
OpenSSH `sshd` cannot do password authentication unprivileged. PuTTY's
own test server, `uppity`, can (any user; password "weasel";
keyboard-interactive "stoat"/"weasel") and is built from the vendored
tree, but on macOS it rejects TCP clients: it only trusts peers it can
identify as the same user, and its check reads Linux's `/proc`.
**Decision:** `spb_ssh_fixture` (test-only) runs `uppity` on a Unix-domain
socket, which it accepts, and relays a loopback TCP port to it, so the
client under test uses its real TCP path. Test host keys
(`Core/tests/fixtures/hostkey-{a,b}.ppk`) are generated with upstream's
`puttygen`, committed, and marked as not secret. Exit statuses from
`uppity` can read 127 when its pty reaches end-of-file before it reaps
the shell (`unix/pty.c`, `EXITTYPE_WEIRD`); tests accept that value, and
exact exit statuses are checked by hand against OpenSSH.
**Consequences:** SSH tests run in seconds, offline, in CI on both
architectures, under the sanitizers. Public-key and agent tests (M09)
can add OpenSSH `sshd` with key authentication.

## D-026 — Session windows belong to one launch; local network access is declared

**Status:** Accepted (M04)
**Context:** SwiftUI restores `WindowGroup` windows with their values at
the next launch, which reconnected old sessions (and showed empty windows
for values that no longer decoded). PuTTY never reconnects by itself.
Separately, macOS requires apps to declare local-network use: without it,
connections to LAN addresses fail with "No route to host".
**Decision:** Each `SessionRequest` carries an id for the launch that made
it; a restored window from another launch closes without connecting, and
windows that cannot be decoded close too. `NSQuitAlwaysKeepsWindows` is
registered false. The app declares `NSLocalNetworkUsageDescription`, so
macOS asks the user once.
**Consequences:** Relaunching shows the launcher only. The first
connection to a LAN host shows the system's Local Network permission
prompt.


## D-027 — Saved sessions: one versioned JSON file, PuTTY's rules

**Status:** Accepted (M05); implements D-004's persistence
**Context:** PuTTY keeps sessions in the registry (Windows) or one file
per session (`~/.putty/sessions`, Unix). SwiftPutty's core never opens a
session by name (`spb_storage.c`); the Swift side owns them.
**Decision:** `Persistence.SavedSessionStore` keeps every session in
`~/Library/Application Support/SwiftPutty/Saved Sessions.json`:
`{"format": "org.swiftputty.saved-sessions", "version": 1, "sessions":
{name: {PuTTY keyword: value}}}`, values encoded as PuTTY's Unix files
encode them, keys sorted (deterministic output). Each call reads the file
afresh (as PuTTY reads its storage). Each change writes a new file
created with mode 0600 (sessions can hold proxy passwords) in a 0700
directory, synced, then renamed over the old one. A file with a newer
version, or one that cannot be read, is reported and never overwritten.
Older versions will be migrated in place on read when a version 2
exists. PuTTY's rules apply unchanged: "Default Settings" is always
listed first; other names sort by `strcmp`; an empty name means "Default
Settings"; a missing session loads as built-in defaults; sessions are
saved normalised (every keyword).
**Consequences:** A session is a PuTTY keyword map, so importing PuTTY's
Unix session files later is a format conversion. One damaged file
affects all sessions, but it is never destroyed automatically.

## D-028 — The configuration dialog is native, panel by panel

**Status:** Accepted (M05)
**Context:** PuTTY describes its dialog portably (`config.c`
`setup_config_box`, handlers driven through `dlg_*` calls), and each
frontend renders it. Rendering that control box from Swift would mean
implementing the `dlg_*` API across the core thread for synchronous
handlers, file and font selectors and colour pickers.
**Decision:** SwiftUI panels (`ConfigurationUI`) edit the keyword map
directly, following `setup_config_box` for wording, order and saved
values. The logic of the handlers that are more than "set a keyword"
(`sessionsaver_handler`, `config_protocols_handler`,
`config_port_handler`, keepalive minutes/seconds) is mirrored in
`ConfigurationModel` and unit-tested. Panels use `PuTTYKeyword`, which a
test checks against PuTTY's saved keywords. A control appears only when
SwiftPutty implements its effect; categories are added by the milestones
that implement them (M06 terminal, M09 SSH, M12 the rest). Open, Cancel
and About follow PuTTY; Open closes the dialog; File > New Session…
reopens it, starting from "Default Settings".
**Consequences:** Native controls and no core-thread round trips while
editing. The parity table (CONFIGURATION_PARITY.md) is the checklist that
keeps the panels in step with upstream; an upstream update must be
diffed against `config.c`.

## D-029 — The log file question has its own dialog slot; `prepare_session` in the bridge

**Status:** Accepted (M05); extends D-024 (API v5)
**Context:** With "Ask the user every time" (PuTTY's default), the log
file opens on the first logged byte, which can be while the host key
dialog is up. GTK PuTTY keeps dialogs in slots, so the two coexist.
Separately, GTK PuTTY applies `prepare_session` (user@host, `:suffix`,
whitespace) before connecting; the bridge did not.
**Decision:** `SPB_PROMPT_LOG_FILE_EXISTS` uses the same prompt callback
with a second slot per session, answers `SPB_ANSWER_LOG_OVERWRITE`,
`SPB_ANSWER_LOG_APPEND` or `SPB_ANSWER_CANCEL` (GTK's Overwrite / Append /
Disable). Log data is queued by upstream while it is open. It survives
the end of the connection and is withdrawn only at release.
`SessionController` holds pending prompts in order. `spb_session_create`
calls `prepare_session`; `spb_settings_prepare_session` exposes it so the
frontend shows the destination as PuTTY uses it.
**Consequences:** Logging works with PuTTY's default settings. A host
key dialog and a log question can both be pending; the window shows them
one after the other.
