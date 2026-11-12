import SwiftUI

/// One of the host editor's port forwards (README section 4): its name, or else its destination,
/// what it does, and Off when it is off; side by side, or stacked at accessibility text sizes, where
/// Off beside them would break the title in the middle of a word. VoiceOver reads it as one element,
/// the state first, "to" for the arrow and a port as a port. A forward that is not complete keeps its
/// name, and says so by a symbol and in words.
///
/// It turns off and on, and is deleted, from its own screen, from a swipe, which VoiceOver and Switch
/// Control offer as its actions, and from its menu, for a long press, a pointer and Voice Control.
struct PortForwardRow<Destination: View>: View {
    let forward: PortForwardDraft
    let focus: AccessibilityFocusState<HostEditorModel.PortForwardFocus?>.Binding
    /// Turns the forward on or off; it gets the forward's spoken title, for the announcement.
    let setEnabled: (PortForwardDraft, String, Bool) -> Void
    /// Deletes the forward; it gets the forward's spoken title, for the announcement.
    let delete: (PortForwardDraft, String) -> Void
    @ViewBuilder let destination: () -> Destination
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let complete = forward.forward
        let name = forward.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = complete.map(PortForwardDisplay.title) ?? (name.isEmpty ? "Incomplete Port Forward" : name)
        let spokenTitle = complete.map(PortForwardDisplay.spokenTitle) ?? title
        let detail = complete.map(PortForwardDisplay.summary) ?? "Not complete. Open it to finish it."
        let spokenDetail = complete.map(PortForwardDisplay.spokenSummary) ?? detail
        let toggleTitle = forward.isEnabled ? "Turn Off" : "Turn On"
        let toggleSymbol = forward.isEnabled ? "pause.circle" : "play.circle"
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout =
            isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        NavigationLink(destination: destination) {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if complete == nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.statusError)
                        }
                        Text(title)
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    Text(detail)
                        .font(Typography.dataCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: isStacked ? nil : .infinity, alignment: .leading)
                if !forward.isEnabled {
                    ValueText("Off")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenTitle)
            .accessibilityValue(forward.isEnabled ? spokenDetail : "Off. \(spokenDetail)")
            .accessibilityInputLabels(spokenTitle == title ? [title] : [title, spokenTitle])
        }
        .accessibilityIdentifier("port-forward")
        .accessibilityFocused(focus, equals: .row(forward.id))
        .contextMenu {
            Button(toggleTitle, systemImage: toggleSymbol) { setEnabled(forward, spokenTitle, !forward.isEnabled) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(forward, spokenTitle) }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(forward, spokenTitle) }
            Button(toggleTitle, systemImage: toggleSymbol) { setEnabled(forward, spokenTitle, !forward.isEnabled) }
                .tint(Palette.accentDeep)
        }
    }
}
