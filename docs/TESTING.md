# Testing

Status: **M02.** C bridge tests, core-thread and session tests against
local TCP servers, and Swift package tests exist; SSH integration fixtures
start in M04.

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
| `spb_session_test` (ctest) | `Core/tests/spb_session_test.c` | Core thread and executor (M02), against an in-process loopback TCP server: idle loop blocks, PuTTY timers fire in order and never early, Raw echo, input queued before connect, 4 MiB transfer intact, remote close (exit code, then CLOSED), refused connection, unknown host, SSH/Telnet refused until their milestone, 1,200 release paths (never started, connecting, connected with traffic), 128 sessions driven from 8 threads, descriptors return to baseline, shutdown straight after release. Also run under `leaks --atExit`, ASan+UBSan and TSan |
| `spb_link_closure_test` (ctest) | `Core/tests/spb_link_closure_test.c` | Force-loads every core archive member; the build fails on any unresolved symbol (both architectures) |
| `SwiftPuttyKitTests` (Swift Testing) | `Tests/SwiftPuttyKitTests/` | Swift wrapper: bridge loads, licence, core lifecycle, settings conversion (including Unicode), session lifecycle and event streams, core thread, Raw sessions against `TestServers.LoopbackServer` (echo, Unicode, remote close, refused, unknown host, SSH not yet available, 100 concurrent sessions, 2 MiB transfer), `SessionController` (state, transcript bound, release on drop). One serialized root suite (D-020); also run under ASan and TSan |

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

## SSH server fixtures (D-009)

1. **OpenSSH `sshd` (primary).** `/usr/sbin/sshd` (OpenSSH 10.3p1 on the dev
   host), started unprivileged per test run: `sshd -D -e -f <tmp>/sshd_config`
   with `ListenAddress 127.0.0.1`, a random high port, generated host keys
   (ed25519, ecdsa, rsa), `AuthorizedKeysFile` pointing at a generated user
   key, `AllowTcpForwarding yes`, `GatewayPorts clientspecified`,
   `PidFile`/`HostKey` under the temp dir. Password auth for the current
   user is not usable unprivileged. Password and KI cases therefore use
   fixture 2, or an `sshd` built with a test PAM-free auth configuration.
2. **PuTTY `uppity`** (`unix/uppity.c`, upstream test server). Built from
   the vendored tree. Used for deterministic cases (password and KI with
   fixed credentials) and for fault injection, e.g. delaying
   `tcpip-forward` replies to reproduce H-1.
3. **Docker OpenSSH (optional).** Not installed on the dev host; not required.

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

- Debug and Release, arm64 and x86_64 slices. The arm64 runtime pass needs
  Apple Silicon hardware.
- Clean build at every milestone end.
