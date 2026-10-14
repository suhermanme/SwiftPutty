# Implementation Status

| Milestone | Title | Status |
|---|---|---|
| **M00** | Upstream analysis and architecture | **COMPLETE** (2026-10-14) |
| **M01** | Build skeleton and PuTTY core integration | **COMPLETE** (2026-10-14) |
| **M02** | Session executor and event loop | **COMPLETE** (2026-10-14) |
| **M03** | Terminal rendering foundation | **COMPLETE** (2026-10-14) |
| M04 | Basic SSH session | NOT STARTED |
| M05 | Saved sessions and PuTTY config UI | NOT STARTED |
| M06 | Terminal parity | NOT STARTED |
| M07 | Live session reconfiguration framework | NOT STARTED |
| M08 | SSH tunnels + live tunnel reconfiguration | NOT STARTED |
| M09 | SSH authentication and connection parity | NOT STARTED |
| M10 | Event log and session operations | NOT STARTED |
| M11 | Additional PuTTY backends | NOT STARTED |
| M12 | Configuration parity pass | NOT STARTED |
| M13 | Security and reliability hardening | NOT STARTED |
| M14 | Performance pass | NOT STARTED |
| M15 | macOS productisation | NOT STARTED |
| M16 | Upstream update procedure | NOT STARTED |
| M17 | Release candidate audit | NOT STARTED |

## M03 — Terminal rendering foundation

**Delivered**

- **Terminal on the core thread** (`Core/src/spb_terminal.c`): every
  session owns a PuTTY `Terminal` (with `init_ucs` as GTK PuTTY sets it up
  for a Unicode font) and, while connected, an `Ldisc`. Seat output goes
  to `term_data`, whose backlog throttles the backend. The Seat gains the
  terminal-backed methods (tty modes, cursor position, trust status,
  control-character stripping, pixel size).
- **TermWin → frames** (D-021): draw calls are recorded into a cell grid
  with colours resolved as GTK PuTTY resolves them. Cursor overlays,
  wide and combining characters, DEC double-width/height lines and the
  trust sigil are cell flags. One `terminal_updated` notification per
  frame; `spb_session_read_frame` copies the dirty rows. Scrollbar,
  palette, title, icon title, bell, clipboard write, paste request and
  resize request are forwarded.
- **Input** (`Core/src/spb_input.c`, D-023): keys translated as GTK
  PuTTY's `key_event` with PuTTY's formatters (cursor/keypad application
  modes, function key types, Backspace, Return, Shift-PageUp scrollback,
  Shift-Insert paste, Meta); typed and input-method UTF-8 text with
  inline composition (`term_set_preedit_text`); bracketed paste; mouse
  with Windows PuTTY's button mapping (select/extend/paste, double/triple
  click, rectangular with Option); wheel to the application in mouse
  reporting mode or to the scrollback; scroll, resize, focus, Copy All.
- **Clipboards** (D-022): GTK's `setup_clipboards`; app-private selection
  buffer plus the general pasteboard.
- **Bridge API v3** (`PuTTYBridge.h`): `spb_cell`, `spb_frame_info`,
  `spb_session_read_frame`, the input functions, terminal callbacks,
  `spb_session_set_preedit`.
- **Upstream patch** `0004-terminal-free-last-selected-text.patch` (found by
  `leaks`): `term_free` leaked the local selection buffers. Planned
  patches renumbered again: status hook `0005`, H-1 fix `0006`, H-2 fix
  `0007`.
- **Swift**: `PuTTYSession` terminal events and input methods;
  `TerminalScreen` (frame buffers); `SessionController` forwards terminal
  events to a `SessionTerminalDelegate` and tracks the titles.
