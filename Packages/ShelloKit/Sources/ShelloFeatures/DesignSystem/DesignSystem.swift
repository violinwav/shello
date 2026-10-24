import CoreText
import Foundation
import ShelloTerminalUI
import os

/// The design system from the UI design (docs/ui/ui_v1/README.md, STACK section 7.13): the colour
/// tokens in `Palette`, the fonts in `Typography`, and SF Symbols for icons.
public enum DesignSystem {
    /// The bundle that holds the colour sets and the fonts.
    static let resourceBundle = Bundle.module

    /// Registers the bundled fonts with the app's process. Call it once at launch, before the first
    /// screen draws; later calls do nothing.
    public static func registerFonts() {
        _ = fontRegistration
    }

    /// JetBrains Mono for terminals, with the semibold face for bold text.
    static let terminalTypeface = TerminalTypeface(
        regular: FontFace.jetBrainsMonoRegular.postScriptName, bold: FontFace.jetBrainsMonoSemiBold.postScriptName)

    private static let fontRegistration: Void = {
        for face in FontFace.allCases {
            guard let url = face.url else {
                logger.error("Missing font file \(face.rawValue, privacy: .public)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let description = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown error"
                logger.error(
                    "Could not register font \(face.rawValue, privacy: .public): \(description, privacy: .public)")
            }
        }
    }()

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "DesignSystem")
}

/// The font files the app bundles: only the weights the screens use.
enum FontFace: String, CaseIterable {
    case geistRegular = "Geist-Regular"
    case geistMedium = "Geist-Medium"
    case jetBrainsMonoRegular = "JetBrainsMono-Regular"
    case jetBrainsMonoSemiBold = "JetBrainsMono-SemiBold"

    /// The font's PostScript name, which is also its file name.
    var postScriptName: String { rawValue }

    var url: URL? {
        DesignSystem.resourceBundle.url(forResource: rawValue, withExtension: "ttf", subdirectory: folder)
    }

    /// The family's folder in the bundle, next to its licence.
    private var folder: String {
        switch self {
        case .geistRegular, .geistMedium: "Geist"
        case .jetBrainsMonoRegular, .jetBrainsMonoSemiBold: "JetBrainsMono"
        }
    }
}
