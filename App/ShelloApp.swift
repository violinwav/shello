import Foundation
import ShelloCore
import ShelloFeatures
import ShelloModel
import ShelloSecurity
import ShelloStorage
import SwiftUI
import UIKit
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
    /// Whether iOS's Local Network question has been explained on this device.
    private let localNetworkNotice: LocalNetworkNotice
    /// The tabs each window has open, for Restore, under the windows' scene sessions.
    private let rememberedTabs: RememberedTabsStore
    /// Whether the data a UI test asked for is in the database. Debug builds only.
    @State private var hasTestData = !Launch.addsTestData

    init() {
        DesignSystem.registerFonts()
        DesignSystem.applyTextSizeChangesAtOnce()
        let unlockWindow = UnlockWindow()
        secrets = SecretStore(keychain: SystemKeychain(), unlockWindow: unlockWindow)
        sshKeys =
            Launch.keepsSSHKeysInMemory
            ? .inMemory(
                unlockWindow: unlockWindow, secureEnclave: Launch.standsInForSecureEnclave,
                fixtureKeys: Launch.fixtureSSHKeys)
            : SSHKeyStore(unlockWindow: unlockWindow)
        appLock = AppLock(window: unlockWindow, defaults: Launch.settings, isEnabled: Launch.locksApp)
        terminalSettings = TerminalSettings(defaults: Launch.settings, cursorBlinks: Launch.blinksCursor)
        localNetworkNotice = LocalNetworkNotice(defaults: Launch.settings)
        rememberedTabs = RememberedTabsStore(
            file: Launch.rememberedTabsFile,
            openWindows: { Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)) })
        let secrets = secrets
        let sshKeys = sshKeys
        services = Result { Services(database: try Self.openDatabase(), secrets: secrets, keys: sshKeys) }
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
                    case .success(let services) where hasTestData:
                        RootView()
                            .environment(\.hostRepository, services.hostRepository)
                            .environment(\.exportRepository, services.exportRepository)
                            .environment(\.secretStore, secrets)
                            .environment(\.sshKeyStore, sshKeys)
                            .environment(\.appLock, appLock)
                            .environment(\.terminalSettings, terminalSettings)
                            .environment(\.hostConnector, services.hostConnector)
                            .environment(\.localNetworkNotice, localNetworkNotice)
                            .environment(\.backgroundConnectionTime, Launch.backgroundConnectionTime)
                            .environment(\.rememberedTabs, rememberedTabs)
                    case .success(let services):
                        Color.clear.task {
                            await Launch.addTestData(to: services.hostKeyRepository)
                            hasTestData = true
                        }
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
        if let directory = Launch.testDataDirectory {
            return try AppDatabase(directory: directory)
        }
        return try AppDatabase.openInAppGroup()
    }
}

/// What the screens read and write the database through, and connect with.
private struct Services {
    let hostRepository: HostRepository
    let exportRepository: ExportRepository
    let hostKeyRepository: HostKeyRepository
    let hostConnector: HostConnector

    init(database: AppDatabase, secrets: SecretStore, keys: SSHKeyStore) {
        hostRepository = HostRepository(database)
        exportRepository = ExportRepository(database)
        hostKeyRepository = HostKeyRepository(database)
        hostConnector = HostConnector(hostKeys: hostKeyRepository, secrets: secrets, keys: keys)
    }
}

/// How this launch runs. Debug builds take the options of the UI tests (UITests/TestApp.swift) from
/// the environment; release builds always run as they ship.
private enum Launch {
    #if DEBUG
        private static let environment = ProcessInfo.processInfo.environment
        /// UI tests start every launch with an empty database and settings of their own.
        private static let isUITesting = environment["SHELLO_UI_TESTING"] == "1"

        /// Where a UI test's database and remembered tabs live: a new directory at every launch, so
        /// that each test starts from no hosts; or, for a test that names its data
        /// (`SHELLO_UI_TESTING_DATA`), the same directory at every launch, so that it can terminate
        /// Shello and find its hosts and tabs in the next launch (RestoreTests).
        static let testDataDirectory: URL? =
            isUITesting
            ? URL.temporaryDirectory.appending(
                path: "UITests-\(environment["SHELLO_UI_TESTING_DATA"] ?? UUID().uuidString)",
                directoryHint: .isDirectory)
            : nil

