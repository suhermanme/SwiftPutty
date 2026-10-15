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
session can stall others (risk R-2; revisit by M14). *Amended by D-035
(M11): the loop waits with `select()`, not `poll()`.*

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

## D-030 — Terminal parity: PuTTY's terminal does the work; macOS stands in for Windows window features

**Status:** Accepted (M06); API v6
**Context:** Most Terminal and Window settings are read by PuTTY's own
terminal, line discipline and key formatters, so they work once they can
be set. The rest are frontend work: GTK PuTTY's window code reads a known
list (border, scrollbar side, pointer hiding, clipboard keys, title
handling), and Windows PuTTY adds options with no Unix counterpart (bell
sound file, taskbar flash, always on top, Alt-Enter).
**Decision:**
- The panels follow `config.c` plus `unix/config-gtk.c`'s Unix options
  (scrollbar on left, UTF-8 override, the OS X Meta keys). The core is
  built with upstream's `OSX_META_KEY_CONFIG` (only that part of
  `OSX_GTK`), so `OSXOptionMeta` / `OSXCommandMeta` are saved and loaded
  by `settings.c`, as in upstream's OS X build.
- Frontend options are collected in `TerminalViewOptions` and handled as
  GTK PuTTY handles them. Windows-only options with a macOS equivalent
  are adapted: a custom bell sound plays with `NSSound` (beep if it
  cannot); taskbar flashing becomes a Dock bounce (once, or until
  activated) for a window in the background; always on top is a floating
  window level; Alt-Enter becomes Option-Return.
- Ctrl+Insert and Ctrl+Shift+C/V are decided in the bridge, as GTK's
  `key_event` (new `SPB_KEY_C` / `SPB_KEY_V`): with "No action" they type
  Ctrl-C / Ctrl-V. Clipboard choices use OS X PuTTY's names ("Last selected
  text", "System clipboard"); X11 named clipboards are not offered.
- The character set list is upstream's (`cp_enumerate`, exposed by the
  bridge) without "Use font encoding", which has no meaning when every
  font is drawn as Unicode.
**Consequences:** Settings take effect through upstream code wherever
upstream has it. Windows-only options with no macOS meaning (PC speaker,
logical palettes, Windows mouse-button mode with its context menu, RTF
copy, system colours, resize-by-font) stay out until a later milestone
decides them.

## D-031 — Change Settings: GTK PuTTY's flow, asynchronous, one at a time

**Status:** Accepted (M07); implements D-005 and ARCHITECTURE §6; API v7
**Context:** PuTTY reconfigures a live session by replacing its whole
`Conf` and calling the reconfigure functions in a fixed order; GTK PuTTY
edits a copy in a non-modal dialog and swaps it in on Apply. The main
thread must never wait for the core thread (D-017).
**Decision:**
- `spb_session_export_settings` returns the running settings (with the
  live window title, `term_pre_reconfig`) and `backend_cfg_info`;
  `spb_session_reconfigure` applies a settings map. Both answer through
  callbacks with a request number; `SessionController` turns them into
  `async` calls and allows one Change Settings at a time.
- The new `Conf` is loaded from the settings, then PuTTY's unsaved keys
  (which `load_open_settings` resets) are copied from the running `Conf`.
  This is the §6.3 overlay, built from the other side; a self-check sets
  every key to a non-default value and proves nothing changes across
  export and reconfigure (R-3), and fails if the overlay is removed.
- Order, as GTK's `after_change_settings_dialog`: `log_reconfig`,
  `ldisc_configure` + `ldisc_echoedit_update`, `term_reconfig`,
  clipboards, `backend_reconfig`, then character set, cached values,
  scrollback size and a full redraw. A pending log file question is
  withdrawn if the log is reopened. The frontend then applies font,
  border, scrollbar and window options and resizes the window when the
  size, font, border or scrollbar changed.
- As GTK's `drawing_area_setup`, the running `TermWidth` / `TermHeight`
  follow the window, so the dialog shows the current size.
- The dialog is the configuration window in mid-session mode, shown as a
  sheet on the session window (Session > Change Settings…, ⇧⌘,): Apply
  instead of Open, no About, and what `config.c` hides with `midsession`
  hidden (destination, Load/Delete, Connection's TCP / IP version /
  logical host, Connection/Data; SSH logging only for SSH). Save stays
  ("Save the current session settings").
