# Testing

Status: **M04.** C bridge, core-thread/session, terminal and SSH tests
against local servers, and Swift package tests (including pixel-level
rendering and SSH through a real terminal view) exist.

## Running the tests

```sh
scripts/test-all.sh            # everything below
scripts/test-all.sh --clean    # same, from an empty build/ (milestone sign-off)

scripts/build-core.sh --test --asan --tsan   # C core + C tests (+ leaks, ASan/UBSan, TSan)
swift test                                   # Swift package tests (needs build-core first)
swift test --sanitize=address --scratch-path build/swiftpm-asan
swift test --sanitize=thread --scratch-path build/swiftpm-tsan
```

| Suite | Location | What it covers |
|---|---|---|
| `spb_bridge_test` (ctest) | `Core/tests/spb_bridge_test.c` | Public C API: library info, init/shutdown rules, defaults, normalisation, map editing, 20,000 create/destroy cycles, concurrent sessions, leak counters. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_session_test` (ctest) | `Core/tests/spb_session_test.c` | Core thread and executor (M02), against an in-process loopback TCP server: idle loop blocks, PuTTY timers fire in order and never early, Raw echo, input queued before connect, 4 MiB transfer intact, remote close (exit code, then CLOSED), refused connection, unknown host, Telnet refused until its milestone (SSH until M04), 1,200 release paths (never started, connecting, connected with traffic), 128 sessions driven from 8 threads, descriptors return to baseline, shutdown straight after release. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_terminal_test` (ctest) | `Core/tests/spb_terminal_test.c` | The terminal (M03), with the test holding the server end of a Raw connection: initial frame and default palette; SGR colours (16, bold as colour, 256, true colour, reverse, dim, underline, strikethrough); wide, combining and astral characters; VT100 line drawing; DECDWL; active and passive cursor; OSC title and bell; resize and the application's resize request; scrollback (relative, wheel, Shift-PageUp, to bottom); exact bytes for cursor/keypad keys in normal and application modes, function keys, Backspace, Return, Tab, Meta, typed UTF-8; paste and bracketed paste; drag and double-click selection, right-button paste, Copy All; X11 mouse reporting and wheel; 20,000-line burst coalescing. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_ssh_test` (ctest) | `Core/tests/spb_ssh_test.c` | SSH (M04) against `uppity` (D-025): unknown host key dialog (PuTTY's text, fingerprint), Accept stores, Connect Once does not, Cancel ends the session, changed key shows the security warning, closing with the dialog up withdraws it and ignores a stale answer; login as/keyboard-interactive (silent answer never echoed); configured user name, wrong then right password; shell output; terminal size reaches the remote pty; exit status. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_link_closure_test` (ctest) | `Core/tests/spb_link_closure_test.c` | Force-loads every core archive member; the build fails on any unresolved symbol (both architectures) |
| `SwiftPuttyKitTests` (Swift Testing) | `Tests/SwiftPuttyKitTests/` | Swift wrapper: bridge loads, licence, core lifecycle, settings conversion (including Unicode), session lifecycle and event streams, core thread, Raw sessions against `TestServers.LoopbackServer` (echo, Unicode, remote close, refused, unknown host, Telnet not yet available, 100 concurrent sessions, 2 MiB transfer), `SessionController` (state, transcript bound, release on drop); terminal through a real `TerminalView` in a window, driven by `TestServers.ScriptedPeer` (screen contents and colours, title, resize from window size, keyboard via synthesized `NSEvent`s, Option as Meta or not, paste and selection, scrollback, rendering checked pixel by pixel, screen kept after the session ends); key mapping and font parsing; SSH through `TestServers.SSHFixture` and a real `TerminalView` (host key dialog, keyboard-interactive and password logins typed as key events, shell output, window size to remote pty, Cancel); dialog layout (`PuTTYPromptPresentation`). One serialized root suite (D-020); also run under ASan and TSan. `SPB_RENDER_DUMP=<file.png>` saves the rendering test's bitmap |

## Principles

- Tests never contact Internet hosts. All SSH servers are local and
  ephemeral, bound to 127.0.0.1.
- No mocks in production code. Test doubles live only in test targets.
- A milestone is not complete while any test fails.

## Layers

| Layer | Tooling | Examples |
|---|---|---|
| Upstream self-tests | Upstream CMake targets (`testcrypt` + `test/cryptsuite.py`, `test_conf`, `test_tree234`, …) | Run after every upstream update and patch change |
| Bridge C tests | Small C test executables linked against `swiftputty-core` | Create/destroy sessions; settings round-trip over all `conf_key_info[]` keys; overlay preserves `NOT_SAVED` keys; core thread start/stop |
| Swift unit tests | XCTest / Swift Testing | `SessionConfiguration` Codable round-trips and migrations; diff classification; tunnel validation (duplicate listen address rejection) |
| Integration | XCTest driving real sessions against local servers | Connect, host-key accept/reject, password/pubkey/KI auth, resize, Unicode, forwarding |
| Sanitizers | ASan/UBSan builds of bridge + core; TSan for Swift ↔ core-thread hand-off | All integration suites in M13; H-1/H-2 regression tests from M08 |

## SSH server fixtures (D-009, D-025)

1. **PuTTY `uppity` (in use since M04).** Upstream's test server, built
   from the vendored tree by `scripts/build-core.sh`. `spb_ssh_fixture`
   runs it on a Unix-domain socket in a temporary directory and relays a
   loopback TCP port to it (uppity rejects TCP peers on macOS). Any user
   name; password `weasel`; keyboard-interactive `stoat` then `weasel`;
   `/bin/sh` on a pty. Host keys: `Core/tests/fixtures/hostkey-a.ppk`,
   `hostkey-b.ppk` (test-only, not secret). Exit statuses may read 127
   (an uppity pty race; see D-025). The work directory must be short:
   macOS limits Unix socket paths to 104 bytes. Later: fault injection
   (e.g. delayed `tcpip-forward` replies for H-1).
2. **OpenSSH `sshd` (planned for M08/M09).** `/usr/sbin/sshd`, started
   unprivileged per test run: `sshd -D -e -f <tmp>/sshd_config` with
   `ListenAddress 127.0.0.1`, a random high port, generated host keys,
   `AuthorizedKeysFile` pointing at a generated user key,
   `AllowTcpForwarding yes`, `GatewayPorts clientspecified`. For public-key
   authentication and forwarding against a production server.
3. **Manual interoperability check.** Each SSH milestone is also checked
   by hand against a current OpenSSH server on the LAN (M04: OpenSSH 10.2
   on Ubuntu: hybrid post-quantum key exchange, host key dialog, password
   login, pty size, `TERM`, exact exit status). Not automated: tests never
   depend on hosts outside the machine.

Helper processes for forwarding verification: a local TCP echo server, plus
a tiny SOCKS4/5 client in the test target.

## Release-blocking forwarding scenarios

Each runs on **one** SSH session, asserting `spb_session_transport_id`
unchanged and the shell responsive (`echo` round-trip) after every step:

1. connect → add `L<p>` → connect through it → remove → new connections
   refused → established stream still alive → shell alive.
2. connect → add `D<p>` → SOCKS5 and SOCKS4A CONNECT through it → remove →
   refused → shell alive.
3. connect → add `R<p>` → wait for `REMOTE_ENABLED` → server-side connect
   reaches local echo → remove → server-side connect fails → add another
   → change again → repeat ≥ 50 times → no crash, no reconnect.
4. **H-1 regression:** add `R<p>` and remove it before the reply (uppity
   with delayed reply). ASan-clean.
5. **H-2 regression:** configure `R<p>` and `4R<p>`. Expect a validation
   error in Swift and, at the bridge level, an ASan-clean `DUPLICATE`
   status over repeated Applies.
6. Edit staging: change the source port of a live L forward, with the new
   port deliberately occupied → old forward still listening, error surfaced.

## Build matrix

- Debug and Release, arm64 and x86_64 slices.
- CI (`.github/workflows/ci.yml`, GitHub Actions) runs
  `scripts/test-all.sh --clean` on Apple Silicon (`macos-26`) and Intel
  (`macos-26-intel`) runners with Xcode 26.6, on every push to `main`, every
  pull request, and on demand. So each architecture's tests run natively,
  including the sanitizer and leak passes. Failing checks appear as
  annotations on the run; the full log is uploaded as an artifact.
- Clean build at every milestone end.
