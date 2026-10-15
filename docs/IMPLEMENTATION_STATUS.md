# Implementation Status

| Milestone | Title | Status |
|---|---|---|
| **M00** | Upstream analysis and architecture | **COMPLETE** (2026-10-14) |
| **M01** | Build skeleton and PuTTY core integration | **COMPLETE** (2026-10-14) |
| **M02** | Session executor and event loop | **COMPLETE** (2026-10-14) |
| **M03** | Terminal rendering foundation | **COMPLETE** (2026-10-14) |
| **M04** | Basic SSH session | **COMPLETE** (2026-10-14) |
| **M05** | Saved sessions and PuTTY config UI | **COMPLETE** (2026-10-15) |
| **M06** | Terminal parity | **COMPLETE** (2026-10-15) |
| **M07** | Live session reconfiguration framework | **COMPLETE** (2026-10-15) |
| **M08** | SSH tunnels + live tunnel reconfiguration | **COMPLETE** (2026-10-15) |
| **M09** | SSH authentication and connection parity | **COMPLETE** (2026-10-15) |
| **M10** | Event log and session operations | **COMPLETE** (2026-10-15) |
| **M11** | Additional PuTTY backends | **COMPLETE** (2026-10-15) |
| **M12** | Configuration parity pass | **COMPLETE** (2026-10-15) |
| **M13** | Security and reliability hardening | **COMPLETE** (2026-10-15) |
| M14 | Performance pass | NOT STARTED |
| M15 | macOS productisation | NOT STARTED |
| M16 | Upstream update procedure | NOT STARTED |
| M17 | Release candidate audit | NOT STARTED |

## M13 — Security and reliability hardening

Scope agreed at the start of the milestone: the proxy password in the
keychain, a review of local commands (and the pre-connect command
enabled), fuzzing, audits (R-7, passwords in logs, the upstream GPG
signature), reliability stress tests, and GSSAPI on macOS.

**Delivered** (bridge API v12)

- **Proxy password in the keychain** (D-040): never written to the
  sessions file; moved there from older files when a session loads; a
  keychain failure leaves the file untouched.
- **Local commands reviewed** (D-041): `posix_spawn` with only the
  command's own pipes, signals reset (patch 0015); every command reaped
  by a per-pid waiter (`spb_subprocess.c`) instead of upstream's
  process-wide SIGCHLD handler and `waitpid(-1)`; writes to an exited
  command no longer raise SIGPIPE (patch 0022). **Command to run before
  connection** is offered on the Connection panel; upstream exposed the
  proxy password through `%pass` and wiped the session's proxy
  credentials (patch 0014).
- **Fuzzing** (D-042): `spb_fuzz_terminal` (server output through the
  whole terminal path, frames and RTF copy) and `spb_fuzz_parsers` (host
  keys, CA keys and expressions, every saved and legacy keyword), run
  briefly by ctest in every build, plus a Swift test of 500 mutated
  sessions files. Upstream bugs found and fixed: a malformed colour
  aborted (0016); **a short Ed25519/Ed448 point aborted while decoding a
  server's host key, before verification** (0017: a malicious server
  could end every session of the app); out-of-range `BugHMAC2` and an
  uninitialised proxy type (0018); a negative scrollback size aborted
  (0019); copying combining characters read uninitialised attributes
  (0020).
- **Audits**: R-7 closed (unreachable on Unix; ARCHITECTURE.md §11);
  session logs never hold a typed password, in any log type (with a
  control run that proves the check sees one); the vendored source
  verified against PuTTY's GPG signature and key chain
  (`scripts/verify-upstream.sh`).
- **Reliability**: reset mid-transfer, file descriptor exhaustion, 32
  busy sessions released and the core shut down at once, an unwritable
  sessions directory.
- **GSSAPI on macOS** (D-043, patch 0021): `GSS.framework` and
  `libgssapi_krb5.dylib` load with every function bound; logins with
  GSSAPI on are not delayed. **Tested end to end** (D-044) against a
  Kerberos realm in Docker: GSSAPI key exchange, GSSAPI authentication,
  and the password fallback without a ticket; found patch 0023 (each
  GSSAPI login leaked its MIC).

**Tests and results**