        /// UI tests start every launch without SSH keys: the keys live in memory, not the Keychain.
        static var keepsSSHKeysInMemory: Bool { isUITesting }

        /// The simulator cannot make Secure Enclave keys. A UI test about them gets a stand-in, which
        /// keeps its keys in memory.
        static var standsInForSecureEnclave: Bool { environment["SHELLO_UI_TESTING_SECURE_ENCLAVE"] == "1" }

        /// A UI test that signs in with an SSH key starts with the test server's client key among the
        /// keys in memory: "private-key-in-base64 name", for TestServers/keys/client_ed25519.
        static var fixtureSSHKeys: [SSHKeyStore.FixtureKey] {
            let fields = environment["SHELLO_UI_TESTING_SSH_KEY"]?.split(separator: " ", maxSplits: 1).map(String.init)
            guard let fields, fields.count == 2, let privateKey = Data(base64Encoded: fields[0]) else { return [] }
            return [SSHKeyStore.FixtureKey(privateKey: privateKey, comment: fields[1])]
        }

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

        /// A UI test about the background has the connections close after this many seconds in it,
        /// rather than at the end of the time iOS grants, about half a minute.
        static var backgroundConnectionTime: Duration? {
            environment["SHELLO_UI_TESTING_BACKGROUND_SECONDS"].flatMap(Double.init).map { .seconds($0) }
        }

        /// A UI test about a changed host key starts with another key trusted for its server:
        /// "address port algorithm key-in-base64 fingerprint".
        private static var trustedHostKey: (server: Server, key: HostKey)? {
            let fields = environment["SHELLO_UI_TESTING_TRUSTED_HOST_KEY"]?.split(separator: " ").map(String.init)
            guard let fields, fields.count == 5, let port = UInt16(fields[1]),
                let key = Data(base64Encoded: fields[3])
            else { return nil }
            return (
                Server(address: fields[0], port: port),
                HostKey(algorithm: fields[2], wireRepresentation: key, fingerprint: fields[4])
            )
        }

        static var addsTestData: Bool { trustedHostKey != nil }

        /// Adds what the UI test asked for to the database, before the first screen shows.
        static func addTestData(to hostKeys: HostKeyRepository) async {
            guard let trustedHostKey else { return }
            do {
                try await hostKeys.trust(trustedHostKey.key, of: trustedHostKey.server)
            } catch {
                Logger(subsystem: "ch.shello.Shello", category: "Storage").error("Could not add test data: \(error)")
            }
        }

        static let settings: UserDefaults = {
            guard isUITesting else { return .standard }
            let suite = "ch.shello.Shello.UITests"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }()

        /// A UI test's remembered tabs go with its database.
        static var rememberedTabsFile: URL {
            testDataDirectory?.appending(path: rememberedTabsFileName) ?? shippedRememberedTabsFile
        }
    #else
        static let testDataDirectory: URL? = nil
        static let rememberedTabsFile = shippedRememberedTabsFile
        static let keepsSSHKeysInMemory = false
        static let standsInForSecureEnclave = false
        static let fixtureSSHKeys: [SSHKeyStore.FixtureKey] = []
        static let locksApp = true
        static let blinksCursor = true
        static let colorScheme: ColorScheme? = nil
        static let showsPrivacyCoverOnly = false
        static let backgroundConnectionTime: Duration? = nil
        static let settings = UserDefaults.standard
        static let addsTestData = false
        static func addTestData(to hostKeys: HostKeyRepository) async {}
    #endif

    private static let rememberedTabsFileName = "RememberedTabs.json"

    /// Where the windows remember their tabs: in the app's own container, as no extension restores
    /// tabs, rather than in the App Group's with the database.
    private static let shippedRememberedTabsFile = URL.applicationSupportDirectory.appending(
        path: rememberedTabsFileName, directoryHint: .notDirectory)
}
