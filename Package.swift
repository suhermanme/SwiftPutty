// swift-tools-version: 6.0
//
// SwiftPuttyKit: the Swift side of SwiftPutty below the app target.
//
// The C core (PuTTY + bridge) is prebuilt into
// build/SwiftPuttyCore.xcframework by scripts/build-core.sh; run that
// first. See README.md.

import PackageDescription

let package = Package(
    name: "SwiftPuttyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuTTYBridge", targets: ["PuTTYBridge"]),
        .library(name: "SessionLayer", targets: ["SessionLayer"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "ConfigurationUI", targets: ["ConfigurationUI"]),
    ],
    targets: [
        .binaryTarget(
            name: "SwiftPuttyCore",
            path: "build/SwiftPuttyCore.xcframework"
        ),
        .target(
            name: "PuTTYBridge",
            dependencies: ["SwiftPuttyCore"],
            path: "Sources/PuTTYBridge"
        ),
        .target(
            name: "SessionLayer",
            dependencies: ["PuTTYBridge"],
            path: "Sources/SessionLayer"
        ),
        .target(
            name: "TerminalUI",
            dependencies: ["PuTTYBridge", "SessionLayer"],
            path: "Sources/TerminalUI"
        ),
        .target(
            name: "Persistence",
            dependencies: ["PuTTYBridge"],
            path: "Sources/Persistence"
        ),
        .target(
            name: "ConfigurationUI",
            dependencies: ["PuTTYBridge", "Persistence", "TerminalUI"],
            path: "Sources/ConfigurationUI"
        ),
        // Test-only support code (local servers); not a product.
        .target(
            name: "TestServers",
            path: "Sources/TestServers"
        ),
        // One test target: every test shares one process-wide PuTTY core
        // and runs serially under a single root suite.
        .testTarget(
            name: "SwiftPuttyKitTests",
            dependencies: ["PuTTYBridge", "SessionLayer", "TerminalUI", "Persistence",
                           "ConfigurationUI", "TestServers"],
            path: "Tests/SwiftPuttyKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
