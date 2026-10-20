import ShelloModel
import SwiftUI

/// A host in the list: its protocol, name, user and address, and its tags.
struct HostRow: View {
    let host: Host
    let tags: [Tag]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the badge moves above the text, which then has the full width.
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            ProtocolBadge(hostProtocol: host.protocol)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(host.name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    if host.isFavorite {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(Palette.accentInk)
                    }
                }
                Text(host.connectionSummary)
                    .font(Typography.dataCaption)
                    .foregroundStyle(Palette.textTertiary)
                if !tags.isEmpty {
                    TagLine(tags: tags)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// What VoiceOver reads after the host's name: protocol, user and address, favourite, tags.
    static func accessibilityValue(of host: Host, tags: [Tag]) -> String {
        var parts = [host.protocol.displayName, host.spokenConnectionSummary]
        if host.isFavorite {
            parts.append("Favorite")
        }
        if !tags.isEmpty {
            parts.append("Tags: " + tags.map(\.name).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}