Clean build, `scripts/test-all.sh --clean`, arm64 host, Xcode 27.0 /
Swift 6.4 / CMake 4.4.3.

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo), patches 0001–0023 | PASS |
| C tests (8 programs, including `spb_fuzz_terminal` and `spb_fuzz_parsers`); new: pre-connect command and reaping, logs without passwords, short Ed25519 key, GSSAPI libraries and timing, Kerberos logins (Docker), reset mid-transfer, SIGPIPE from a local command, descriptor exhaustion, busy shutdown | PASS |
| `leaks --atExit`: the five C test programs | PASS (0 leaks of ours; Apple's Heimdal `krb5_get_credentials` / `_krb5_build_authenticator` excluded in `spb_ssh_test`, D-043/D-044) |
| C tests under ASan + UBSan / TSan (Debug) | PASS |
| Longer fuzzing by hand: 550,000 parser inputs (100,000 under ASan+UBSan), 9,000 terminal inputs under ASan+UBSan | PASS after patches 0016–0020 |
| `swift test` (122 tests, 27 suites; new: keychain and secret store, mutated and unwritable sessions files) | PASS |
| `swift test --sanitize=address` / `--sanitize=thread` | PASS |
| App Debug build; Release build, universal | PASS |
| `scripts/verify-upstream.sh` (network) | PASS: good signature by PuTTY's release key; archive identical to `Vendor/putty` |

- **Clicked through by hand** (Debug app, driven by AppleScript UI
  scripting, screenshots checked; 2026-10-15): Connection panel's
  pre-connect command saved, and run before a real connection (marker
  file written); the proxy password saved to the keychain and absent
  from the sessions file, reloaded after relaunch; the GSSAPI list's
  macOS names; manual host keys (invalid key and duplicate refused with
  PuTTY's messages); the host CA window (bad key refused with the live
  "Cannot decode key" line, a bad expression refused with the parser's
  message, save and delete); Copy All with Copy as RTF on: plain text
  and RTF on the pasteboard, pasted into TextEdit with colours,
  underline and background; Ctrl+right-click opens the window menu,
  and its items act on the session (New Session, Event Log); closing a
  connected session asks first. **Fixed:** the context menu showed
  Duplicate Session, Change Settings, Event Log, Clear Scrollback and
  Reset Terminal disabled (SwiftUI updates its items' state only when
  their menu opens) and macOS added "AutoFill"; the source menus are now
  updated first, the copies keep that state, and plug-ins are off.
- **Clicked through by hand** (2026-10-16; Raw session to a local
  server that turns on mouse reporting): in Compromise mode a plain
  right-click goes to the application as a mouse report and opens no
  menu; Change Settings from the Ctrl+right-click menu, Selection panel,
  "Windows" and Apply: a plain right-click then opens the menu, and
  nothing reaches the application, though it still has the mouse.

**Limitations / not done**

- The Kerberos test needs Docker: CI's macOS runners skip it. GSSAPI
  delegation on the server side is not tested. X11 rows stay PARTIAL.
- The fuzzing driver is not coverage-guided; a libFuzzer campaign with
  an LLVM toolchain (`-DSPB_LIBFUZZER=ON`) is left for M17.
- Developer builds are ad-hoc signed, so macOS may ask once per rebuild
  before the app reads its keychain items (D-040; M15 signs properly).
- Patches 0010–0023 are not yet reported upstream. **0017 should be
  reported privately** (a server can abort the client).
- From reading `unix/network.c` (not tested): a forwarding listener whose
  `accept()` fails while descriptors are exhausted stays readable, so
  the loop would retry it every iteration until descriptors free up, as
  upstream does. Not changed.

## M12 — Configuration parity pass

**Delivered** (bridge API v11)

- **Connection/Proxy**: every field, in upstream's type order. SOCKS 4/5,
  HTTP, Telnet command and local command proxies, with exclusions, all
  upstream code. **SSH jump hosts** through saved sessions: the core asks
  the frontend's store by name (`spb_core_set_saved_session_lookup`,
  D-036), so PuTTY's `do_defaults(name)` sees SwiftPutty's sessions.
- **Connection/Data**: environment variables. **SSH**: protocol
  version, connection sharing (with the upstream's close warning),
  manually configured host keys, and a **host CA** window over upstream's
  storage (`spb_hostca.c`, D-037; `ca-config.c` not linked).
- **Agent authentication and agent forwarding** tested with a real
  `ssh-agent`.
- **Terminal/Window**: printer (an `lpr -P` command per macOS printer),
  "Action of mouse buttons" with the terminal's context menu (D-038),
  bold/wide/bold-wide fonts and shadow bold, variable-pitch font filter,
  "Use system colours" following light/dark mode, "When window is
  resized" and the full-screen scrollbar, and **Copy as RTF**: the bridge
  hands over styled runs as `win_clip_write` decides them and the view
  writes RTF beside the text (D-039).
- **Upstream patches**: 0010 (an HTTP proxy's blank line ending the
  headers waited for another byte: a 407 stalled and client-first
  protocols hung after a 200); 0011 (every proxied connection leaked its
  Conf); 0012 (Telnet and local proxy commands were formatted twice,
  leaking the first, which can hold the proxy password); 0013 (the proxy
  negotiator's `reconnect` flag was never initialised; found by UBSan).
  0011 and 0012 were found by `leaks --atExit`.
- **Parity document checked**: `ParityTests` fails if any Conf key of
  the vendored `conf.h` is missing from CONFIGURATION_PARITY.md.
- `spb_ssh_test`: the encrypted-key steps allow 90 s, since Argon2 under
  TSan overran 20 s once on a loaded host.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, arm64
host, Xcode 27.0 / Swift 6.4 / CMake 4.4.3)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo), patches 0001–0013 | PASS |
| C tests: `spb_backends_test` proxies (SOCKS 4/5, HTTP 407 then Basic, Telnet and local commands, exclusions); `spb_ssh_test` jump host, environment, connection sharing, manual host keys, host CAs, agent; `spb_terminal_test` system colours, printing, Copy as RTF | PASS (6 programs) |
| `leaks --atExit`: all five C test programs | PASS (0 leaks) |
| C tests under ASan + UBSan / TSan (Debug) | PASS |
| `swift test` (116 tests, 27 suites; new: `ParityTests`, `ProxyTests`, `ManualHostKeyTests`, `HostCATests`, fonts and shadow bold, system colours, resize actions, Copy as RTF) | PASS |
| `swift test --sanitize=address` / `--sanitize=thread` | PASS |
| App Debug build; Release build, universal | PASS |

**Limitations / not done**

- **Not clicked through by hand** in this milestone: the new panels,
  the context menu and the host CA window are covered by the tests
  above only.
- **Command to run before connection** (`PreConnectCommand`) is not
  offered: it runs a local command and is left for M13's security review.
- **Proxy password** is saved in the session file in plain text, as
  PuTTY does; keeping it out of the file (Keychain) is planned for M13.
- GSSAPI and X11 forwarding stay PARTIAL (no Kerberos or XQuartz here).
- Patches 0010–0013 are not yet reported upstream.

