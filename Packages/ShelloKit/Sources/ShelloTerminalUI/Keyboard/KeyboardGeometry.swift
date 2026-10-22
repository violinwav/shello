import UIKit

/// The sizes a keyboard is drawn at, after the UI design: on a phone, keys 44 points high and 5
/// apart in rows 10 apart, and the extra keys row's keys 42 points square and 6 apart. Keys are
/// larger on an iPad, smaller in landscape on a phone, where the keyboard would cover most of the
/// terminal, and grow a little with Dynamic Type, whose labels grow more.
nonisolated struct KeyboardMetrics: Equatable {
    var keyHeight: CGFloat
    var keySpacing: CGFloat
    var rowSpacing: CGFloat
    var insets: UIEdgeInsets
    var cornerRadius: CGFloat
    /// How much larger labels are than the design's sizes.
    var labelScale: CGFloat
    /// Bold Text: every label in the bold face.
    var boldText = false
    /// Increase Contrast: every key outlined.
    var highContrast = false

    /// The Shello keyboard's sizes for `traits`.
    @MainActor
    static func keyboard(for traits: UITraitCollection) -> KeyboardMetrics {
        let size = SizeClass(traits)
        var metrics: KeyboardMetrics
        switch size {
        case .phone:
            metrics = KeyboardMetrics(
                keyHeight: 44, keySpacing: 5, rowSpacing: 10,
                insets: UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6),
                cornerRadius: 7, labelScale: 1)
        case .phoneLandscape:
            metrics = KeyboardMetrics(
                keyHeight: 34, keySpacing: 5, rowSpacing: 6, insets: UIEdgeInsets(top: 6, left: 6, bottom: 4, right: 6),
                cornerRadius: 6, labelScale: 0.9)
        case .pad:
            metrics = KeyboardMetrics(
                keyHeight: 56, keySpacing: 8, rowSpacing: 10,
                insets: UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8),
                cornerRadius: 8, labelScale: 1.25)
        }
        metrics.grow(for: traits)
        return metrics
    }

    /// The extra keys row's sizes for `traits`. Its keys sit on the keyboard below, which has a
    /// margin of its own, so the row has none at the bottom.
    @MainActor
    static func extraKeysRow(for traits: UITraitCollection) -> KeyboardMetrics {
        var metrics: KeyboardMetrics
        switch SizeClass(traits) {
        case .phone:
            metrics = KeyboardMetrics(
                keyHeight: 42, keySpacing: 6, rowSpacing: 0, insets: UIEdgeInsets(top: 8, left: 6, bottom: 0, right: 6),
                cornerRadius: 9, labelScale: 1)
        case .phoneLandscape:
            metrics = KeyboardMetrics(
                keyHeight: 34, keySpacing: 6, rowSpacing: 0, insets: UIEdgeInsets(top: 6, left: 6, bottom: 0, right: 6),
                cornerRadius: 8, labelScale: 0.9)
        case .pad:
            metrics = KeyboardMetrics(
                keyHeight: 48, keySpacing: 8, rowSpacing: 0,
                insets: UIEdgeInsets(top: 10, left: 8, bottom: 0, right: 8),
                cornerRadius: 10, labelScale: 1.15)
        }
        metrics.grow(for: traits)
        return metrics
    }

    /// Dynamic Type: labels scale with the body text style, up to 1.6 times, the most that fits a
    /// letter key, and keys grow by half as much, so that the keyboard leaves room for the terminal.
    /// Bold Text and Increase Contrast apply too.
    @MainActor
    private mutating func grow(for traits: UITraitCollection) {
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits)
        let clamped = min(max(scale, 0.85), 1.6)
        labelScale *= clamped
        keyHeight = (keyHeight * (1 + max(clamped - 1, 0) / 2)).rounded()
        boldText = traits.legibilityWeight == .bold
        highContrast = traits.accessibilityContrast == .high
    }

    private enum SizeClass {
        case phone
        case phoneLandscape
        case pad

        @MainActor
        init(_ traits: UITraitCollection) {
            if traits.verticalSizeClass == .compact {
                self = .phoneLandscape
            } else if traits.horizontalSizeClass == .regular {
                self = .pad
            } else {
                self = .phone
            }
        }
    }
}

