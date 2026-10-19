// swift-tools-version: 6.2

// All of Shello's logic. The Xcode project holds only the app and extension targets.
// Target layout and dependency rules: docs/spec/STACK.md sections 4 and 5.

import PackageDescription

/// Swift 6.2's approachable concurrency defaults (SE-0461), matching
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES` in the Xcode project.
let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// UI-free targets: nonisolated by default, and every unsafe pointer use is marked `unsafe` (SE-0458).
/// They import Foundation and their C libraries only, so they stay buildable on Linux.
let core: [SwiftSetting] = approachableConcurrency + [.strictMemorySafety()]

/// UIKit and SwiftUI targets: main actor by default (SE-0466).
let ui: [SwiftSetting] = approachableConcurrency + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "ShelloKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "ShelloFeatures", targets: ["ShelloFeatures"])
    ],
    targets: [
        // Domain types: host, group, tag, snippet, preset.
        .target(name: "ShelloModel", swiftSettings: core),
        // GRDB database, migrations, JSON export and import.
        .target(name: "ShelloStorage", dependencies: ["ShelloModel"], swiftSettings: core),
        // Keychain, Secure Enclave, unlock window, SSH agent, security log.
        .target(name: "ShelloSecurity", dependencies: ["ShelloModel"], swiftSettings: core),
        // libssh wrapper: connection actor, channels, SFTP, forwards, algorithm policy.
        .target(name: "ShelloSSH", dependencies: ["ShelloModel"], swiftSettings: core),
        // tmux queries and parsers over hidden channels.
        .target(name: "ShelloTmux", dependencies: ["ShelloModel", "ShelloSSH"], swiftSettings: core),
        // Tabs and connections lifecycle, reconnect and reattach, detection, multi-host run.
        .target(
            name: "ShelloCore",
            dependencies: ["ShelloModel", "ShelloStorage", "ShelloSecurity", "ShelloSSH", "ShelloTmux"],
            swiftSettings: core
        ),
        // UIKit: SwiftTerm host view, Shello keyboard, extra keys row, pads.
        .target(name: "ShelloTerminalUI", dependencies: ["ShelloModel"], swiftSettings: ui),
        // SwiftUI screens.
        .target(
            name: "ShelloFeatures",
            dependencies: ["ShelloModel", "ShelloCore", "ShelloTerminalUI"],
            swiftSettings: ui
        ),

        .testTarget(name: "ShelloModelTests", dependencies: ["ShelloModel"], swiftSettings: core),
        .testTarget(name: "ShelloStorageTests", dependencies: ["ShelloStorage"], swiftSettings: core),
        .testTarget(name: "ShelloSecurityTests", dependencies: ["ShelloSecurity"], swiftSettings: core),
        .testTarget(name: "ShelloSSHTests", dependencies: ["ShelloSSH"], swiftSettings: core),
        .testTarget(name: "ShelloTmuxTests", dependencies: ["ShelloTmux"], swiftSettings: core),
        .testTarget(name: "ShelloCoreTests", dependencies: ["ShelloCore"], swiftSettings: core),
        .testTarget(name: "ShelloTerminalUITests", dependencies: ["ShelloTerminalUI"], swiftSettings: ui),
        .testTarget(name: "ShelloFeaturesTests", dependencies: ["ShelloFeatures"], swiftSettings: ui),
    ],
    swiftLanguageModes: [.v6]
)
