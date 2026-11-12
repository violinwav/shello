import UIKit

/// The monospaced font family a terminal draws its text in, by the PostScript names of its faces.
/// The app passes JetBrains Mono, which it bundles (STACK section 7.13); a face that is not
/// registered falls back to the system's monospaced font.
nonisolated public struct TerminalTypeface: Equatable, Sendable {
    public var regular: String
    /// The face for bold text.
    public var bold: String

    public init(regular: String, bold: String) {
        self.regular = regular
        self.bold = bold
    }

    /// The system's monospaced font, SF Mono.
    public static let system = TerminalTypeface(regular: "", bold: "")

    /// The four faces a terminal needs at `size` points. The family has no italic face, so italic
    /// text is slanted by the font's own matrix, as CoreText does for families without one.
    func fonts(size: CGFloat) -> Fonts {
        let regular = UIFont(name: self.regular, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont(name: self.bold, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
        return Fonts(regular: regular, bold: bold, italic: Self.slanted(regular), boldItalic: Self.slanted(bold))
    }

    /// The faces SwiftTerm draws with.
    struct Fonts {
        let regular: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
    }

    /// A slant of 12 degrees, close to the angle of italic faces in monospaced families.
    private static func slanted(_ font: UIFont) -> UIFont {
        let slant = CGAffineTransform(a: 1, b: 0, c: tan(12 * .pi / 180), d: 1, tx: 0, ty: 0)
        return UIFont(descriptor: font.fontDescriptor.withMatrix(slant), size: font.pointSize)
    }
}