**Consequences:** No reconnection, ever: settings that need a new
connection are not offered, and a change PuTTY handles by re-keying
(ciphers, compression, rekey limits) re-keys the same connection.
Tunnel edits, with their staging (§6.4), build on this in M08.

## D-032 — Live port forwarding: PuTTY's manager, structured status, edits staged from PuTTY's own idiom

**Status:** Accepted (M08); implements D-005 and ARCHITECTURE §5–6.5; API v8
**Context:** PuTTY applies forwarding changes by diffing the whole
`CONF_portfwd` map (`portfwdmgr_config`), reports outcomes only as Event
Log text, and has two use-after-free bugs on the paths a live editor
exercises (H-1, H-2).
**Decision:**
- Forwardings change only through `spb_session_reconfigure`; there is no
  per-tunnel C API. Patch 0006 adds structured status (`portfwd_status`
  callback), keyed by the exact `CONF_portfwd` entry. Patches 0007 / 0008
  fix H-1 / H-2; both were first reproduced under AddressSanitizer by the
  new tests, which now guard them.
- The Tunnels panel is config.c's (list, Remove, Add, Local / Remote /
  Dynamic, Auto / IPv4 / IPv6, accept-all options), with each row's live
  state mid-session. PuTTY's way of editing — Remove fills the fields
  with the entry, Add puts back the changed one — is recorded as an edit
  pair; no separate Edit control was needed.
- Edits are staged by `SessionController` (§6.4): to another listening
  address, the new forwarding is added first and the old one removed only
  once the new one is up; to the same address, the old one is replaced
  and put back if the new one fails. Plain adds and removes apply in one
  step, as in PuTTY. What was kept is reported to the user.
- A second remote forwarding on the same server address (e.g. `R8080`
  with `4R8080`) is refused when added (H-2 defence in depth).
**Consequences:** A failed edit never leaves the user with neither
forwarding. Forwarding semantics, including PuTTY's "a refused remote
forwarding stays configured and is requested again on the next change",
stay upstream's.

## D-033 — SSH authentication: upstream does it all; tests use uppity's key options

**Status:** Accepted (M09)
**Context:** Public-key authentication, passphrases, the agent, banners
and algorithm preferences are all implemented by PuTTY's SSH code and
need only settings and the terminal (where PuTTY asks for passphrases).
D-009 planned an unprivileged OpenSSH `sshd` for key tests.
**Decision:** No bridge changes. The SSH sub-panels follow config.c
(Kex, Host keys, Cipher with Up/Down preference lists, Auth, Credentials,
GSSAPI, TTY, X11, Bugs, More bugs) with config.c's mid-session rules.
"Attempt authentication using Pageant" reads "SSH agent": on macOS the
agent is the one at `SSH_AUTH_SOCK`, which PuTTY's Unix code already
uses. Key tests use uppity, not `sshd`: `spb_ssh_fixture` passes options
after `--` to it (`--userkey`, `--deny-auth`, `--bannertext`), and test
user keys made with upstream `puttygen` are committed (not secret).
**Consequences:** Key authentication is tested offline in CI. GSSAPI is
not usable on macOS as upstream stands (its Unix loader looks for `.so`
names); agent, agent forwarding and X11 forwarding are configurable but
not yet tested end to end.

## D-034 — Session operations: GTK PuTTY's window menu; restart reuses the session