- **TerminalUI** (new module): `TerminalView` (AppKit, layer-backed,
  `NSTextInputClient`, scrollbar, mouse, focus, bell incl. visual bell,
  Edit > Copy/Paste, Copy All), `TerminalRenderer` (Core Text: batched
  glyphs in the primary font, Core Text lines for fallback/combining
  text, decorations, cursor overlays, double-size lines),
  `TerminalKeyMapper`, `TerminalFont` (PuTTY `FontName`, whole-point
  cells), `TerminalSessionView` (SwiftUI).
- **App**: launcher form for Raw connections (interim, until the
  configuration dialog in M05); one window per session with PuTTY's title
  behaviour ("host - SwiftPutty", terminal title, "(inactive)"), Close
  window on exit, fatal-error alert, default 80×24 size; Edit > Copy All
  to Clipboard. Debug builds accept `SWIFTPUTTY_DEBUG_OPEN_RAW=host:port`
  to open a session at launch (used for screenshots).

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4):

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| `spb_bridge_test`, `spb_session_test`, `spb_link_closure_test` | Passed |
| `spb_terminal_test` (frames, colours, Unicode, line drawing, double-size lines, cursor, title/bell, resize, scrollback, exact key/paste/mouse bytes, selection and clipboards, mouse reporting, 20,000-line burst) | Passed; the burst renders in about 0.17 s with 7 frame notifications |
| `leaks --atExit`: all three C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan (Debug) | Passed, no reports |
| C tests under TSan (Debug, `halt_on_error=1`) | Passed, no reports |
| `swift test` (43 tests, 11 suites; includes a pixel-level rendering check through a real `TerminalView`) | 43/43 passed; repeated runs stable |
| `swift test --sanitize=address` | 43/43 passed |
| `swift test --sanitize=thread` | 43/43 passed, no reports |
| App Debug build | Succeeded, 0 warnings |
| App Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |
| Manual run of the Debug app against a local Raw server (demo screen + shell on a PTY), screenshot-checked | 16/256/true colours, bold as colour, attributes, Cyrillic, CJK, emoji, combining, double-width/height lines, window title from OSC, window opens at 80×24, terminal fills the window |

**Problems found and fixed during M03**

- Paint-time re-entrancy: PuTTY calls `set_scrollbar` and other TermWin
  methods inside a paint, while the screen lock is held. These now record
  their change under the held lock (no recursive locking).
- Upstream frontends must register their selection clipboards with each
  Terminal (`setup_clipboards`); without it, selection copied nothing.
