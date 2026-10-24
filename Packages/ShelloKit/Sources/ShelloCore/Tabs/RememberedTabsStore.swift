import Foundation
import ShelloModel
import os

/// Where each window's tabs are remembered for Restore (GLOSSARY): a file of its own, not the
/// database, since open tabs are neither synced nor exported (README section 15). Each window's
/// are kept under the identifier of its scene session (`UISceneSession.persistentIdentifier`), which
/// iOS keeps for the window when it terminates Shello, and when the user closes Shello from the app
/// switcher (STACK section 7.13). Each change is written at once: the scene state iOS keeps for a
/// window (`@SceneStorage`) is saved only as the window goes to the background, so a kill while
/// Shello is in front, or a crash, would lose what changed since.
///
/// A window that iOS discards takes its tabs with it, as when the user closes a window on iPad.
/// Only the first window of a launch, if iOS made it anew, takes over the tabs of a window that iOS
/// discarded while Shello was not running: those that changed last. iOS discards every window as it
/// installs a new build of Shello.
@MainActor
public final class RememberedTabsStore {
    private let file: URL
    private let openWindows: @MainActor () -> Set<String>
    private let now: @MainActor () -> Date
    private var windows: [String: Window]
    /// Whether a window appeared since this store was opened, which is once a launch.
    private var hasSeenAWindow = false

    /// The windows' tabs in `file`, which iOS keeps the windows of `openWindows` for: the
    /// identifiers of the scene sessions it has (`UIApplication.openSessions`). `now` times each
    /// change.
    public init(
        file: URL, openWindows: @escaping @MainActor () -> Set<String>,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.file = file
        self.openWindows = openWindows
        self.now = now
        windows = Self.read(file)
    }

    /// The window `id` appeared: the tabs it can restore. Those it remembers if iOS kept it; for the
    /// first window of a launch that iOS made anew, those it took over; otherwise none.
    public func windowAppeared(_ id: String) -> RememberedTabs {
        let open = openWindows()
        let discarded = windows.keys.filter { $0 != id && !open.contains($0) }
        if !hasSeenAWindow, windows[id] == nil {
            // The tabs that changed last, of the discarded windows that had some.
            let withTabs = discarded.compactMap { windows[$0] }.filter { !$0.tabs.isEmpty }
            windows[id] = withTabs.max { $0.changedAt < $1.changedAt }
        }
        hasSeenAWindow = true
        for window in discarded {
            windows[window] = nil
        }
        let tabs = windows[id]?.tabs ?? .empty
        // Known from now on, with no tabs yet: never takes over another window's.
        windows[id] = windows[id] ?? Window(tabs: .empty, changedAt: now())
        write()
        return tabs
    }

    /// Keeps `tabs` as what the window `id` has open now. The tabs of windows that iOS discarded
    /// meanwhile, as one the user closed, go.
    public func remember(_ tabs: RememberedTabs, ofWindow id: String) {
        let open = openWindows()
        for window in windows.keys where window != id && !open.contains(window) {
            windows[window] = nil
        }
        windows[id] = Window(tabs: tabs, changedAt: now())
        write()
    }

    // MARK: - The file

    /// A window's tabs, and when they last changed.
    private struct Window: Codable {
        var tabs: RememberedTabs
        var changedAt: Date
    }

    /// What the file holds. A newer version is read as no tabs: its format may differ.
    private struct Contents: Codable {
        static let currentVersion = 1

        var version: Int
        var windows: [String: Window]
    }

    private static func read(_ file: URL) -> [String: Window] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            logger.error("Could not read the remembered tabs: \(error)")
            return [:]
        }
        do {
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard contents.version == Contents.currentVersion else {
                logger.notice("The remembered tabs have version \(contents.version), which this Shello does not read")
                return [:]
            }
            return contents.windows
        } catch {
            logger.error("Could not read the remembered tabs: \(error)")
            return [:]
        }
    }

    private func write() {
        do {
            let data = try JSONEncoder().encode(Contents(version: Contents.currentVersion, windows: windows))
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Self.logger.error("Could not remember the tabs: \(error)")
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Tabs")
}