/// Where the keys go, and which key a point is on. Each key's touch area reaches halfway into the
/// gaps around it, and the keys at the edges reach the edges, so that no touch on the keyboard
/// misses.
nonisolated struct KeyboardGeometry: Equatable {
    struct Cap: Equatable {
        var key: KeyboardKey
        var frame: CGRect
        var touchFrame: CGRect
    }

    var caps: [Cap]
    var size: CGSize

    /// The Shello keyboard: rows that share a width between their keys, by the keys' widths.
    init(rows: [KeyboardRow], width: CGFloat, metrics: KeyboardMetrics) {
        let count = CGFloat(rows.count)
        let height =
            metrics.insets.top + metrics.insets.bottom + count * metrics.keyHeight
            + max(count - 1, 0) * metrics.rowSpacing
        size = CGSize(width: width, height: height)
        caps = []
        let available = width - metrics.insets.left - metrics.insets.right
        for (rowIndex, row) in rows.enumerated() {
            let y = metrics.insets.top + CGFloat(rowIndex) * (metrics.keyHeight + metrics.rowSpacing)
            let top = rowIndex == 0 ? 0 : y - metrics.rowSpacing / 2
            let bottom = rowIndex == rows.count - 1 ? height : y + metrics.keyHeight + metrics.rowSpacing / 2
            let units = row.keys.reduce(0) { $0 + $1.width } + 2 * row.inset
            let gaps = CGFloat(max(row.keys.count - 1, 0)) * metrics.keySpacing
            let unit = units > 0 ? max((available - gaps) / CGFloat(units), 0) : 0
            var x = metrics.insets.left + CGFloat(row.inset) * unit
            for (keyIndex, key) in row.keys.enumerated() {
                let keyWidth = CGFloat(key.width) * unit
                let frame = CGRect(x: x, y: y, width: keyWidth, height: metrics.keyHeight)
                let left = keyIndex == 0 ? 0 : x - metrics.keySpacing / 2
                let right = keyIndex == row.keys.count - 1 ? width : x + keyWidth + metrics.keySpacing / 2
                caps.append(
                    Cap(
                        key: key, frame: frame,
                        touchFrame: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
                x += keyWidth + metrics.keySpacing
            }
        }
    }

    /// The extra keys row: one row of keys at their own widths, in key heights, which scrolls
    /// when it is wider than the screen.
    init(row keys: [KeyboardKey], metrics: KeyboardMetrics) {
        let height = metrics.insets.top + metrics.keyHeight + metrics.insets.bottom
        caps = []
        var x = metrics.insets.left
        for (index, key) in keys.enumerated() {
            let keyWidth = (CGFloat(key.width) * metrics.keyHeight).rounded()
            let frame = CGRect(x: x, y: metrics.insets.top, width: keyWidth, height: metrics.keyHeight)
            let left = index == 0 ? 0 : x - metrics.keySpacing / 2
            let right = x + keyWidth + (index == keys.count - 1 ? metrics.insets.right : metrics.keySpacing / 2)
            caps.append(
                Cap(key: key, frame: frame, touchFrame: CGRect(x: left, y: 0, width: right - left, height: height)))
            x += keyWidth + metrics.keySpacing
        }
        size = CGSize(width: x - metrics.keySpacing + metrics.insets.right, height: height)
    }

    /// The key under `point`.
    func hit(at point: CGPoint) -> KeyTouches.Hit? {
        guard let index = caps.firstIndex(where: { $0.touchFrame.contains(point) }) else { return nil }
        let cap = caps[index]
        return KeyTouches.Hit(index: index, key: cap.key, frame: cap.frame, touchFrame: cap.touchFrame)
    }
}