- Focus changes need an explicit `term_update` (as GTK's focus handler).
- Core Text: `CTFontDrawGlyphs` uses the context's text matrix and text
  position, which `CTLineDraw` advances; glyphs came out mirrored or
  displaced until both were set explicitly per path. Caught by the
  pixel-level rendering test.
- Upstream leak in `term_free` (patch `0004`).
- The terminal answers control sequences in binary test payloads (e.g.
  ENQ, DA), so transfer tests now use printable data.
- Test races: the loop-iteration and descriptor diagnostics were sampled
  at the wrong moment under sanitizer timing. `spb_debug_uxsel_fds` now
  counts on the core thread; the iteration test uses two barriers.
- App: the terminal is resized when the session appears after layout;
  the terminal view takes keyboard focus when its window opens.

**Limitations / not done**

- Only Raw connections, from an interim launcher form; SSH is M04, the
  configuration dialog M05.
- Not visually verified: keyboard focus in the running app (the launch
  environment keeps focus in the terminal that started it), the Edit menu
  Copy/Paste, the scrollbar by mouse, IME composition. These paths are
  covered by automated tests through a real `NSWindow`/`NSEvent`, except
  menu routing and IME.
- Server-driven window operations (move, minimise, raise) are ignored;
  resize requests resize the window. Terminal-parity work (M06) covers
  the remaining keyboard options (e.g. Ctrl+Shift+C/V, Alt-numpad codes),
  bell options (wave file), blinking-text timing checks and printing.
- No flow control between the main thread and the terminal beyond
  PuTTY's own backlog (M14).
- arm64 slice built and linked; tests not run (x86_64 host).

## M02 — Session executor and event loop

**Delivered**

- **PuTTY core thread** (`Core/src/spb_eventloop.c`, D-003): one thread
  per process (`org.swiftputty.putty-core`), started by `spb_core_init`
  and joined by `spb_core_shutdown`. Its loop is upstream's
  `cli_main_loop` (`unix/cliloop.c`) plus a non-blocking self-pipe and a
  locked FIFO command queue. All PuTTY code runs on this thread.
- **Session executor** (`Core/src/spb_session.c`): sessions own their
  `Conf`, `LogContext` and `Backend`. `start`, `send`, `send_eof`, `close`
  and `release` are asynchronous and run in call order. The connection
  lifecycle follows GTK PuTTY (`start_backend`, `exit_callback`,
  `connection_fatal_callback`, `destroy_inst_connection`). States:
  `CREATED → CONNECTING → CONNECTED → CLOSED | FAILED` (D-018).
  Release is non-blocking and ends with a `released` callback (D-017).
  Only the Raw protocol starts in M02 (D-019).
- **Seat and LogPolicy** (`Core/src/spb_seat.c`): GTK PuTTY's choices
  where no terminal or dialog is needed. Output, Event Log, remote exit
  and fatal errors are forwarded. Interactive prompts are refused with a
  message naming the milestone that adds them.
- **Bridge API v2** (`PuTTYBridge.h`): see ARCHITECTURE §10 for the
  differences from the §7 proposal. New diagnostics: core barrier, watched
  descriptor count, loop iterations, PuTTY-timer probe.
- **Upstream patches** (found by the M02 tests, both suitable for
  upstream):
  - `0002-pollwrap-hup-wakes-writers.patch`: on macOS a refused
    non-blocking `connect()` shows up in `poll()` as `POLLHUP` only, which
    pollwrap ignored for writers. The loop spun at 100% CPU and the
    failure was never reported. Unpatched upstream `plink -raw` to a
    closed local port shows the same: 100% CPU, never exits.
  - `0003-network-free-connect-error-message.patch`: each failed
    asynchronous connection attempt leaked its error text.
  - Planned patches renumbered: status hook `0004`, H-1 fix `0005`, H-2
    fix `0006` (renumbered again in M03).
- **Swift** (`Sources/PuTTYBridge`): `PuTTYSession` (replaces
  `PuTTYSessionHandle`) delivers `PuTTYSessionEvent`s on an `AsyncStream`
  that finishes after teardown. `PuTTYCore` gains `isCoreThread`,
  `waitForPendingWork()` and diagnostics.
- **SessionLayer** (`Sources/SessionLayer`): `SessionController`,
  `@MainActor @Observable`. It holds state, detail, Event Log, a 1 MiB
  output transcript (until the terminal exists) and the exit code.
- **Tests**: new `spb_session_test` (C); Swift tests merged into one
  serialized target `SwiftPuttyKitTests` (D-020) with a loopback server
  helper (`Sources/TestServers`). `build-core.sh --tsan` and Swift TSan are
  now part of `test-all.sh`.
- **App**: the launcher reports the core thread. No session UI yet.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4):

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| `spb_bridge_test` | Passed |
| `spb_session_test` (core thread, timers, Raw echo, 4 MiB transfer, remote close, refused, unknown host, protocol gating, 1,200 release paths, 128 sessions from 8 threads, descriptor baseline, shutdown after release) | Passed (about 1 s) |
| `spb_link_closure_test` | Passed |
| `leaks --atExit`: `spb_bridge_test`, `spb_session_test` | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan (Debug) | Passed, no reports |
| C tests under TSan (Debug, `halt_on_error=1`) | Passed, no reports |
| `swift test` (30 tests, 8 suites) | 30/30 passed; also 5 consecutive repeat runs, all passed |
| `swift test --sanitize=address` | 30/30 passed |
| `swift test --sanitize=thread` | 30/30 passed, no reports |
| App Debug build | Succeeded, 0 warnings |
| App Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |
| Manual launch of the Release app | Core thread present and idle in `poll()`; quits cleanly (thread joined); no crash reports |

