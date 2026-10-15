# Testing

Status: **M12.** C bridge, core-thread/session, terminal and SSH tests
against local servers, and Swift package tests (including pixel-level
rendering, SSH through a real terminal view, the saved-session store and
the configuration dialog's logic and, since M10, typing into it) exist.

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
| `spb_bridge_test` (ctest) | `Core/tests/spb_bridge_test.c` | Public C API: library info, init/shutdown rules, defaults, normalisation, map editing, 20,000 create/destroy cycles, concurrent sessions, leak counters; PuTTY's character set list and canonical names (M06); the R-3 round-trip self-check over every Conf key (M07). Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_session_test` (ctest) | `Core/tests/spb_session_test.c` | Core thread and executor (M02), against an in-process loopback TCP server: idle loop blocks, PuTTY timers fire in order and never early, Raw echo, input queued before connect, 4 MiB transfer intact, remote close (exit code, then CLOSED), refused connection, unknown host, a serial line that does not exist (since M11; before, Telnet was refused until its milestone), 1,200 release paths (never started, connecting, connected with traffic), 128 sessions driven from 8 threads, descriptors return to baseline, shutdown straight after release. Session log (M05): a new file is written without asking; an existing one with "Ask" raises the log file question (PuTTY's text) and Overwrite / Append / Disable give the expected file and Event Log line; answered after the connection ended, the queued data is still written; released while asking, the file is untouched; "Always overwrite/append" do not ask. `prepare_session`: `user@host:junk`, IPv6 literals, and sessions applying it themselves. Change Settings (M07): export, no-op apply, logging turned on mid-session, transport id unchanged, creation snapshot unchanged, reconfigure after the connection failed. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_terminal_test` (ctest) | `Core/tests/spb_terminal_test.c` | The terminal (M03), with the test holding the server end of a Raw connection: initial frame and default palette; SGR colours (16, bold as colour, 256, true colour, reverse, dim, underline, strikethrough); wide, combining and astral characters; VT100 line drawing; DECDWL; active and passive cursor; OSC title and bell; resize and the application's resize request; scrollback (relative, wheel, Shift-PageUp, to bottom); exact bytes for cursor/keypad keys in normal and application modes, function keys, Backspace, Return, Tab, Meta, typed UTF-8; paste and bracketed paste; drag and double-click selection, right-button paste, Copy All; X11 mouse reporting and wheel; 20,000-line burst coalescing. M06: Ctrl+Shift+C/V type ^C/^V by default; a second session with non-default settings: Linux function keys, rxvt Home/End, Backspace as ^H, Ctrl+Shift+C and Ctrl+Insert copy to the system clipboard, Ctrl+Shift+V and Shift+Insert paste from it, the cursor blinks; M07 live reconfiguration of that session: the window size and live title in the exported settings, Backspace and function keys, the default colour, exactly 10 lines of scrollback. M12: "Use system colours" (set, changed, turned off); remote-controlled printing piped to the printer command and not displayed; Copy as RTF: the selection as runs of equal style (default colours reported as default, bold red bumped to bright red with the bold flag, a background colour, underline), and no styled copy with the setting off. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_ssh_test` (ctest) | `Core/tests/spb_ssh_test.c` | SSH (M04) against `uppity` (D-025): unknown host key dialog (PuTTY's text, fingerprint), Accept stores, Connect Once does not, Cancel ends the session, changed key shows the security warning, closing with the dialog up withdraws it and ignores a stale answer; Change Settings on a live SSH session (M07): SSH-2 reported, a new cipher order re-keys the same connection to ChaCha20, shell still works; port forwarding (M08), all on one connection with the shell checked after each step: local, dynamic (SOCKS5) and remote forwardings added live with their status events, used end to end through a local echo server, removed live (closed status, new connections refused, an established stream keeps working), remote on/off 50 times, a taken local port reported as listen failed, H-1 (remote forwarding added and removed before the reply; use after free without patch 0007) and H-2 (`R` and `4R` on one port; duplicate status; use after free without patch 0008); public-key authentication (M09) against a key-only uppity (`--userkey`, password and keyboard-interactive denied, a banner): an unencrypted key logs in without a prompt and shows the banner, an encrypted key asks for its passphrase in the terminal (wrong, then right; banner off), no key is refused; session operations (M10): SSH-2's Special Commands list (Break, signals, the "More signals" submenu closed, a separator, "Repeat key exchange"), an unlisted command ignored, the listed rekey logged "at user request" on the same connection, Clear Scrollback empties the scrollback, Reset Terminal clears the screen, the close warning (connected, no extra text; not connected after close), Restart ignored while connected, no specials once closed, Restart after a local close and after the remote exit (logged, new transport, shell works), and after a refused connection (fails again); M12: an SSH jump host proxy through a saved session found by the frontend lookup, environment variables reaching the shell, connection sharing (a downstream reuses the upstream, info -1, the close warning "This will also close 1 downstream connection."), manually configured host keys (accepted without the dialog, others refused), the host CA store (save, list, load, key and validity errors, delete), agent authentication and forwarding with a real `ssh-agent` (fixture `userkey.openssh`); login as/keyboard-interactive (silent answer never echoed); configured user name, wrong then right password; shell output; terminal size reaches the remote pty; exit status. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_backends_test` (ctest) | `Core/tests/spb_backends_test.c` | The other backends (M11), each against a peer the test plays itself. Telnet over a loopback socket: active negotiation offers NAWS, TTYPE and DO ECHO; terminal type sent upper-case on SB TTYPE SEND; window size on DO NAWS and after a resize; server echo turns local echo off; Return sends CR LF (Telnet New Line), or CR with it off; a 0xFF data byte is doubled; the Telnet commands menu and "Are You There" sends IAC AYT; server close ends the session CLOSED; passive mode sends nothing until the server negotiates. Rlogin: a source port in 512–1023, the greeting with local and remote user names and terminal type/speed, the first NUL hidden, the server's urgent 0x80 answered with the window size (and again after a resize), the user name asked in the terminal ("rlogin username:") when not configured. SUPDUP: the six 36-bit terminal words (count, type, options with **MORE**, 24 rows, 79 columns, scroll 1), the greeting shown up to %TDNOP, then the location string. Serial, on a pseudo-terminal: opening and line settings logged, 9600 baud applied, data both ways, Change Settings to 19200 changes the open line. Proxies (M12), with the test as the proxy: SOCKS 5 without and with a password, SOCKS 4, HTTP (407, then Basic authorization; patch 0010), the Telnet proxy command, a local proxy command, and the exclusion list. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_link_closure_test` (ctest) | `Core/tests/spb_link_closure_test.c` | Force-loads every core archive member; the build fails on any unresolved symbol (both architectures) |
| `SwiftPuttyKitTests` (Swift Testing) | `Tests/SwiftPuttyKitTests/` | Swift wrapper: bridge loads, licence, core lifecycle, settings conversion (including Unicode), session lifecycle and event streams, core thread, Raw sessions against `TestServers.LoopbackServer` (echo, Unicode, remote close, refused, unknown host, a serial line that does not exist, 100 concurrent sessions, 2 MiB transfer), `SessionController` (state, transcript bound, release on drop); terminal through a real `TerminalView` in a window, driven by `TestServers.ScriptedPeer` (screen contents and colours, title, resize from window size, keyboard via synthesized `NSEvent`s, Option as Meta or not, paste and selection, scrollback, rendering checked pixel by pixel, screen kept after the session ends); key mapping and font parsing; SSH through `TestServers.SSHFixture` and a real `TerminalView` (host key dialog, keyboard-interactive and password logins typed as key events, shell output, window size to remote pty, Cancel); dialog layout (`PuTTYPromptPresentation`, including the log file question's buttons); the log file question through `SessionController`, answered after the connection closed. Saved sessions (M05, temporary directories): Default Settings first and `strcmp` order, empty name is Default Settings, missing sessions load built-in defaults, normalised save/load, delete, mode 0600/0700 and no temporary files left, deterministic versioned format, newer or damaged files reported and never overwritten, settings Codable. Configuration dialog model: starts from Default Settings, port follows the protocol only while it is the default, typing a name selects as PuTTY's binary search, Save under the typed or selected name (beeps with neither), Load, Delete (never Default Settings), double-click opens only saved sessions with a host, Open's "list had the focus" special case, keepalive minutes/seconds, store errors reported, `atoi`, every panel keyword is one PuTTY saves; M06: numeric keypad radio over two keywords, colours (clamped), character classes, bell overload times (microseconds shown as seconds), Meta-key settings saved, character sets. Terminal view options and geometry (border, scrollbar on the left); Ctrl+Shift+C/V key mapping. Change Settings (M07): export / one at a time / apply / cancel through `SessionController`; applied settings reach the terminal (Backspace) and the window (font, border, size) through a real `TerminalView`; the dialog's mid-session rules. Port forwarding (M08): PuTTY's saved format and listening addresses; the Tunnels panel's Add / Remove rules and messages, the H-2 check, edits recorded from Remove-then-Add; staged edits against uppity (a move to a taken port keeps the old forwarding working and is reported, a move to a free port replaces it, a new destination on the same port), remote status and a staged remote move. SSH panels (M09): preference lists reorder and survive PuTTY's normalisation, terminal modes as config.c. Other backends (M11): ports follow the connection type only while default, a serial session needs a line, stop bits in half bits, the `/dev/cu.*` device list, which protocol panels show mid-session, a serial session on a pseudo-terminal through `SessionController` (opening and speed logged, the Break special, typed data reaches the line). Session operations (M10): the Event Log keeps PuTTY's first 128 and latest 127 entries around `..`, timestamps and clipboard lines; against uppity through a real `TerminalView`: the Special Commands tree, rekey from it, the close warning's text, Restart after close (new transport, exit code cleared, logged), Clear Scrollback. Configuration parity (M12): SSH jump host through a saved session (`ProxyTests`), environment variables, manual host keys (`ManualHostKeyTests`), host CAs (`HostCATests`), bold/wide fonts and shadow bold (pixels), system colours following the appearance, resize actions, Copy as RTF (colours, bold font and underline read back from the RTF), and every Conf key of the vendored `conf.h` named in CONFIGURATION_PARITY.md (`ParityTests`). One serialized root suite (D-020); also run under ASan and TSan. `SPB_RENDER_DUMP=<file.png>` saves the rendering test's bitmap |

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
| Swift unit tests | Swift Testing | Saved-session store format and rules, configuration dialog logic (M05); later: format migrations, diff classification, tunnel validation (duplicate listen address rejection) |
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

All six are automated since M08 (`spb_ssh_test` against uppity for 1–5;
staging, 6, in `TunnelTests` through `SessionController`), and 1–4 were
also checked against OpenSSH 10.2 on the LAN.

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