## M11 — Additional PuTTY backends

**Delivered**

- **Every Unix backend starts**: SSH, Serial, Telnet, Rlogin, SUPDUP and
  Raw, all upstream code. Their Special Commands come through M10's menu
  (Telnet's commands, serial Break).
- **Core loop waits with `select()`** (D-035): macOS's `poll()` never
  reports TCP urgent data, so Rlogin servers' window size requests (and
  Telnet SYNCH) were lost; found by the Rlogin test, and unpatched
  upstream would behave the same on macOS.
- **Patch 0009**: upstream leaked the "rlogin username:" prompt once
  answered (found by `leaks --atExit`).
- **Configuration dialog**: Session panel radio buttons SSH / Serial /
  Other: (Telnet, Rlogin, SUPDUP, Raw), in upstream's order; for Serial
  the host and port boxes are "Serial line" (with a menu of `/dev/cu.*`)
  and "Speed". Connection/Serial (line hidden mid-session; speed, data
  bits, stop bits in half bits, parity and flow control as the Unix
  backend offers them), Connection/Telnet, Connection/Rlogin and
  Connection/SUPDUP panels, with config.c's mid-session rules (now on
  the model as `shows(_:)`, tested).
- Fixed-point edit boxes format as config.c does (`%g`), which stop bits
  (denominator 2) need.
- **Clicked through by hand** (Debug app; screenshots checked): SSH /
  Serial / Other: Telnet radio buttons; Serial turns the boxes into
  "Serial line" and "Speed" (9600), the device menu lists
  `/dev/cu.Bluetooth-Incoming-Port` and fills the line; the Serial,
  Telnet, Rlogin and SUPDUP panels with PuTTY's defaults; Other: Telnet
  moves the port to 23. A Telnet session to a local test peer: greeting
  shown, server echo (text appears once), typing sent character by
  character, Return as CR LF; Special Commands lists Telnet's commands
  and "Are You There" reaches the peer (IAC 246); Change Settings lists
  Connection > Telnet only, with just the two live options, and turning
  off Telnet New Line makes Return send CR NUL at once.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo), patches 0001–0009 | PASS |
| C tests: new `spb_backends_test` (Telnet active and passive, Rlogin incl. urgent window size request and user name prompt, SUPDUP, serial on a pty incl. live speed change); `spb_session_test` now checks a missing serial line | PASS (6 programs) |
| `leaks --atExit`: all five C test programs | PASS (0 leaks) |
| C tests under ASan + UBSan / TSan (Debug) | PASS |
| `swift test` (107 tests, 22 suites; new: connection types and ports, serial launchability, stop bits, `/dev/cu.*` list, mid-session panels, a serial session through `SessionController`) | PASS |
| `swift test --sanitize=address` / `--sanitize=thread` | PASS |
| App Debug build; Release build, universal | PASS |

**Limitations / not done**

- No real serial hardware tried; the serial backend is tested on a
  pseudo-terminal (termios settings, speed changed live, data both
  ways). Hardware flow control and parity on a real line are untested.
- Telnet, Rlogin and SUPDUP are tested against peers the test plays
  itself, not against real servers (none is installed here).
- Errors from a live serial reconfiguration are discarded, as upstream
  does (its FIXME); the Event Log shows what was configured.
- Connection/Proxy and the Data panel's environment variables remain
  (M12).

## M10 — Event log and session operations

**Delivered**

- **Bridge API v9** (D-034): Restart Session (after the connection
  ends; logged, terminal reset, same window and scrollback), Special
  Commands (the backend's list, reported as it changes; only listed
  commands run), the close-warning query (upstream `close_warn_text`),
  Clear Scrollback, Reset Terminal, and PuTTY's non-fatal errors as a
  callback (the "SwiftPutty Error" box).
- **Event Log window**, one per session, as GTK PuTTY's: the first 128
  entries and the latest 128 with `..` at the gap, timestamped when
  logged, multiple selection copied as "time<TAB>event" lines; it closes
  with its session window.
- **Session menu** in GTK PuTTY's order: Restart Session, Duplicate
  Session (running settings), Saved Sessions (opens the session, or the
  configuration dialog if it has no destination), Change Settings…,
  Event Log, Special Commands (with submenus; hidden without a
  connection), Clear Scrollback, Reset Terminal.
- **Warn before closing window** (Behaviour panel): closing a connected
  window asks "SwiftPutty Exit Confirmation" (Yes / No); ⌘Q asks once
  for all such windows.
- `scripts/build-app.sh Debug` fixed (empty array under `set -u`).
- **Clicked through by hand** (Debug app against uppity, driven with
  System Events and real mouse events; screenshots checked): the
  Session menu in GTK's order, Restart disabled while connected;
  Special Commands with "More signals" and separators, and "Repeat key
  exchange" logged "at user request"; the Event Log window (timestamps,
  Shift-click selection, ⌘A / ⌘C give "time<TAB>event" lines, Close);
  ⌘W on a connected window asks, No keeps it and Yes closes it;
  Duplicate Session opens a second connection; after `exit 5` the
  window is "(inactive)", Restart is enabled and Special Commands
  hidden, and Restart reconnects in the same window with the scrollback
  kept; Clear Scrollback and Reset Terminal; Saved Sessions shows
  "(No sessions)", updates as soon as a session is saved, and opens it;
  ⌘Q asks once ("these 2 sessions"; one session: "this session"), No
  keeps the app, Yes quits, and nothing is asked with nothing connected.
