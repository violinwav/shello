import UIKit

/// How one key looks, worked out from the key, its state and the palette.
struct KeyFace: Equatable {
    enum Glyph: Equatable {
        case none
        /// The swipe key's four arrows around a dot in the accent colour.
        case arrows(UIColor, dot: UIColor)
        /// An SF Symbol, in the label's colour, at `weight`.
        case symbol(String, weight: UIImage.SymbolWeight)
    }

    var label: String
    var corner: String?
    var labelFont: UIFont
    var cornerFont: UIFont
    var background: UIColor
    var foreground: UIColor
    var cornerColor: UIColor
    var ring: UIColor?
    var isRound = false
    /// The hairline of shadow under a key of the keyboard; none on the extra keys row.
    var shadow: UIColor?
    /// A bar under the label, which marks a locked modifier without relying on colour.
    var isLocked = false
    /// How much larger than the design the bar is drawn: it grows with the labels.
    var markScale: CGFloat = 1
    var glyph = Glyph.none
}

/// One key drawn with Core Animation layers (STACK section 7.5): its cap, its label, its corner
/// symbol, its glyph and the bar of a locked modifier. Only what changed is set again.
final class KeyCap {
    let layer = CALayer()
    private let label = CATextLayer()
    private let corner = CATextLayer()
    private let lockBar = CALayer()
    private let ring = CAShapeLayer()
    private let arrows = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let symbol = CALayer()
    private var drawn: (face: KeyFace, size: CGSize, cornerRadius: CGFloat, scale: CGFloat)?

    init() {
        for text in [label, corner] {
            text.alignmentMode = .center
            text.isWrapped = false
            layer.addSublayer(text)
        }
        for sublayer in [lockBar, ring, arrows, dot, symbol] {
            layer.addSublayer(sublayer)
        }
        symbol.contentsGravity = .center
        ring.fillColor = nil
        ring.lineWidth = 1
        for each in [layer, label, corner, lockBar, ring, arrows, dot, symbol] {
            each.actions = Self.noAnimations
        }
    }

    /// A key changes at once, as the finger touches it. A text layer draws its new text after the
    /// transaction that set it, so turning animations off for that transaction is not enough.
    static let noAnimations: [String: any CAAction] = Dictionary(
        uniqueKeysWithValues: [
            "contents", "bounds", "position", "frame", "hidden", "opacity", "backgroundColor", "borderColor",
            "borderWidth", "cornerRadius", "shadowOpacity", "shadowPath", "path", "fillColor", "sublayers",
        ].map { ($0, NSNull()) })

    func draw(_ face: KeyFace, frame: CGRect, cornerRadius: CGFloat, scale: CGFloat) {
        layer.frame = frame
        if let drawn, drawn.face == face, drawn.size == frame.size, drawn.cornerRadius == cornerRadius,
            drawn.scale == scale
        {
            return
        }
        drawn = (face, frame.size, cornerRadius, scale)
        let bounds = CGRect(origin: .zero, size: frame.size)

        layer.backgroundColor = face.background.cgColor
        let radius = face.isRound ? min(bounds.width, bounds.height) / 2 : cornerRadius
        layer.cornerRadius = radius
        // A shape rather than the layer's border, which `render(in:)` draws with square sides.
        ring.isHidden = face.ring == nil
        ring.strokeColor = face.ring?.cgColor
        ring.frame = bounds
        ring.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius - 0.5).cgPath
        // The design's keys sit on a hairline of shadow: 0 1px 0 at 65 % black.
        layer.shadowColor = face.shadow?.cgColor
        layer.shadowOpacity = face.shadow == nil ? 0 : 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowPath = face.shadow == nil ? nil : UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath

        Self.set(label, text: face.label, font: face.labelFont, color: face.foreground, scale: scale)
        let lineHeight = ceil(face.labelFont.lineHeight)
        var labelY = ((bounds.height - lineHeight) / 2).rounded()

        corner.isHidden = face.corner == nil
        if let text = face.corner {
            Self.set(corner, text: text, font: face.cornerFont, color: face.cornerColor, scale: scale)
            let size = (text as NSString).size(withAttributes: [.font: face.cornerFont])
            let inset = face.cornerFont.pointSize * 0.4
            corner.frame = CGRect(
                x: bounds.width - ceil(size.width) - inset, y: inset * 0.75, width: ceil(size.width),
                height: ceil(face.cornerFont.lineHeight))
            // At large text sizes the label moves down, as far as the key allows, until the top of
            // a tall letter clears the corner symbol.
            let clear = corner.frame.maxY + 1 - (face.labelFont.ascender - face.labelFont.capHeight)
            labelY = min(max(labelY, clear.rounded(.up)), max(bounds.height - lineHeight, labelY))
        }
        label.frame = CGRect(x: 0, y: labelY, width: bounds.width, height: lineHeight)

        lockBar.isHidden = !face.isLocked
        lockBar.backgroundColor = face.foreground.cgColor
        let barWidth = (12 * face.markScale).rounded()
        let barHeight = (2 * face.markScale).rounded()
        lockBar.cornerRadius = barHeight / 2
        lockBar.frame = CGRect(
            x: ((bounds.width - barWidth) / 2).rounded(), y: bounds.height - (5 * face.markScale).rounded() - barHeight,
            width: barWidth, height: barHeight)