**Problems found and fixed during M02**

- Lost wake-up in the first version of the self-pipe: the "wake pending"
  flag was cleared before the pipe was drained, so a concurrent wake byte
  could be swallowed while the flag stayed set. The loop then slept
  forever. The 20,000-session C test caught it. The pipe is now drained
  first and the flag cleared after.
- The upstream `pollwrap` spin and the `network.c` leak (patches `0002`,
  `0003`, above).
- A failed `backend_init` still hands back a backend for the frontend to
  free (as GTK PuTTY does). The first version dropped it and leaked it.
- Swift suites in two test targets ran in parallel in one process and
  broke assertions on process-wide counters. Fixed by D-020.

**Limitations / not done**

- No terminal: output is delivered as raw bytes, and the Ldisc is not
  created yet (M03/M04). Only Raw sessions start; SSH arrives in M04.
- No flow control from the Swift side back to the connection: received
  output is buffered without limit until consumed (M14).
- R-2 is unchanged: a slow DNS lookup blocks the core thread for every
  session. The main thread never waits on the core thread (D-017).
- The repository directory was renamed since M01 (`swift_putty` →
  `SwiftPutty`). Generated build directories from the old path were
  removed; the clean build above starts from scratch.
- arm64 slice built and linked; its tests have not been run (x86_64 host).
- The launcher's extra "Core thread" row was build-verified, not
  screenshot-verified.

## M01 — Build skeleton and PuTTY core integration

**Delivered**

- **Core build** (`scripts/prepare-putty-src.sh`, `scripts/build-core.sh`,
  `Core/cmake/`): PuTTY 0.85 plus the bridge, built inside upstream's
  unmodified CMake build via the documented project-include hook (D-010).
  Each architecture is configured separately and the slices are combined
  into a universal `build/SwiftPuttyCore.xcframework` (D-006, D-012).
  Hardware crypto is present in both slices.
- **Patch infrastructure** (`patches/`): the first local patch,
  `0001-arm-arch-queries-sysctl-fallthrough.patch`, fixes a real upstream
  defect that surfaced as a compiler warning.
- **C bridge** (`Core/include/PuTTYBridge.h`, `Core/src/`):
  - library version, SSH version and licence text (from upstream's generated
    `licence.h`);
  - once-per-process core init/shutdown (D-013): private state directory,
    `$PUTTYDIR` redirection, `sk_init`, `uxsel_init`;
  - the settings document, converted through upstream's
    `load_open_settings`/`save_open_settings`;
  - session objects owning a PuTTY `Conf`;
  - diagnostics counters;
  - every frontend-provided symbol the core needs (platform defaults, error
    reporting, X display, sharing flags, event-loop notification hooks,
    `storage.h` session half; D-011).
- **Swift package** (`Package.swift`, `Sources/PuTTYBridge`):
  `PuTTYCore`, `PuTTYSettings` (Sendable value type), `PuTTYSessionHandle`.
- **App** (`App/SwiftPutty.xcodeproj`, `App/SwiftPutty/`):
  - SwiftUI `@main` app with an app delegate that starts the core at launch
    and shuts it down at exit;
  - a launcher window reporting core status, with failures shown, not
    crashed on;
  - an About window with the PuTTY licence (from the bridge) and
    `THIRD_PARTY_NOTICES.md`, plus the PuTTY `LICENCE` bundled as a
    resource;
  - quits when the last window closes, as PuTTY does;
  - hardened runtime, ad-hoc signing, Swift 6, warnings as errors;
  - universal Release build (`scripts/build-app.sh`).
