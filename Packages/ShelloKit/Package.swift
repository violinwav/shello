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
        // The app's screens, plus the storage, the security services and the connector its
        // composition root opens and hands to them, and the model types they take.
        .library(
            name: "ShelloFeatures",
            targets: ["ShelloFeatures", "ShelloStorage", "ShelloSecurity", "ShelloCore", "ShelloModel"]
        )
    ],
    // Pinned exactly; docs/spec/STACK.md section 8 lists every dependency and why.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        // The preview of SwiftTerm 2.0 and its API; 2.0.0 replaces it once released (STACK section 7.4).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
        // Tests only: the terminal's snapshot tests.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
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
        // The only target that reaches libssh and OpenSSL. zlib is the iOS SDK's. The algorithm
        // policy is data that ships with it (README section 14).
        .target(
            name: "ShelloSSH",
            dependencies: ["ShelloModel", "libssh", "libcrypto"],
            resources: [.copy("Resources/AlgorithmPolicy.json")],
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
        .target(
            name: "ShelloTerminalUI",
            dependencies: ["ShelloModel", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: ui
        ),
        // SwiftUI screens, with the design system's colours and fonts. Each font family folder is
        // copied whole, so that its licence ships next to its files; Resources/Fonts/README.md
        // records where they come from.
        .target(
            name: "ShelloFeatures",
            dependencies: [
                "ShelloModel", "ShelloStorage", "ShelloSecurity", "ShelloCore", "ShelloSSH", "ShelloTerminalUI",
            ],
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
        // Most of them sign in to the test server in TestServers/, and skip when it is not running.
        .testTarget(name: "ShelloSSHTests", dependencies: ["ShelloSSH", "ShelloModel"], swiftSettings: core),
        .testTarget(name: "ShelloTmuxTests", dependencies: ["ShelloTmux"], swiftSettings: core),
        // A real database in a temporary directory, secrets in memory, and the test server in
        // TestServers/, without which the tests that need it skip.
        .testTarget(
            name: "ShelloCoreTests",
            dependencies: ["ShelloCore", "ShelloModel", "ShelloStorage", "ShelloSecurity", "ShelloSSH"],
            swiftSettings: core
        ),
        .testTarget(
            name: "ShelloTerminalUITests",
            dependencies: ["ShelloTerminalUI", "ShelloModel", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: ui
        ),
        // The view models run against a real database in a temporary directory, and a Keychain in memory.
        // The terminal's snapshot tests and its performance test run here too, with the app's fonts and
        // colours; __Snapshots__ holds their reference images.
        .testTarget(
            name: "ShelloFeaturesTests",
            dependencies: [
                "ShelloFeatures", "ShelloStorage", "ShelloSecurity", "ShelloModel", "ShelloTerminalUI", "ShelloCore",
                "ShelloSSH", .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"],
            swiftSettings: ui
        ),
    ],
    swiftLanguageModes: [.v6]
)