- Found while clicking through, and fixed: in Debug builds the
  `SWIFTPUTTY_DEBUG_OPEN_*` aid ran every time the configuration dialog
  appeared, closing it mid-appearance; the reopened dialog then showed
  typed values without storing them (a typed port was saved as 22). It
  now runs once per launch. Release builds never had the aid. A test now
  types into the real dialog through AppKit's field editor.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | PASS |
| C tests (`spb_ssh_test` adds: specials list, user rekey, Clear Scrollback, Reset Terminal, close warning, Restart after close / remote exit / refused connection) | PASS |
| `leaks --atExit`: all four C test programs | PASS (0 leaks) |
| C tests under ASan + UBSan / TSan (Debug) | PASS |
| `swift test` (101 tests, 21 suites; new: Event Log bounds and format, Special Commands tree and rekey, close warning, Restart, Clear Scrollback, typing host and port into the real dialog) | PASS |
| `swift test --sanitize=address` / `--sanitize=thread` | PASS |
| App Debug build; Release build, universal | PASS |

**Limitations / not done**

- Saved Sessions and Duplicate Session are checked by hand only (no
  automated test); a saved session with no destination opening the
  configuration dialog was not tried.
- The non-fatal error path is not exercised (upstream reaches it only
  through an SSH proxy connection).
