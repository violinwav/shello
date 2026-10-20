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

/// Warnings are errors in Shello's own targets, as in Configurations/Project.xcconfig. Set here
/// rather than on the xcodebuild command line, which would also reach package dependencies such as
/// GRDB: Xcode builds those with warnings suppressed, and the compiler rejects `-warnings-as-errors`
/// together with `-suppress-warnings`.
let warningsAsErrors: [SwiftSetting] = [.treatAllWarnings(as: .error)]

/// UI-free targets: nonisolated by default, and every unsafe pointer use is marked `unsafe` (SE-0458).
/// They import Foundation and their C libraries only, so they stay buildable on Linux.
let core: [SwiftSetting] = approachableConcurrency + warningsAsErrors + [.strictMemorySafety()]

/// UIKit and SwiftUI targets: main actor by default (SE-0466).
let ui: [SwiftSetting] = approachableConcurrency + warningsAsErrors + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "ShelloKit",
    platforms: [.iOS(.v26)],
    products: [
        // The app's screens, plus the storage its composition root opens and hands to them.
        .library(name: "ShelloFeatures", targets: ["ShelloFeatures", "ShelloStorage"])
    ],
    // Pinned exactly; docs/spec/STACK.md section 8 lists every dependency and why.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")
    ],
    targets: [
        // Domain types: host, group, tag, snippet, preset.
        .target(name: "ShelloModel", swiftSettings: core),
        // GRDB database, migrations, JSON export and import.
        .target(
            name: "ShelloStorage",
            dependencies: ["ShelloModel", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: core
        ),
        // Keychain, Secure Enclave, unlock window, SSH agent, security log.
        .target(name: "ShelloSecurity", dependencies: ["ShelloModel"], swiftSettings: core),
        // libssh wrapper: connection actor, channels, SFTP, forwards, algorithm policy.
        // The only target that reaches libssh and OpenSSL. zlib is the iOS SDK's.
        .target(
            name: "ShelloSSH",
            dependencies: ["ShelloModel", "libssh", "libcrypto"],
            swiftSettings: core,
            linkerSettings: [.linkedLibrary("z")]
        ),
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
        // SwiftUI screens, with the design system's colours and fonts. Each font family folder is
        // copied whole, so that its licence ships next to its files; Resources/Fonts/README.md
        // records where they come from.
        .target(
            name: "ShelloFeatures",
            dependencies: ["ShelloModel", "ShelloStorage", "ShelloCore", "ShelloSSH", "ShelloTerminalUI"],
            exclude: ["Resources/Fonts/README.md"],
            resources: [
                .process("Resources/Colors.xcassets"),
                .copy("Resources/Fonts/Geist"),
                .copy("Resources/Fonts/JetBrainsMono"),
            ],
            swiftSettings: ui
        ),

        // Static XCFrameworks that Vendor/build.sh builds from verified source (STACK section 12).
        // Run it once before building; the outputs are not in git.
        .binaryTarget(name: "libssh", path: "../../Vendor/build/xcframeworks/libssh.xcframework"),
        .binaryTarget(name: "libcrypto", path: "../../Vendor/build/xcframeworks/libcrypto.xcframework"),

        .testTarget(name: "ShelloModelTests", dependencies: ["ShelloModel"], swiftSettings: core),
        // GRDB too, for the tests that inspect the schema and the stored rows. Fixtures holds a
        // database written by each schema version, for the migration tests.
        .testTarget(
            name: "ShelloStorageTests",
            dependencies: ["ShelloStorage", "ShelloModel", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")],
            swiftSettings: core
        ),
        .testTarget(name: "ShelloSecurityTests", dependencies: ["ShelloSecurity"], swiftSettings: core),
        .testTarget(name: "ShelloSSHTests", dependencies: ["ShelloSSH"], swiftSettings: core),
        .testTarget(name: "ShelloTmuxTests", dependencies: ["ShelloTmux"], swiftSettings: core),
        .testTarget(name: "ShelloCoreTests", dependencies: ["ShelloCore"], swiftSettings: core),
        .testTarget(name: "ShelloTerminalUITests", dependencies: ["ShelloTerminalUI"], swiftSettings: ui),
        // The view models run against a real database in a temporary directory.
        .testTarget(
            name: "ShelloFeaturesTests",
            dependencies: ["ShelloFeatures", "ShelloStorage", "ShelloModel"],
            swiftSettings: ui
        ),
    ],
    swiftLanguageModes: [.v6]
)