- **Test runner** `scripts/test-all.sh [--clean]`.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4):

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| `spb_bridge_test` (library info, init rules, defaults, normalisation, 20,000 session create/destroy cycles, 256 concurrent sessions, shutdown rules) | Passed |
| `spb_link_closure_test` (every archive member force-loaded; built for both architectures) | Passed |
| `spb_bridge_test` under `leaks --atExit` | 0 leaks, 0 bytes |
| C tests under ASan + UBSan (Debug) | Passed, no reports |
| `swift test` (14 tests, 5 suites: bridge loads, licence, core lifecycle, settings conversion including Unicode, 10,000 session create/destroy cycles, 500 concurrent sessions) | 14/14 passed |
| `swift test --sanitize=address` | 14/14 passed |
| App Debug build | Succeeded, 0 warnings |
| App Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |
| Manual launch of the Release app | Launcher shows core "Running"; state directory created with mode 0700; clean quit; no crash reports |

**Problems found and fixed during M01**

- Settings without `Protocol` loaded as raw/port 0. The bridge was missing
  the `settings_set_default_protocol/port` initialisation every upstream
  frontend performs.
- `dsymutil` dropped debug info for same-named upstream objects (D-015).
- Hardware-crypto object libraries were initially missing from the archive.
  They are now collected generically.
- `ssh/ca-config.c` (portable dialog code) is excluded from the archive.
  Found by the new link-closure test.

**Limitations / not done**

- No event loop or core thread yet (done in M02).
- `nonfatal` and `old_keyfile_warning` go to the unified log only. UI
  surfacing comes with the Event Log (M10) and auth work (M09).
- The arm64 slice is built and linked, but its tests have not been *run*.
  This host is x86_64.
- The About window was build-verified and its licence source is tested,
  but it was not visually checked, because UI automation permissions are
  unavailable here. The launcher window was screenshot-verified.
- GPG verification of the upstream tarball is still pending (no `gpg` on
  this host).

## M00 — Upstream analysis and architecture

**Delivered**

- `Vendor/putty/`: pristine PuTTY 0.85 release source (SHA-256 verified
  against upstream `sha256sums`; GPG signature not yet verified).
- `docs/ARCHITECTURE.md`: upstream component map; the Change Settings →
  `backend_reconfig` → `portfwdmgr_config` call flow with file:line
  citations; local/remote/dynamic forwarding internals; the event/timer/
  callback model; the proposed threading model; the proposed C bridge API
  (`PuTTYBridge.h`); runtime-config architecture; risks.
- `docs/UPSTREAM_PUTTY.md`: pin, minimum source subset, build integration,
  planned patches, update procedure.
- `docs/CONFIGURATION_PARITY.md`: every Windows 0.85 dialog setting, with
  planned macOS mapping and runtime classification derived from upstream.
- `docs/DECISIONS.md`: D-001 … D-009.
- `docs/TESTING.md`: test strategy and fixtures.
- `THIRD_PARTY_NOTICES.md`, `README.md`.

**Verification performed**

- Unmodified 0.85 configured with `-DPUTTY_GTK_VERSION=NONE`. Built
  `plink`, `testcrypt` and `test_conf` as a universal binary (outside the
  repo, in a scratch directory). `lipo -info plink` → `x86_64 arm64`;
  `plink -V` → `Release 0.85`.
- Per-architecture configure confirmed that HW-crypto feature probes
  succeed only in single-arch configures (D-006).
- Upstream git history checked for forwarding fixes after 0.85.

**Not done (by design, M00 is analysis only)**

- No application, bridge or patch code written.
- Upstream hazards H-1/H-2 are identified by code reading only and **not yet
  reproduced**. Reproduction under ASan is an M08 entry criterion.

**Open items carried forward**

- Verify the GPG signature of `putty-0.85.tar.gz` (needs `gpg` and the
  PuTTY release key).
- arm64 tests need Apple Silicon hardware. This build host is x86_64.
- R-2 (shared core thread vs blocking DNS) to be measured by M14.
