# SwiftPutty

[![CI](https://github.com/suhermanme/SwiftPutty/actions/workflows/ci.yml/badge.svg)](https://github.com/suhermanme/SwiftPutty/actions/workflows/ci.yml)

A native macOS (SwiftUI + AppKit) frontend for the **PuTTY 0.85** portable
core. The goal is Windows `putty.exe` behaviour — SSH, terminal semantics,
saved sessions, and especially **live "Change Settings…" on a running
session, including adding, removing and editing SSH tunnels without
reconnecting** — presented as a native Mac app.

SwiftPutty is an independent project, not an official PuTTY product. PuTTY
is © Simon Tatham and contributors, MIT licensed. See
`THIRD_PARTY_NOTICES.md`.

## Status

Milestones **M00** (analysis and architecture), **M01** (build skeleton
and PuTTY core integration), **M02** (session executor and event loop),
**M03** (terminal rendering foundation), **M04** (basic SSH session),
**M05** (saved sessions and configuration dialog), **M06** (terminal
parity), **M07** (live Change Settings), **M08** (SSH tunnels, changed
live), **M09** (SSH authentication and the SSH panels), **M10** (Event
Log and session operations), **M11** (Telnet, Rlogin, SUPDUP and serial
lines), **M12** (configuration parity: proxies, connection sharing, host
keys and CAs, agent forwarding, fonts, system colours, Copy as RTF),
**M13** (security and reliability) and **M14** (performance) are complete.
The app starts with PuTTY's configuration dialog (Session, Logging,
Terminal with Keyboard / Bell / Features, Window with Appearance /
Behaviour / Translation / Selection / Colours / Fonts, Connection with
Data and Proxy, the SSH panels, Serial, Telnet, Rlogin and SUPDUP; saved
sessions with PuTTY's Load / Save / Delete rules) and opens SSH, Telnet,
Rlogin, SUPDUP, Raw and serial-line sessions in terminal windows driven by
PuTTY's own protocol code and terminal emulator, with PuTTY's host key
dialog, in-terminal login and session logging. Session > Change Settings…
changes a running session without reconnecting, as PuTTY does, including
adding, removing and editing SSH port forwardings (a failed edit keeps the
old one). See `docs/IMPLEMENTATION_STATUS.md`.

M14 retained a bounded terminal glyph cache and added lossless output
delivery with acknowledgement-based backpressure. A controlled DNS
measurement confirmed that synchronous resolver stalls block all sessions
on the shared core thread; the existing contract remains pending evidence
of problematic real-world resolver latency. See `docs/M14_DNS_MEASUREMENT.md`.

M15 adds an ad-hoc-signed universal macOS app ZIP for GitHub Releases.
Tag a release as `vMAJOR.MINOR.PATCH` to build and publish the app and its
SHA-256 checksum from the `macos-26` GitHub Actions runner. The archive
contains both Apple Silicon (arm64, including M-series Macs) and Intel
(x86_64) slices. Ad-hoc signatures are not notarized; macOS may require the
user to explicitly allow the downloaded app before opening it.

## Building

Requirements: macOS 14+, Xcode 26 (Swift 6), CMake ≥ 3.20, Ninja, Perl.
No runtime dependencies beyond macOS itself.

```sh
scripts/build-core.sh          # PuTTY core + bridge → build/SwiftPuttyCore.xcframework
scripts/build-app.sh           # core + universal Release app → build/DerivedData/…/SwiftPutty.app
scripts/build-app.sh Debug
scripts/test-all.sh [--clean]  # every automated check
```

To build the same release ZIP locally (without publishing it):

```sh
scripts/package-release.sh 0.1.0
```

The resulting `build/releases/SwiftPutty-v0.1.0-macos-universal.zip`
contains an ad-hoc-signed app with arm64 and x86_64 slices. A `v0.1.0` tag
triggers the GitHub Release workflow; use a new `vMAJOR.MINOR.PATCH` tag for
each release.

CI runs `scripts/test-all.sh --clean` on Apple Silicon and Intel runners
for every push to `main` and every pull request (`.github/workflows/ci.yml`).

To work in Xcode, run `scripts/build-core.sh` once (and again after changing
`Core/` or `patches/`), then open `App/SwiftPutty.xcodeproj`. Swift-only
work can use `swift build` / `swift test` at the repository root.

## Layout

```
App/            SwiftUI app (Xcode project)
Sources/        Swift modules (PuTTYBridge, SessionLayer, TerminalUI; TestServers for tests) — Package.swift at the root
Tests/          Swift tests
Core/           C bridge: PuTTYBridge.h, bridge sources, CMake integration, C tests
Vendor/putty/   pristine PuTTY 0.85 source (never edited; see patches/)
patches/        local patches applied to a build copy of the PuTTY source
scripts/        build and test scripts
docs/           project documentation
```

## Licence

SwiftPutty is distributed under the MIT licence, the same licence as
PuTTY: see `LICENSE`. The bundled PuTTY source keeps its own copyright and
licence (`Vendor/putty/LICENCE`, `THIRD_PARTY_NOTICES.md`).

## Documentation

| Document | Contents |
|---|---|
| `docs/ARCHITECTURE.md` | How PuTTY reconfigures a live session and forwards ports (with source citations); SwiftPutty architecture; C bridge API |
| `docs/UPSTREAM_PUTTY.md` | Pinned upstream version, source subset, build integration, patches, update procedure |
| `docs/CONFIGURATION_PARITY.md` | Every Windows PuTTY setting → macOS mapping and live-reconfigurability |
| `docs/DECISIONS.md` | Architectural decision records |
| `docs/TESTING.md` | How to run the tests; test strategy and fixtures |
| `docs/IMPLEMENTATION_STATUS.md` | Milestone progress and results |