        drawGlyph(face, in: bounds, scale: scale)
    }

    private func drawGlyph(_ face: KeyFace, in bounds: CGRect, scale: CGFloat) {
        arrows.isHidden = true
        dot.isHidden = true
        symbol.isHidden = true
        switch face.glyph {
        case .none:
            break
        case .arrows(let color, let dotColor):
            // The design's 26-point drawing on its 42-point key, scaled to this key.
            let unit = min(bounds.width, bounds.height) / 42
            let origin = CGPoint(x: bounds.midX - 13 * unit, y: bounds.midY - 13 * unit)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
            }
            let path = UIBezierPath()
            for triangle in [
                [point(13, 2.5), point(16, 6), point(10, 6)], [point(13, 23.5), point(16, 20), point(10, 20)],
                [point(2.5, 13), point(6, 10), point(6, 16)], [point(23.5, 13), point(20, 10), point(20, 16)],
            ] {
                path.move(to: triangle[0])
                path.addLine(to: triangle[1])
                path.addLine(to: triangle[2])
                path.close()
            }
            arrows.path = path.cgPath
            arrows.fillColor = color.cgColor
            arrows.isHidden = false
            dot.path =
                UIBezierPath(
                    arcCenter: point(13, 13), radius: 2.6 * unit, startAngle: 0, endAngle: 2 * .pi, clockwise: true
                )
                .cgPath
            dot.fillColor = dotColor.cgColor
            dot.isHidden = false
        case .symbol(let name, let weight):
            let configuration = UIImage.SymbolConfiguration(pointSize: face.labelFont.pointSize * 1.2, weight: weight)
            guard let image = UIImage(systemName: name, withConfiguration: configuration) else { break }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let tinted = image.withTintColor(face.foreground, renderingMode: .alwaysOriginal)
            let rendered = UIGraphicsImageRenderer(size: tinted.size, format: format).image { _ in
                tinted.draw(at: .zero)
            }
            symbol.contents = rendered.cgImage
            symbol.contentsScale = scale
            symbol.frame = CGRect(
                x: (bounds.width - tinted.size.width) / 2, y: (bounds.height - tinted.size.height) / 2,
                width: tinted.size.width, height: tinted.size.height)
            symbol.isHidden = false
        }
    }

    private static func set(_ layer: CATextLayer, text: String, font: UIFont, color: UIColor, scale: CGFloat) {
        layer.contentsScale = scale
        layer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

/// The bubble over a key: the symbol a flick types, or the alternates of a long-press, with the
/// one under the finger in the accent colour and drawn larger, so that the selection does not rely
/// on colour alone.
final class KeyCalloutView {
    let layer = CALayer()
    private var items: [CATextLayer] = []
    private let selection = CALayer()

    init() {
        layer.isHidden = true
        layer.cornerRadius = 10
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.zPosition = 10
        selection.cornerRadius = 7
        layer.addSublayer(selection)
        layer.actions = KeyCap.noAnimations
        selection.actions = KeyCap.noAnimations
    }

    func draw(
        _ callout: KeyTouches.Callout?, text: (String) -> String, font: UIFont, palette: KeyboardPalette, scale: CGFloat
    ) {
        guard let callout, let first = callout.frames.first, let last = callout.frames.last else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        let frame = first.union(last).insetBy(dx: -4, dy: -4)
        layer.frame = frame
        layer.backgroundColor = palette.callout.cgColor
        layer.shadowColor = UIColor.black.cgColor
        while items.count < callout.items.count {
            let item = CATextLayer()
            item.alignmentMode = .center
            item.actions = KeyCap.noAnimations
            layer.addSublayer(item)
            items.append(item)
        }
        let selectedFont = font.withSize(font.pointSize * 1.15)
        for (index, item) in items.enumerated() {
            guard index < callout.items.count else {
                item.isHidden = true
                continue
            }
            item.isHidden = false
            let isSelected = index == callout.selection
            let itemFont = isSelected ? selectedFont : font
            let lineHeight = ceil(itemFont.lineHeight)
            let itemFrame = callout.frames[index].offsetBy(dx: -frame.minX, dy: -frame.minY)
            item.contentsScale = scale
            item.string = NSAttributedString(
                string: text(callout.items[index]),
                attributes: [.font: itemFont, .foregroundColor: isSelected ? palette.onAccent : palette.label])
            item.frame = CGRect(
                x: itemFrame.minX, y: itemFrame.midY - lineHeight / 2, width: itemFrame.width, height: lineHeight)
            if isSelected {
                selection.frame = itemFrame.insetBy(dx: 2, dy: 2)
            }
        }
        selection.backgroundColor = palette.accent.cgColor
    }
}

/// A key as VoiceOver, Voice Control and Switch Control see it: a keyboard key with its spoken
/// name, whose activation presses it. Its actions type its corner symbol and alternates.
final class KeyAccessibilityElement: UIAccessibilityElement {
    var press: () -> Void = {}
    /// Where an assistive technology that touches the key rather than activating it puts its
    /// finger, in the container's coordinates, if not in the middle of the key's frame.
    var activationPointInContainerSpace: CGPoint?

    override func accessibilityActivate() -> Bool {
        press()
        return true
    }

    override var accessibilityActivationPoint: CGPoint {
        get {
            guard let point = activationPointInContainerSpace, let container = accessibilityContainer as? UIView else {
                return super.accessibilityActivationPoint
            }
            return UIAccessibility.convertToScreenCoordinates(CGRect(origin: point, size: .zero), in: container).origin
        }
        set {
            super.accessibilityActivationPoint = newValue
        }
    }
}