- No terminal context menu (GTK's Ctrl+right-click); the menu bar has
  every item.
- `old_keyfile_warning` still goes to the unified log only.

## M09 — SSH authentication and connection parity

**Delivered**

- **Public-key authentication** from PPK files, unencrypted or with a
  passphrase (asked in the terminal, as PuTTY does), the pre-auth banner,
  and the other authentication options, all through upstream code (D-033).
- **The remaining SSH panels**, as config.c: Kex, Host keys and Cipher
  (preference lists with Up / Down and the warn-below line; rekey limits;
  shown mid-session for SSH-2), Auth, Credentials (key file and
  certificate with Browse…, auth plugin), GSSAPI, TTY (no pty; terminal
  modes with Auto / Nothing / This: and Set), X11, Bugs and More bugs.
  The tree is now PuTTY's full SSH subtree.
- **Test fixture**: `spb_ssh_fixture` passes options to uppity; test user
  keys (`Core/tests/fixtures/userkey*.ppk`, `userkey.pub`) made with
  upstream `puttygen`, committed, not secret.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | CLEAN_CORE |
| C tests (`spb_ssh_test` adds key-only uppity: key login with banner, passphrase key wrong then right with banner off, no key refused) | CLEAN_C |
| `leaks --atExit`: all four C test programs | CLEAN_LEAKS |
| C tests under ASan + UBSan / TSan (Debug) | CLEAN_SAN |
| `swift test` (96 tests, 18 suites; new: preference lists, terminal modes; every new panel keyword checked against PuTTY's saved settings) | CLEAN_SWIFT |
| `swift test --sanitize=address` / `--sanitize=thread` | CLEAN_SWIFT_SAN |
| App Debug build; Release build, universal | CLEAN_APP |

**Limitations / not done**

- Not tested end to end: authentication through an SSH agent, agent
  forwarding, X11 forwarding (needs XQuartz). The settings reach PuTTY.
- GSSAPI is unavailable on macOS as upstream stands (its Unix library
  loader looks for `.so` names); the settings are kept (M13/M15).
- Manually configured host keys and the host CA manager are not done
  (M12).
- No manual check against the LAN server this milestone (it would need
  the test key in the server's `authorized_keys`).
- New panels not clicked through by hand; checked by build and tests.

## M08 — SSH tunnels + live tunnel reconfiguration

**Delivered**

- **Upstream bugs H-1 and H-2 reproduced, then fixed** (D-032): under
  AddressSanitizer, removing a remote forwarding before the server has
  answered was a use after free in `ssh2_rportfwd_globreq_response`
  (freed in `ssh2_rportfwd_remove`), and a duplicate remote forwarding
  left a freed record that the next `portfwdmgr_config` used. Patches
  `0007` and `0008` fix them; `0007` also frees the queue of unanswered
  global requests at teardown (an upstream leak). The reproductions stay
  as regression tests.
- **Structured forwarding status** (patch `0006`, bridge API v8
  `portfwd_status`): listening, listen failed (with PuTTY's reason),
  remote requested / enabled / refused, duplicate, closed, keyed by the
  exact `PortForwardings` entry.
- **Tunnels in the configuration dialog**: Connection/SSH (remote command,
  no shell, compression; mid-session as config.c) and Connection/SSH/
  Tunnels as PuTTY's (accept-all options, list, Remove filling the fields,
  Add, Local / Remote / Dynamic, Auto / IPv4 / IPv6, PuTTY's messages),
  plus a refusal of a second remote forwarding on the same server port.
  Mid-session each forwarding shows its live state.
- **Live edits, staged** (ARCHITECTURE §6.4): Remove-then-Add is recorded
  as an edit. A forwarding moved to another listening address is added
  before the old one is removed, and the old one stays if the new one
  fails; one changed on the same address is replaced and put back on
  failure. The user is told what was kept. Plain adds and removes behave
  exactly as in PuTTY.
- **Swift**: `PortForwarding` (PuTTY's saved format, kinds, listening
  addresses), `PortForwardStatus`, `PortForwardingEdit`;
  `SessionController.portForwardStatuses`,
  `applyChangeSettings(_:portForwardingEdits:)`, `lastPortForwardingReport`.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| H-1 / H-2 reproduced before the fixes (ASan, `spb_ssh_test`) | Use after free in `ssh2_rportfwd_globreq_response`; then, with 0007 only, in `portfwdmgr_config` after the duplicate branch |
| C tests (`spb_ssh_test` adds: L / D / R forwardings added live and used end to end, status events, removed live with an established stream kept, R on/off 50 times, listen failure on a taken port, H-1, H-2; shell and transport id checked throughout) | Passed |
| `leaks --atExit`: all four C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan / TSan (Debug) | Passed, no reports |
| `swift test` (94 tests, 18 suites; new: saved format, listening addresses, Tunnels panel rules, edit pairs, staged edits against uppity incl. a move to a taken port keeping the old forwarding, remote status and staged remote move) | 94/94 passed |
| `swift test --sanitize=address` / `--sanitize=thread` | 94/94 passed, no reports |
| App Debug build; Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |

**Manual interoperability check** against the LAN OpenSSH 10.2p1 server,
through the bridge as the app uses it, all on one connection: local
forwarding to the server's sshd (banner received), dynamic forwarding
(SOCKS5) to the same, a remote forwarding accepted by OpenSSH and used
from the server's shell back to a local echo server (`/dev/tcp`), all
removed live (local port closed), five add/remove races of a remote
forwarding (the H-1 pattern), shell alive and transport id unchanged.

**Problems found and fixed during M08**

- H-1 and H-2 (above), and the leaked global-request queue.
- The new status type in `ssh.h` needed to live in `defs.h`: some upstream
  files include `ssh.h` without `putty.h`.

**Limitations / not done**

- The Tunnels sheet in the running app was build-checked and its pieces
  tested (model, controller staging, panel layout), not clicked through
  by hand.
- Staging is for edits (Remove-then-Add); PuTTY's single-step semantics
  apply otherwise, including keeping a refused remote forwarding
  configured. SSH-1 cannot cancel remote forwardings (upstream).
- Patches 0007 / 0008 are not yet reported upstream (M16/M17 task).
- X11 forwarding and agent forwarding are M09.

## M07 — Live session reconfiguration framework

**Delivered**

- **Change Settings** (D-031): Session > Change Settings… (⇧⌘,) opens the
  configuration dialog as a sheet on the session window, started from the
  running settings (with the live window title, as `term_pre_reconfig`).
  Mid-session it is PuTTY's: Apply instead of Open, no About, Save only
  ("Save the current session settings"), and what `config.c` hides with
  `midsession` hidden. One Change Settings at a time per session.
- **Apply without reconnecting**: the core installs the new `Conf` and
  runs GTK PuTTY's sequence (`log_reconfig`, `ldisc_configure` /
  `ldisc_echoedit_update`, `term_reconfig`, clipboards, `backend_reconfig`,
  character set, scrollback size, redraw). Keepalives, cipher and
  compression changes (PuTTY re-keys the same connection), logging,
  keyboard, terminal, colours, selection and bell settings take effect at
  once. The window follows font, border, scrollbar and size changes; window
  options (always on top, icon title, ...) are reapplied.
- **R-3 closed**: PuTTY's unsaved keys keep their running values; a
  self-check sets every `conf_key_info[]` key to a non-default value and
  proves export → reconfigure changes nothing, and fails if the overlay is
  removed (verified by breaking it on purpose).
- **Bridge API v7**: `spb_session_export_settings` /
  `spb_session_reconfigure` with `settings_exported` / `reconfigured`
  callbacks (request numbers; the main thread never waits),
  `spb_session_transport_id`, `spb_debug_check_reconfigure_roundtrip`.
  `spb_session_copy_settings` now returns the creation-time settings
  (thread-safe). The running `TermWidth` / `TermHeight` follow the window,
  as GTK's.
- **Swift**: `PuTTYSession.exportSettings` / `reconfigure` / `transportID`;
  `SessionController.beginChangeSettings` / `applyChangeSettings` /
  `cancelChangeSettings` (async), `settings` now the running settings;
  `SessionTerminalDelegate.terminal(_:settingsChangedFrom:to:)`;
  `ConfigurationModel(changing:protocolInfo:store:)`.
- A pending log file question is withdrawn when Change Settings reopens
  the log (the M05 limitation).

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| C tests (R-3 round trip over every key; Raw: export, no-op apply, logging turned on mid-session, transport unchanged; terminal: size and live title exported, Backspace / function keys / colour / scrollback changed live; SSH: SSH-2 reported, cipher change re-keys the same connection to ChaCha20, shell still works) | Passed |
| `leaks --atExit`: all four C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan / TSan (Debug) | Passed, no reports |
| `swift test` (88 tests, 17 suites; new: Change Settings through `SessionController`, live effects through a real `TerminalView` incl. window resize, mid-session dialog rules) | 88/88 passed |
| `swift test --sanitize=address` / `--sanitize=thread` | 88/88 passed, no reports |
| App Debug build; Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |

**Manual interoperability check** against the LAN OpenSSH 10.2p1 server,
through the bridge as the app uses it: password login; running settings
exported (SSH-2); new cipher order, keepalives and width applied; OpenSSH
re-keyed ("Initiating key re-exchange (cipher settings changed)", then
ChaCha20 both ways); the shell kept working; the transport id did not
change.

**Problems found and fixed during M07**

- `spb_session_copy_settings` read the session's `Conf` from the caller's
  thread, which reconfiguration would make a data race; it now returns a
  snapshot taken at creation.
- Without the running size kept in the `Conf`, a font change would have
  snapped a resized window back to its original size.
- A row of the parity table had a `|` inside a cell, which split it.

**Limitations / not done**

- The Change Settings sheet in the running app was build-checked and its
  pieces tested (model, controller, view), not clicked through by hand.
- Tunnel editing and its staging, and the SSH panels (ciphers, kex,
  rekey limits) in the dialog, arrive with M08 and M09; until then those
  settings change only through saved sessions or tests.
- No Event Log summary of what changed (PuTTY has none either; the Event
  Log window is M10).

## M06 — Terminal parity

**Delivered**

- **Configuration panels** (D-030): Terminal/Keyboard (Backspace, Home/End,
  function key type, Shift/Ctrl/Alt arrows, initial cursor and numeric
  keypad state, Option/Command as Meta), Terminal/Bell (action, custom
  sound file, Dock indication, overload protection), Terminal/Features (all
  thirteen), Window/Translation (PuTTY's character sets, UTF-8 override,
  CJK ambiguous width, line drawing), Window/Selection (Shift override,
  selection mode, auto-copy, mouse paste / {Ctrl,Shift}+Ins /
  Ctrl+Shift+{C,V} clipboards, control characters in paste),
  Window/Selection/Copy (character classes), Window/Colours (ANSI, 256 and
  24-bit colour, bold style, the 22 colours); and in existing panels:
  cursor blinks, hide pointer when typing, gap to the window edge,
  scrollbar on left, separate window and icon titles, always on top, full
  screen on Option-Return. Everything the terminal, line discipline and
  key formatters read takes effect through upstream code.
- **Frontend behaviour** (`TerminalViewOptions`): window border and
  scrollbar side; pointer hidden while typing only when configured (it was
  always hidden before); custom bell sound via `NSSound`, beeping if the
  file cannot be played; Dock bounce for a bell in a background window;
  floating window level; Option-Return full screen; icon title as the
  minimised window's title.
- **Bridge API v6**: Ctrl+Insert copy and Ctrl+Shift+C/V decided in C per
  the settings (`SPB_KEY_C` / `SPB_KEY_V`; "No action" types ^C / ^V, as
  GTK's `key_event`); the character set list and canonical names. The
  core is built with upstream's `OSX_META_KEY_CONFIG`, so the Meta-key
  settings are saved (they were dropped by every save before).
- The configuration window is taller (15 categories); radio groups put
  their label above the buttons, as PuTTY lays them out.

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| C tests (`spb_bridge_test` adds character sets; `spb_terminal_test` adds Ctrl+Shift+C/V defaults and a second session: Linux function keys, rxvt Home/End, ^H Backspace, Ctrl+Shift+C / Ctrl+Insert copy, Ctrl+Shift+V / Shift+Insert paste from the system clipboard, cursor blink) | Passed |
| `leaks --atExit`: all four C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan / TSan (Debug) | Passed, no reports |
| `swift test` (85 tests, 16 suites; new: view options and geometry, Ctrl+Shift+C/V mapping, keypad radio, colours, character classes, bell overload times, Meta keys saved, character sets) | 85/85 passed |
| `swift test --sanitize=address` / `--sanitize=thread` | 85/85 passed, no reports |
| App Debug build; Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |
| Every panel rendered offscreen in a real `NSWindow` and inspected; the M05 dialog also checked in the running app | Fixed during M06: squeezed radio groups, category tree taller than the window |

**Manual interoperability check** against the LAN OpenSSH 10.2p1
(Ubuntu) server, through the bridge API as the app uses it, with
non-default settings (all passed): host box ` test_user@host ` split into
host and user name (`prepare_session`); unknown host key dialog; password
prompt in the terminal; the log file question ("SwiftPutty Log to File")
answered Append, and the log appended to the existing file;
`TERM=xterm-256color` and the user name seen by the server; Linux F1 and
rxvt Home/End reaching the server as `^[[[A^[[H^[Ow` (`cat -v`); a
selection copied by Ctrl+Shift+C to the system clipboard; the cursor
blinking; remote character set ISO-8859-1 showing UTF-8 `é` as `Ã©` with
"Override with UTF-8 if locale says so" off (with it on, a UTF-8 locale
keeps UTF-8, as upstream); `exit 3` reported as exit status 3.

**Problems found and fixed during M06**

- `OSXOptionMeta` / `OSXCommandMeta` were not PuTTY keywords in this build
  (upstream saves them only with `OSX_META_KEY_CONFIG`), so normalised
  saves dropped them.
- The mouse pointer was hidden on every keypress, against PuTTY's default.
- Ctrl+Shift+C/V reached the bridge as plain ^C/^V, so the clipboard
  settings could not apply; Ctrl+Insert never copied.
- Charset names on Unix are plain ("ISO-8859-1"), not Windows' long
  names; the first test assumed the latter.

**Limitations / not done**

- Not exercised by hand in the running app: the bell sound and Dock
  bounce, Option-Return, always-on-top, the colour picker, the character
  class table (logic and layout are tested; the terminal-side behaviour
  was checked against the LAN server through the bridge, above).
- Not offered: GTK's Window/Fonts panel (separate bold and wide fonts,
  shadow bold), "When window is resized" (font-size resizing), scrollbar
  in full screen, "Allow variable-pitch fonts", Windows' mouse-button mode
  (its right-click menu), RTF copy, system colours, PC speaker, printing
  (the printer is still stubbed). Warn before closing is M10.
- Settings apply when a session starts; changing them in a running
  session is M07.

## M05 — Saved sessions and PuTTY config UI

**Delivered**

- **Saved sessions** (`Sources/Persistence`, D-027): `SavedSessionStore`
  keeps PuTTY keyword maps in one versioned JSON file
  (`~/Library/Application Support/SwiftPutty/Saved Sessions.json`),
  written atomically, mode 0600 in a 0700 directory. PuTTY's rules:
  "Default Settings" first, `strcmp` order, empty name = Default
  Settings, missing sessions load built-in defaults, normalised saves. A
  newer or unreadable file is reported and never overwritten.
- **Configuration dialog** (`Sources/ConfigurationUI`, D-028): the app now
  starts with "SwiftPutty Configuration", PuTTY's tree and panels for
  Session, Session/Logging, Terminal, Window, Window/Appearance,
  Window/Behaviour, Connection and Connection/Data, with PuTTY's wording
  and saved values (rows in CONFIGURATION_PARITY.md). `ConfigurationModel`
  mirrors `sessionsaver_handler` (name box selecting by PuTTY's binary
  search; Load; Save to the typed or selected name; Delete, never Default
  Settings; double-click opens a saved session with a host; Open's "list
  had the focus" case; beeps where PuTTY beeps), `config_protocols_handler`
  (port follows the protocol only while it is the old default; Raw's
  default port is 0, shown blank, as PuTTY; the interim launcher used 23)
  and the keepalive minutes/seconds encoding. Only controls whose effect
  SwiftPutty implements are shown. Font: fixed-pitch family and size.
  Log file: Browse… via `NSSavePanel`.
- **App**: Open starts the session window and closes the dialog; Cancel
  closes it (and the app if no session is open); About; File > New
  Session… (⌘N) reopens it from Default Settings. Session windows carry
  the whole settings map; the title follows GTK PuTTY (terminal title,
  else `WinTitle`, else "host - SwiftPutty"). The app runs in the home
  directory, so relative log names (default `putty.log`) land there as
  with Unix PuTTY. The interim launcher is gone.
- **Bridge API v5** (D-029):
  - session logging's "file exists, ask" question
    (`SPB_PROMPT_LOG_FILE_EXISTS`; Overwrite / Append / Disable, GTK's
    wording) in its own dialog slot, kept after the connection ends and
    withdrawn at release. Previously logging was silently disabled
    whenever the file existed, with PuTTY's default settings;
  - `spb_settings_prepare_session`; sessions now apply upstream
    `prepare_session` (`user@host`, `:suffix`, whitespace) as GTK PuTTY
    does.
- **Swift**: `PuTTYSettings` is `Codable`/`Hashable` and has
  `preparedForSession()`; `PuTTYPrompt.Kind.logFileExists`, answers
  `.overwriteLog` / `.appendToLog`; `SessionController.pendingPrompts`
  (a host key dialog and a log question can both be pending; the window
  shows them in turn).

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| `spb_bridge_test`, `spb_terminal_test`, `spb_ssh_test`, `spb_link_closure_test` | Passed |
| `spb_session_test` (adds session log: new file, Ask → Overwrite / Append / Disable, answered after the connection closed, released while asking, Always overwrite/append; `prepare_session`) | Passed |
| `leaks --atExit`: all four C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan (Debug) | Passed, no reports |
| C tests under TSan (Debug, `halt_on_error=1`) | Passed, no reports |
| `swift test` (75 tests, 15 suites; new: saved-session store, configuration dialog model, log question through `SessionController`, its dialog layout) | 75/75 passed |
| `swift test --sanitize=address` / `--sanitize=thread` | 75/75 passed, no reports |
| App Debug build; Release build, universal | Succeeded, 0 warnings; `lipo`: x86_64 arm64 |
| Every configuration panel rendered offscreen in a real `NSWindow` and inspected | Layout as PuTTY's panels; fixed during M05: label-as-placeholder text, squeezed edit boxes |

**Problems found and fixed during M05**

- With PuTTY's default "Ask the user every time", session logging was
  disabled whenever the log file existed (the M02 placeholder); now the
  question is asked (API v5).
- The bridge skipped `prepare_session`, so `user@host` in the host box
  was looked up as a host name.
- Raw's port defaulted to 23 in the interim launcher; PuTTY's is 0.
- The Connection panel's logical host name first used keyword
  `LogicalHost`; PuTTY's is `LogHost`. Panels now use `PuTTYKeyword`,
  and a test checks every keyword against PuTTY's saved settings.
- A C test released a session straight after answering, so release
  (D-017) suppressed the answer's Event Log line; the test now waits.

**Limitations / not done**

- Not exercised by hand: the screen was locked, so the dialog was
  checked by offscreen rendering and its logic by unit tests; keyboard
  focus, double-click in the list, the font popover, `NSSavePanel`, the
  Local Network prompt and opening a saved session against the LAN
  server through the window are not yet checked interactively.
- Panels not yet present: Keyboard, Bell, Features, Translation,
  Selection, Colours (M06); Proxy, SSH and its subpanels, Serial, Telnet,
  Rlogin, SUPDUP (M09, M11, M12); the environment variables list and the
  printer (M12). Connection types: SSH and Raw (M11 for the rest).
- No Change Settings (M07): mid-session Save, the runtime/reconnect
  split, and `log_reconfig`, which will also have to withdraw a pending
  log file question when it closes the log.
- No import of PuTTY's Unix session files; no "Saved Sessions" or
  "Duplicate Session" menus (M10).

## M04 — Basic SSH session

**Delivered**

- **SSH enabled** in the bridge (`PROT_SSH`, `PROT_SSHCONN`), started as
  GTK PuTTY starts a backend (trust status set before `backend_init`).
  Upstream's SSH stack is used unchanged.
- **Logins in the terminal** (D-024): user name, password and
  keyboard-interactive prompts go to `term_get_userpass_input`, exactly as
  GTK PuTTY: PuTTY's echo rules, trust sigil and retry messages.
- **Dialogs** (D-024, API v4): host key (unknown or changed) and
  weak-crypto prompts reach the frontend as `spb_prompt` (kind, id,
  PuTTY's `SeatDialogText`); `spb_session_answer_prompt` answers Accept
  (stores the key via upstream `store_host_key`), Connect Once or Cancel.
  A dialog whose connection ends is withdrawn (`prompt_cancelled`); stale
  answers are ignored. PuTTY's button wording comes from
  `prompt_descriptions`, as GTK's.
- **Swift**: `PuTTYPrompt` and `.prompt` / `.promptCancelled` events,
  `PuTTYSession.answer(_:with:)`; `SessionController.pendingPrompt` and
  `answer(_:with:)`.
- **UI**: `PuTTYPromptView` sheet laid out as GTK PuTTY's dialog (title,
  security warning, paragraphs, monospaced fingerprints, "More info";
  Accept / Connect Once / Cancel, no default button for a changed key;
  Yes / No for weak crypto). Launcher: connection type SSH (default, port
  22) or Raw, optional user name. Debug builds:
  `SWIFTPUTTY_DEBUG_OPEN_SSH=[user@]host:port`.
- **App fixes** (D-026): session windows are tied to the launch that opened
  them, so SwiftUI's window restoration no longer reconnects old sessions
  or leaves empty windows; `NSLocalNetworkUsageDescription` declared, so
  LAN servers are reachable once the user allows it.
- **Upstream patch** `0005-ssh-bpp-free-clears-queues.patch` (found by
  `leaks`): closing an SSH session leaked packets still queued in its BPP,
  e.g. while the host key dialog was up. Planned patches renumbered again:
  status hook `0006`, H-1 fix `0007`, H-2 fix `0008`.
- **Test fixture** (D-025): `spb_ssh_fixture` runs upstream's `uppity`
  behind a loopback relay; committed test-only host keys; `uppity` is
  built by `scripts/build-core.sh` (its duplicate-library linker note
  silenced for that target only).

**Tests and results** (clean build, `scripts/test-all.sh --clean`, x86_64
host, Xcode 26.6 / Swift 6.3.3 / CMake 4.4.4; CI on Apple Silicon and
Intel)

| Check | Result |
|---|---|
| Core build, arm64 + x86_64 (RelWithDebInfo) | OK, 0 warnings |
| `spb_bridge_test`, `spb_session_test`, `spb_terminal_test`, `spb_link_closure_test` | Passed |
| `spb_ssh_test` (host key accept/store, once, cancel, changed key; dialog withdrawn on close; keyboard-interactive and password logins; shell; pty size; exit status) | Passed (about 3.5 s) |
| `leaks --atExit`: all four C test programs | 0 leaks, 0 bytes (each) |
| C tests under ASan + UBSan (Debug) | Passed, no reports |
| C tests under TSan (Debug, `halt_on_error=1`) | Passed, no reports |
| `swift test` (49 tests, 13 suites; SSH through a real `TerminalView`) | 49/49 passed; SSH suites stable over repeated runs |
| `swift test --sanitize=address` / `--sanitize=thread` | 49/49 passed, no reports |
| App Debug build; Release build, universal | Succeeded, 0 warnings |
| App against the local SSH fixture, screenshot-checked | Host key sheet with PuTTY's text and buttons; window title "127.0.0.1 - SwiftPutty"; relaunch reopens no sessions |

**Manual interoperability check** against a LAN OpenSSH 10.2p1 (Ubuntu)
server, through the bridge API exactly as the app uses it: hybrid
post-quantum key exchange (NTRU Prime / Curve25519), AES-256 with AES-NI;
the host key dialog with PuTTY's full text and More info; password login
as an ordinary user; pty 80×24 with `TERM=xterm`; commands ran; `exit 7`
reported as exit status 7.

**Problems found and fixed during M04**

- `uppity` refuses TCP clients on macOS (its same-user check reads
  `/proc`), hence the Unix-socket relay; Unix socket paths are limited to
  104 bytes, now checked by the fixture.
- `uppity` sometimes reports exit status 127 (pty EOF before the shell is
  reaped); tests accept it (D-025).
- SwiftUI window restoration reconnected old sessions at launch (D-026).
- Connections to LAN hosts from the app failed with "No route to host"
  without the Local Network usage declaration (D-026).
- Upstream leak of queued SSH packets at teardown (patch `0005`).

**Limitations / not done**

- Public-key authentication from key files, agent forwarding, X11
  forwarding, GSSAPI, and the remaining authentication options are M09
  (the agent is used if `SSH_AUTH_SOCK` is set, as PuTTY does; not yet
  tested). No session specials menu (break, rekey) yet: M10.
- The Local Network permission prompt and a full login through the app's
  UI against the LAN server were not exercised by hand (the machine was
  locked); the same path is covered against `uppity` by automated tests
  through a real window, and against the LAN server through the bridge.
- No warning before closing a connected session window (PuTTY's
  `WarnOnClose`): M10.

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
  `0007` (renumbered again in M04).
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

**CI** (added to complete M03): `.github/workflows/ci.yml` runs
`scripts/test-all.sh --clean` on GitHub's Apple Silicon (`macos-26`) and
Intel (`macos-26-intel`) runners with Xcode 26.6. The first run of the
whole suite on arm64 hardware passed every C check (plain, `leaks`,
ASan/UBSan, TSan); one Swift test failed on a timing assumption (below),
and after the fix the arm64 job passed completely. This closes risk R-8:
the arm64 slice is now executed, not just built.

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
- Found by the first arm64 CI run: a test assumed nothing comes between
  a session's `remoteExit` and `CLOSED` events, but since M03 the
  terminal's title update can (timing-dependent). The test now checks
  session events only.

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
