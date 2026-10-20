import ShelloModel
import SwiftUI

/// A section header in the design's style: JetBrains Mono in capitals.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Typography.sectionHeader)
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(Palette.textTertiary)
            // VoiceOver reads the words, not the capitals.
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The tile that shows a host's protocol. It is decoration: the host's row says the protocol to
/// VoiceOver.
struct ProtocolBadge: View {
    let hostProtocol: HostProtocol
    @ScaledMetric(relativeTo: .body) private var size = 38

    var body: some View {
        Text(hostProtocol.badgeTitle)
            .font(Typography.badge)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize()
            .frame(width: size, height: size)
            .background(Palette.tile, in: .rect(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

/// A colour dot and a name: a tag's, or a colour's in the colour picker. A plain stack rather than a
/// `Label`: the accessibility audit takes a label's icon colour for its text colour.
struct ColorLabel: View {
    let color: Tag.Color
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            TagDot(color: color)
            Text(name)
        }
    }
}

/// A tag's colour, always shown next to the tag's or the colour's name.
struct TagDot: View {
    let color: Tag.Color
    @ScaledMetric private var size: CGFloat

    /// A dot `diameter` points wide at the default text size, growing with the text style.
    init(color: Tag.Color, diameter: CGFloat = 10, relativeTo textStyle: Font.TextStyle = .body) {
        self.color = color
        _size = ScaledMetric(wrappedValue: diameter, relativeTo: textStyle)
    }

    var body: some View {
        Circle()
            .fill(Palette.tag(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A host's tags, a dot and the name for each, wrapping onto more lines when they do not fit.
struct TagLine: View {
    let tags: [Tag]

    var body: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 2) {
            ForEach(tags) { tag in
                HStack(spacing: 4) {
                    TagDot(color: tag.color, diameter: 7, relativeTo: .footnote)
                    Text(tag.name)
                }
            }
        }
        .font(Typography.footnote)
        .foregroundStyle(Palette.textSecondary)
    }
}

/// Lays its views out in rows like words in a paragraph: left to right, starting a new row when the
/// next one does not fit.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            // A view wider than a whole row gets the row's width, and wraps inside it.
            if size.width > maxWidth {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if !row.items.isEmpty, row.width + horizontalSpacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : horizontalSpacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }
}

/// A field with its label beside it, or above it at accessibility text sizes. Give the field the
/// same label for VoiceOver: a field inside a row reads only its placeholder otherwise. The visible
/// label is then hidden from VoiceOver, which would stop on it and on the field.
struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityHidden(true)
            field
        }
    }
}

/// A row's value next to its label, in the secondary text token. `LabeledContent` draws values in the
/// system's secondary colour, which is about 3.5:1 on a white cell; the token keeps 8:1.
struct ValueText: View {
    let text: String
    var font: Font?

    init(_ text: String, font: Font? = nil) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Palette.textSecondary)
    }
}

/// Text under a group of rows, in the secondary text colour, which keeps 4.5:1 contrast on the
/// ground in both appearances.
struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Typography.footnote)
            .foregroundStyle(Palette.textSecondary)
    }
}

/// Why a screen has nothing to show. The description uses the secondary text colour, which keeps
/// 4.5:1 contrast on the ground; the system's own empty states draw it lighter.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    let actions: Actions

    init(title: String, systemImage: String, description: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
                .foregroundStyle(Palette.textSecondary)
        } actions: {
            actions
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, description: String) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

extension View {
    /// A prominent button in the design's style: filled with Tiffany in both appearances, with its
    /// label in the dark on-accent colour, 7.7:1 against the fill. The accent tint used elsewhere is
    /// dark in light mode, so a fill in it would need a light label in one appearance and a dark one
    /// in the other.
    func accentFill() -> some View {
        tint(Palette.accent)
            .foregroundStyle(Palette.onAccent)
    }

    /// A prominent toolbar button, such as Save. iOS draws its symbol in a light colour of its own,
    /// so the fill is the deep accent in both appearances rather than Tiffany.
    func prominentToolbarButton() -> some View {
        tint(Palette.accentDeep)
    }

    /// A destructive button's title in the error token: the system's red is about 3.6:1 on a white
    /// cell, the token 5.6:1.
    func destructiveStyle() -> some View {
        foregroundStyle(Palette.statusError)
    }
}

/// A problem with a field, under the field: an icon and a sentence, not only a colour.
struct ProblemText: View {
    let problem: String

    var body: some View {
        Label(problem, systemImage: "exclamationmark.circle.fill")
            .font(Typography.footnote)
            .foregroundStyle(Palette.statusError)
    }
}