**Status:** Accepted (M10)
**Context:** GTK PuTTY's window menu (unix/window.c) offers Restart
Session, Duplicate Session, Saved Sessions, Change Settings, Event Log,
Special Commands, Clear Scrollback, Reset Terminal and the clipboard
items; closing a connected window asks first ("Warn before closing
window"). The bridge's states only moved forward, and SwiftUI has no
hook to refuse a window close.
**Decision:**
- Bridge API v9: `spb_session_restart` (only once the connection has
  ended: logs "----- Session restarted -----", `term_pwron(term, false)`,
  connects again with the running Conf; states start again from
  CONNECTING, and the transport id changes), `spb_session_special`
  (accepted only for a command in the list last reported),
  `spb_session_query_close_warning` (the backend's `close_warn_text`),
  Clear Scrollback and Reset Terminal; callbacks `specials_changed` (the
  seat's `update_specials_menu`, flattened; empty when the connection
  goes), `error_message` (the seat's `nonfatal`, GTK's message box) and
  `close_warning`.
- The Event Log is kept as GTK's `logevent_dlg` keeps it (first 128
  entries, then the latest 128 with `..` marking the gap), timestamped
  when the core logs the line, and shown in one window per session that
  closes with it; the selection copies as "time<TAB>event" lines.
- The menu is the app's Session menu, in GTK's order. New Session stays
  in File and the clipboard items in Edit. Duplicate Session uses the
  running settings, as `launch_duplicate_session(inst->conf)` does.
  Saved Sessions opens a session window directly, or the configuration
  dialog when the session has no destination (`launch_saved_session`).
- The window's delegate is wrapped by a forwarding proxy whose
  `windowShouldClose` asks first (`WindowCloseGuard`). Yes closes the
  window with `NSWindow.close()`, which does not ask again.
- Quitting (⌘Q): PuTTY has no Quit, so the app asks once for all the
  windows that would ask, with the same title and buttons.
**Consequences:** A restarted window keeps its terminal, scrollback, Event
Log and log file, as in GTK PuTTY. If SwiftUI ever replaces the window's
delegate, the guard wraps it again on the next view update.

## D-035 — The core loop waits with select(): macOS poll() loses urgent data

**Status:** Accepted (M11)
**Context:** Every connected PuTTY socket asks uxsel for `SELECT_X`
(`unix/network.c` `uxsel_tell`), so that TCP urgent data reaches the
backend: Rlogin servers ask for the window size that way (0x80), and
Telnet uses it for SYNCH. Upstream's `pollwrap` maps `SELECT_X` to
`POLLPRI`. On macOS, `poll()` never reports urgent data: a probe with
one urgent byte pending gets no `POLLPRI`, no `POLLRDBAND` and does not
even wake, while `select()` puts the socket in its exception set and
`recv(MSG_OOB)` returns the byte. Found by the M11 Rlogin test: the
server's request was never answered. Unpatched upstream PuTTY on macOS
would behave the same.
**Options considered:** (a) Patch pollwrap to add a `select()` check
after each `poll()`. Rejected: `poll()` does not wake for the urgent
byte, so it would be noticed only when other data arrived. (b) kqueue.
Rejected: a third event mechanism for one bit of semantics. (c) Wait
with `select()`, as PuTTY's Unix loops did before pollwrap.
**Decision:** (c). `spb_eventloop.c` builds read, write and exception
sets sized to the highest descriptor, with `_DARWIN_UNLIMITED_SELECT`
so `FD_SETSIZE` does not limit the number of sessions. The sets are
rebuilt every iteration (select overwrites them); an interrupted wait
goes round the outer loop instead of retrying with undefined sets.
**Consequences:** Rlogin window size requests and Telnet SYNCH work. A
refused `connect()` still wakes the loop (select reports the socket
writable), so patch `0002` is no longer exercised by the loop; it stays
applied, as pollwrap is upstream code still built. Cost is O(highest
descriptor) per iteration, small next to the per-iteration uxsel rescan.

## D-036 — Saved sessions for PuTTY's own lookups: a frontend callback (API v10)

**Status:** Accepted (M12)
**Context:** An SSH proxy ("jump host") names its host either as a host
or as a saved session, and PuTTY opens it with `do_defaults(name)`,
starting from "Default Settings" otherwise. Saved sessions belong to the
frontend's versioned store (D-027), not to `unix/storage.c`, so the core
found no session at all and every jump host started from built-in
defaults.
**Options considered:** (a) Mirror the store into PuTTY's Unix session
files. Rejected: two stores and two formats to keep consistent. (b) Pass
every saved session into the core up front. Rejected: stale after any
save, and it loads every session for each connection. (c) Let the core
ask the frontend by name when PuTTY asks.
**Decision:** (c). `spb_core_set_saved_session_lookup` installs a
callback the core calls on the core thread with the session name
("Default Settings" for PuTTY's default); it returns a new settings
object or NULL. `PuTTYCore.setSavedSessionLookup` wraps it and
`AppModel.startCore` answers from the saved-session store. The callback
must return promptly and must not call session functions.
**Consequences:** SSH proxies behave as in PuTTY, including a proxy that
is itself a saved session with its own settings (tested by
`test_ssh_jump_proxy` and Swift `ProxyTests`). Without a lookup, no
saved session exists, which is what the C tests and plain library users
get.

## D-037 — Host CAs: a native window over upstream's storage, ca-config.c not linked

**Status:** Accepted (M12)
**Context:** Windows PuTTY's "Configure host CAs" is a separate dialog
(`ssh/ca-config.c`) written against the portable `ctrl_*`/`dlg_*` dialog
API, over the `host_ca_*` storage API that `unix/storage.c` implements in
the state directory.
**Options considered:** (a) Implement upstream's dialog API to run
ca-config.c. Rejected: a second dialog system for one window. (b) Keep
CAs in the frontend's store. Rejected: PuTTY's certificate checks read
`host_ca_load` itself. (c) Bridge functions with the dialog's rules, and
a native window.
**Decision:** (c). `Core/src/spb_hostca.c` (API v10) lists, loads, saves
and deletes records through upstream storage on the core thread, and
applies ca-config.c's rules: the key may be base64 or a public key
file's text and is shown by fingerprint, may not be a certificate, and
the validity expression must parse (its error located by offset and
length for the editor). `HostCAStore` and `HostCAEditor` provide the
window, opened from the Host keys panel, also mid-session.
`ca-config.c.o` is filtered out of the core archive in
`SwiftPuttyCore.cmake`.
**Consequences:** Records are upstream's format in upstream's place, so
PuTTY's own certificate validation uses them unchanged. An upstream
change to ca-config.c's rules must be mirrored in spb_hostca.c
(UPSTREAM_PUTTY.md update procedure).

## D-038 — Mouse button actions and the terminal's context menu

**Status:** Accepted (M12)
**Context:** Windows PuTTY's "Action of mouse buttons" (`MouseIsXterm`)
decides what the right button does: in Windows mode it opens the
window's menu and the middle button extends; in Compromise and xterm
modes the right button pastes or extends. Ctrl+right-click always opens
the menu (`WM_RBUTTONDOWN`), and GTK PuTTY uses the same gesture. macOS
has no window (system) menu.
**Decision:** The terminal view shows a context menu for Ctrl+right-click,
or any right-click in Windows mode, even when the application has the
mouse; otherwise the click goes to PuTTY's terminal as before. The menu
(`SessionContextMenu` in `SessionWindow.swift`) copies the app's own
items: New Session, the Session menu in its order, Copy, Paste, Copy
All to Clipboard, and About, so it never disagrees with the menu bar.
**Consequences:** All three modes behave as on Windows for the right
button. On a trackpad, a two-finger click is a right-click and follows
the same rule.

## D-039 — System colours, resize actions and Copy as RTF on macOS

**Status:** Accepted (M12)
**Context:** Three Windows settings name Windows facilities:
`UseSystemColours` (the Windows text and highlight colours), `LockSize`
("When window is resized", including the "maximised" case) and
`PasteRTF` (an RTF clipboard format beside the text).
**Decision:**
- *System colours:* the view resolves `textColor`, `textBackgroundColor`,
  `selectedTextColor` and `selectedTextBackgroundColor` in its effective
  appearance and sends them with `spb_session_set_system_colours` (API
  v10), which overrides the default and cursor colours while the setting
  is on; they are sent again when the appearance changes, so the
  terminal follows light and dark mode.
- *Resize actions:* "maximised" is zoomed or full screen. Forbid removes
  resizing, zooming and full screen. With "change the font size" the
  grid is kept and the font scaled to fit; an application's resize
  request is refused when forbidden, or when maximised and changing rows
  and columns, as `wintw_request_resize` does.
- *Copy as RTF:* the bridge (API v11, `clipboard_write_styled`) hands the
  frontend the copy as runs of equal style, decided as `win_clip_write`
  decides them (colours after reverse video and bold/blink bumps; the
  default colours reported as "default"; bold and underline only). The
  view writes plain text and RTF (terminal font, colours, bold font,
  underline) to the pasteboard; runs in the default colours carry no
  colour so the receiving app uses its own. The X selection buffer keeps
  the RTF so Edit > Copy includes it.
**Consequences:** All three are tested (C `test_system_colours`,
`test_copy_as_rtf`; Swift `systemColoursFollowTheAppearance`,
`resizeActions`, `copyAsRTF`). Windows writes its RTF by hand; macOS
generates it from an attributed string, so the exact RTF text differs
while the styling is the same.

## D-040 — The proxy password is kept in the keychain, not the sessions file

**Status:** Accepted (M13)
**Context:** PuTTY saves `ProxyPassword` with the rest of the session, in
plain text (the registry on Windows, `~/.putty/sessions` on Unix).
SwiftPutty's sessions file is mode 0600 (D-027), but it is still a plain
file that backups, sync tools and support requests copy.
**Options considered:** (a) Keep PuTTY's behaviour. Rejected by the M13
review. (b) Never save it; upstream's proxies ask for a missing password
(SOCKS 5, HTTP after a 407, Telnet and local commands). Rejected: a
working saved setting would silently stop working. (c) The keychain.
**Decision:** (c). `SavedSessionStore` takes a `SecretStore`; the app
passes `KeychainSecretStore.proxyPasswords` (generic passwords, service
`org.swiftputty.proxy-password`, account = session name). Save writes
the keychain first and the file second, with `ProxyPassword` empty, so a
keychain failure (reported, `SavedSessionStoreError.secret`) leaves the
old session intact. Load fills the password back in; a password still
in the file is moved to the keychain and the file rewritten. Delete
removes the item after the file. The JSON format is unchanged (version
1): an empty value was always valid.
**Consequences:** Sessions files carry no secrets, so they can be copied
freely. Copying one to another Mac does not carry the proxy password.
Developer builds are ad-hoc signed, so after a rebuild macOS may ask once
whether the new binary may read the item ("Always Allow" answers it); a
Developer ID signature (M15) keeps the access across updates. Everything
else PuTTY saves in a session (e.g. `ProxyUsername`) stays in the file.

## D-041 — Local commands: reviewed, spawned without fork, reaped without SIGCHLD

**Status:** Accepted (M13)
**Context:** Three settings run a local command through `/bin/sh -c`:
the local proxy command (`ProxyTelnetCommand` with proxy type 5), the
authentication plugin (`AuthPlugin`) and the pre-connect command
(`PreConnectCommand`, not offered until this review). They run only
what the user typed into their own sessions, as in PuTTY, so running a
command is not itself the risk. The review of how upstream runs them
(`unix/local-proxy.c`, `unix/utils/subprocess_waiter.c`,
`proxy/newmain.c`) found:
1. `fork()` in a multithreaded process, and the command inherited every
   descriptor not marked close-on-exec (another session's socket).
2. Local proxy commands and authentication plugins were never waited
   for: one zombie per use, for the life of the app.
3. The pre-connect command's waiter installs a process-wide SIGCHLD
   handler that reaps with `waitpid(-1)`: in an app it takes the exit
   status of every other child (Foundation `Process`, `popen` in
   printing) and interrupts system calls on other threads.
4. `new_main_connection()` blanked the proxy credentials in the session's
   Conf instead of its temporary copy: `%pass` in a pre-connect command
   expanded to the proxy password (also into the Event Log), and the
   session's proxy lost its credentials.
**Decision:** Patch 0014 fixes 4. Patch 0015 starts every local command
with `posix_spawn` (`POSIX_SPAWN_CLOEXEC_DEFAULT`: only the three pipes
survive; signal dispositions and mask reset) and gives every command a
waiter. `unix/utils/subprocess_waiter.c` is not linked;
`Core/src/spb_subprocess.c` implements the same API with one detached
thread per command that waits for that pid alone and hands the exit to
the core thread; a waiter freed before the exit still reaps. The
pre-connect command is offered on the Connection panel, as on Windows.
**Consequences:** No signal handler is installed by the core and no
child of the app is reaped but SwiftPutty's own. `spb_backends_test`
checks each point (a non-close-on-exec descriptor is not visible to the
command, pid gone after exit, `%pass` refused with the proxy still
authenticating); it fails without patches 0014/0015. A thread per
running command is cheap at the numbers involved (one per session at
most for each kind).

## D-042 — Fuzzing with libFuzzer-style harnesses and a built-in driver

**Status:** Accepted (M13)
**Context:** M13 adds fuzzing for what reaches SwiftPutty from outside:
a server's terminal output, and text the user pastes or a sessions file
holds (host keys, CA keys and "valid hosts" expressions, every saved
keyword). Apple's clang has no libFuzzer runtime; an LLVM toolchain
would be a new, large dependency on every developer Mac and CI runner.
**Decision:** Harnesses use libFuzzer's interface
(`LLVMFuzzerTestOneInput`, `LLVMFuzzerInitialize`) and live in
`Core/tests/fuzz/`. By default they link with `spb_fuzz_driver.c`, which
runs the seed corpus and then a fixed number of mutated inputs from a
seeded generator (bit flips, byte edits, range copies and deletions,
dictionary tokens, splices), and saves the input being run if the
process dies. `-DSPB_LIBFUZZER=ON` links them with `-fsanitize=fuzzer`
instead, for coverage-guided runs with an LLVM clang.
- `spb_fuzz_terminal` drives one Raw session through the bridge: each
  input is the server's output, followed by a reset and a marker that
  proves it was processed; then the frame is read and the screen copied
  as RTF.
- `spb_fuzz_parsers` covers manual host keys, CA keys, validity
  expressions and settings records over the defaults plus the legacy
  keywords `settings.c` still reads, normalised and turned into a
  session (with a core barrier, so a failure is blamed on its input).
- ctest runs a short deterministic pass of each (400 and 4,000 inputs)
  in the plain, ASan+UBSan and TSan builds, so CI fuzzes on every push.
  Inputs that found bugs stay in the corpus as regression seeds.
**Consequences:** The pass is not coverage-guided, so it finds shallow
bugs best; it found five upstream ones in its first runs (patches
0016–0019; 0017 reachable from a malicious server). Longer runs:
`SPB_FUZZ_RUNS=<n>` or `-runs=`/`-seed=` by hand. A coverage-guided
campaign with libFuzzer remains worthwhile before release (M17).

## D-043 — GSSAPI on macOS: the system's libraries, under PuTTY's keywords

**Status:** Accepted (M13)
**Context:** Upstream's Unix loader (`unix/gss.c`) dlopens
`libgssapi.so.2`, `libgssapi_krb5.so.2` and `libgss.so.1`; macOS has
none of them, so GSSAPI key exchange and authentication silently did
nothing (M09 left the rows PARTIAL). macOS ships `GSS.framework`
(Heimdal-based) and `libgssapi_krb5.dylib` (an MIT-compatible interface
to it), and both export every function PuTTY binds.
**Options considered:** (a) NOT APPLICABLE. Rejected: the platform has
GSSAPI, and enterprise users rely on Kerberos SSH. (b) Ask users to type
a library path. Rejected: works, but the default would stay broken. (c)
Patch the loader's names on macOS.
**Decision:** (c), patch 0021: on `__APPLE__` the three slots load
`GSS.framework`, `libgssapi_krb5.dylib` and `libgss.dylib` (if
installed), and the list shows those names. The settings keywords
(`libgssapi`, `libgssapi_krb5`, `libgss`, `custom`) do not change, so a
saved session means the same thing on every platform.
`spb_debug_gssapi_libraries` (API v12) reports what the loader opened.
**Consequences:** The bridge test checks both system libraries load with
every function bound, and the SSH test that a login with GSSAPI on (the
default) is not delayed (0.06 s against 0.03 s off, on a Mac with a
local KDC). A GSSAPI login itself is not tested: it needs a Kerberos
realm and a server keytab, which a test cannot set up without root.
On a Mac holding a Kerberos credential (such as its local KDC's), Apple's
Heimdal leaks a few principals inside `krb5_get_credentials` when the
key exchange tries it; the `leaks` pass excludes allocations under that
function and still requires every leak found to be one of them.

## D-044 — A Kerberos realm in Docker for the GSSAPI login test

**Status:** Accepted (M13)
**Context:** D-043 made GSSAPI load on macOS but could not test a login:
that needs a KDC and an SSH server with a host keytab. Options were a
Docker container, a Linux VM, or a KDC and `sshd` run natively.
**Decision:** `Core/tests/fixtures/kerberos/` builds a Debian image with
an MIT KDC (realm `SWIFTPUTTY.TEST`, user `tester`, `host/localhost` in
the keytab) and OpenSSH with GSSAPI authentication and Debian's GSSAPI
key exchange. `fixture.sh start` runs it with the KDC and SSH ports on
127.0.0.1. `spb_ssh_test` starts it before anything in the process uses
GSSAPI (Apple's Kerberos reads its configuration once), points
`KRB5_CONFIG` and `KRB5CCNAME` at files of its own, gets a ticket with
macOS's `kinit`, and logs in by GSSAPI key exchange, by GSSAPI
authentication, and with no ticket (password fallback). Without Docker
the test says it is skipped and the rest runs.
**Consequences:** The GSSAPI path is tested end to end against MIT
Kerberos and OpenSSH, with Apple's GSS.framework on the client. It found
patch 0023 (each GSSAPI login leaked its MIC). Apple's Heimdal leaks one
authenticator per context it builds; the `leaks` pass excludes
`_krb5_build_authenticator` too. GitHub's macOS runners have no Docker,
so CI skips it; it runs on developer Macs with Docker Desktop. The
developer's own Kerberos configuration and tickets are never used. Not
covered: credential delegation (`GssapiFwd`) on the server side, other
realms or KDCs (Active Directory), a manual check against a real
deployment.
