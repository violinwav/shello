import Foundation
import ShelloFeatures
import ShelloStorage
import SwiftUI
import os

/// Composition root. Services are created here and passed to the screens through the SwiftUI environment.
@main
struct ShelloApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// The one database of the app, opened once at launch, or why it could not be opened.
    private let hostRepository: Result<HostRepository, any Error>

    init() {
        DesignSystem.registerFonts()
        hostRepository = Result { HostRepository(try Self.openDatabase()) }
        if case .failure(let error) = hostRepository {
            Logger(subsystem: "ch.shello.Shello", category: "Storage").error("Could not open the database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch hostRepository {
            case .success(let repository):
                RootView()
                    .environment(\.hostRepository, repository)
            case .failure(let error):
                DatabaseUnavailableView(error: error)
            }
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
    }

    private static func openDatabase() throws -> AppDatabase {
        #if DEBUG
            // UI tests start every launch with an empty database of its own (UITests/).
            if ProcessInfo.processInfo.environment["SHELLO_UI_TESTING"] == "1" {
                return try AppDatabase(
                    directory: URL.temporaryDirectory.appending(path: "UITests-\(UUID().uuidString)"))
            }
        #endif
        return try AppDatabase.openInAppGroup()
    }
}
