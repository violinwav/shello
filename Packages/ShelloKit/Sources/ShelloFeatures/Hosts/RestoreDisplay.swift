import Foundation

// How the tabs to restore (GLOSSARY: Restore) read under Live in the host list, and to VoiceOver.

enum RestoreDisplay {
    /// The title of the row that restores every offered tab: "Restore 3 Tabs".
    static func restoreAll(count: Int) -> String {
        count == 1 ? "Restore 1 Tab" : "Restore \(count) Tabs"
    }

    /// The offered tabs' names, in their order, as the row under its title shows them: "web, db".
    static func shown(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }

    /// The offered tabs' names as VoiceOver reads them, as a list: "web, db and nas".
    static func spoken(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }

    /// What restoring every tab does beyond the row's title, for VoiceOver: the tab at `connecting`
    /// connects at once, which may ask for Face ID, and the others wait until they are selected.
    /// Nothing for one tab, whose title says it all.
    static func restoreAllHint(names: [String], connecting: Int?) -> String {
        guard names.count > 1 else { return "" }
        guard let connecting, names.indices.contains(connecting) else {
            return "Opens them. Each connects once you select it."
        }
        return "Connects \(names[connecting]) now, and the others once you select them."
    }

    /// What Don't Restore does beyond its title, for VoiceOver.
    static let dontRestoreHint = "Forgets these tabs without connecting. Shello doesn’t offer them again."

    /// The note under the offer for the remembered tabs left out, because their host was deleted.
    static func leftOut(count: Int) -> String {
        count == 1
            ? "One tab can’t be restored: its host was deleted."
            : "\(count) tabs can’t be restored: their hosts were deleted."
    }

    /// What VoiceOver hears once the `count` offered tabs are dismissed, and their rows have gone.
    static func dismissed(count: Int) -> String {
        count == 1 ? "Won’t restore the tab" : "Won’t restore the \(count) tabs"
    }
}
