import Foundation
import ShelloFeatures
import ShelloSecurity
import ShelloStorage
import SwiftUI
import os

/// Composition root. Services are created here and passed to the screens through the SwiftUI environment.
@main
struct ShelloApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// The services around the one database of the app, opened once at launch, or why it could not
    /// be opened.
    private let services: Result<Services, any Error>
    /// The passwords and passphrases in the Keychain, read inside the unlock window.
    private let secrets: SecretStore
    /// The SSH keys, which sign inside the unlock window or after a prompt of their own.
    private let sshKeys: SSHKeyStore
    /// App lock, which opens and closes the unlock window that `secrets` and `sshKeys` use.
    private let appLock: AppLock
    /// The terminal settings of this device.
    private let terminalSettings: TerminalSettings

    init() {
        DesignSystem.registerFonts()
        DesignSystem.applyTextSizeChangesAtOnce()
        let unlockWindow = UnlockWindow()
        secrets = SecretStore(keychain: SystemKeychain(), unlockWindow: unlockWindow)
        sshKeys =
            Launch.keepsSSHKeysInMemory
            ? .inMemory(unlockWindow: unlockWindow, secureEnclave: Launch.standsInForSecureEnclave)
            : SSHKeyStore(unlockWindow: unlockWindow)
        appLock = AppLock(window: unlockWindow, defaults: Launch.settings, isEnabled: Launch.locksApp)
        terminalSettings = TerminalSettings(defaults: Launch.settings, cursorBlinks: Launch.blinksCursor)
        services = Result { Services(database: try Self.openDatabase()) }
        if case .failure(let error) = services {
            Logger(subsystem: "ch.shello.Shello", category: "Storage").error("Could not open the database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Launch.showsPrivacyCoverOnly {
                    PrivacyCover()
                } else {
                    switch services {
                    case .success(let services):
                        RootView()
                            .environment(\.hostRepository, services.hostRepository)
                            .environment(\.exportRepository, services.exportRepository)
                            .environment(\.secretStore, secrets)
                            .environment(\.sshKeyStore, sshKeys)
                            .environment(\.appLock, appLock)
                            .environment(\.terminalSettings, terminalSettings)
                    case .failure(let error):
                        DatabaseUnavailableView(error: error)
                    }
                }
            }
            .preferredColorScheme(Launch.colorScheme)
            .appLock(appLock, preferredColorScheme: Launch.colorScheme)
        }
        .commands {
            TerminalCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            // A suspended app must not hold locks on files in its App Group container (STACK
            // section 7.10). The phase is the app's: background only once every scene is.
            if phase == .background {
                AppDatabase.suspend()
            } else {
                AppDatabase.resume()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: appLock.appDidBecomeActive()
            case .background: appLock.appDidEnterBackground()
            default: break
            }
        }
    }

    private static func openDatabase() throws -> AppDatabase {
        if Launch.usesEmptyDatabase {
            return try AppDatabase(
                directory: URL.temporaryDirectory.appending(path: "UITests-\(UUID().uuidString)"))
        }
        return try AppDatabase.openInAppGroup()
    }
}

/// What the screens read and write the database through.
private struct Services {
    let hostRepository: HostRepository
    let exportRepository: ExportRepository

    init(database: AppDatabase) {
        hostRepository = HostRepository(database)
        exportRepository = ExportRepository(database)
    }
}

/// How this launch runs. Debug builds take the options of the UI tests (UITests/TestApp.swift) from
/// the environment; release builds always run as they ship.
private enum Launch {
    #if DEBUG
        private static let environment = ProcessInfo.processInfo.environment
        /// UI tests start every launch with an empty database and settings of their own.
        private static let isUITesting = environment["SHELLO_UI_TESTING"] == "1"

        static var usesEmptyDatabase: Bool { isUITesting }

        /// UI tests start every launch without SSH keys: the keys live in memory, not the Keychain.
        static var keepsSSHKeysInMemory: Bool { isUITesting }

        /// The simulator cannot make Secure Enclave keys. A UI test about them gets a stand-in, which
        /// keeps its keys in memory.
        static var standsInForSecureEnclave: Bool { environment["SHELLO_UI_TESTING_SECURE_ENCLAVE"] == "1" }

        /// UI tests run without app lock unless they are about it.
        static var locksApp: Bool {
            environment["SHELLO_UI_TESTING_APP_LOCK"].map { $0 == "1" } ?? !isUITesting
        }

        /// UI tests keep the terminal's cursor steady: XCUITest waits for the app to go idle before
        /// each step, and while a cursor blinks it never does, so each step would wait a minute.
        static var blinksCursor: Bool { !isUITesting }

        /// Each UI test chooses its appearance, whatever the simulator's.
        static var colorScheme: ColorScheme? {
            switch environment["SHELLO_UI_TESTING_APPEARANCE"] {
            case "dark": .dark
            case "light": .light
            default: nil
            }
        }

        /// The app switcher's cover on its own, for its accessibility audit: XCUITest cannot hold the
        /// app inactive, which is when the cover shows.
        static var showsPrivacyCoverOnly: Bool { environment["SHELLO_UI_TESTING_PRIVACY_COVER"] == "1" }

        static let settings: UserDefaults = {
            guard isUITesting else { return .standard }
            let suite = "ch.shello.Shello.UITests"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }()
    #else
        static let usesEmptyDatabase = false
        static let keepsSSHKeysInMemory = false
        static let standsInForSecureEnclave = false
        static let locksApp = true
        static let blinksCursor = true
        static let colorScheme: ColorScheme? = nil
        static let showsPrivacyCoverOnly = false
        static let settings = UserDefaults.standard
    #endif
}
