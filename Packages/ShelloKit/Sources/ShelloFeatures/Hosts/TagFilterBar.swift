import ShelloModel
import SwiftUI

/// The tag filters above the host list: All, then one chip per tag. One filter applies at a time.
struct TagFilterBar: View {
    let tags: [Tag]
    @Binding var selection: Tag.ID?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                FilterChip(title: "All", color: nil, isSelected: selection == nil) {
                    selection = nil
                }
                .accessibilityLabel("All Tags")
                .accessibilityInputLabels(["All", "All Tags"])
                ForEach(tags) { tag in
                    FilterChip(title: tag.name, color: tag.color, isSelected: selection == tag.id) {
                        selection = selection == tag.id ? nil : tag.id
                    }
                }
            }
            // In line with the section headers below.
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag Filter")
    }
}

/// A filter chip. The selected chip is filled and checked, so that the selection never depends on
/// colour alone.
struct FilterChip: View {
    let title: String
    let color: Tag.Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isSelected {
                    // VoiceOver hears "selected" from the trait below.
                    Image(systemName: "checkmark")
                        .fontWeight(.bold)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                } else if let color {
                    TagDot(color: color)
                }
                Text(title)
                    .font(Typography.chip)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Palette.ground : Palette.textSecondary)
            .background(isSelected ? Palette.textPrimary : Palette.cell, in: .capsule)
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(Palette.hairline)
                }
            }
            // The chip looks compact but takes taps on a whole touch target.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
