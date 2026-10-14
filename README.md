# SwiftPutty

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
and PuTTY core integration) and **M02** (session executor and event loop)
are complete. The PuTTY core runs on its own thread, and sessions connect
and exchange data through it (Raw protocol, exercised by tests). There is
no terminal, session UI or SSH connectivity yet. See
`docs/IMPLEMENTATION_STATUS.md`.

## Building

Requirements: macOS 14+, Xcode 26 (Swift 6), CMake ≥ 3.20, Ninja, Perl.
No runtime dependencies beyond macOS itself.

```sh
scripts/build-core.sh          # PuTTY core + bridge → build/SwiftPuttyCore.xcframework
scripts/build-app.sh           # core + universal Release app → build/DerivedData/…/SwiftPutty.app
scripts/build-app.sh Debug
scripts/test-all.sh [--clean]  # every automated check
```

To work in Xcode, run `scripts/build-core.sh` once (and again after changing
`Core/` or `patches/`), then open `App/SwiftPutty.xcodeproj`. Swift-only
work can use `swift build` / `swift test` at the repository root.

## Layout

```
App/            SwiftUI app (Xcode project)
Sources/        Swift modules (PuTTYBridge, SessionLayer; TestServers for tests) — Package.swift at the root
Tests/          Swift tests
Core/           C bridge: PuTTYBridge.h, bridge sources, CMake integration, C tests
Vendor/putty/   pristine PuTTY 0.85 source (never edited; see patches/)
patches/        local patches applied to a build copy of the PuTTY source
scripts/        build and test scripts
docs/           project documentation
```

## Documentation

| Document | Contents |
|---|---|
| `docs/ARCHITECTURE.md` | How PuTTY reconfigures a live session and forwards ports (with source citations); SwiftPutty architecture; C bridge API |
| `docs/UPSTREAM_PUTTY.md` | Pinned upstream version, source subset, build integration, patches, update procedure |
| `docs/CONFIGURATION_PARITY.md` | Every Windows PuTTY setting → macOS mapping and live-reconfigurability |
| `docs/DECISIONS.md` | Architectural decision records |
| `docs/TESTING.md` | How to run the tests; test strategy and fixtures |
| `docs/IMPLEMENTATION_STATUS.md` | Milestone progress and results |
