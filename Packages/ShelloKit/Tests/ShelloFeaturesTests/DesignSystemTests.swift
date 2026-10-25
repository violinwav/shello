import ShelloModel
import Testing
import UIKit

@testable import ShelloFeatures

struct DesignSystemTests {
    @Test(arguments: ["Geist-Regular", "Geist-Medium", "JetBrainsMono-Regular", "JetBrainsMono-SemiBold"])
    func bundledFontIsAvailableOnceRegistered(_ postScriptName: String) {
        DesignSystem.registerFonts()

        #expect(UIFont(name: postScriptName, size: 17) != nil)
    }

    @Test func registeringTwiceIsHarmless() {
        DesignSystem.registerFonts()
        DesignSystem.registerFonts()

        #expect(UIFont(name: "Geist-Regular", size: 17)?.familyName == "Geist")
    }

    /// The surface, text and accent tokens from docs/ui/ui_v1/README.md. Accent text is darkened to
    /// 52 % in light mode, as the System board says.
    @Test(arguments: [
        ("Ground", 0xF2F3F5, 0x0A0B0D),
        ("Cell", 0xFFFFFF, 0x15171A),
        ("Tile", 0xEEF0F2, 0x2B2E33),
        ("Hairline", 0xE0E2E6, 0x23262B),
        ("TextPrimary", 0x111316, 0xEDEFF2),
        ("TextSecondary", 0x4A5058, 0xA3A9B1),
        ("TextTertiary", 0x60666E, 0x868C94),
        ("Accent", 0x0ABAB5, 0x0ABAB5),
        ("AccentInk", 0x05615E, 0x0ABAB5),
        ("AccentDeep", 0x05615E, 0x05615E),
        ("OnAccent", 0x16130B, 0x16130B),
        ("StatusOnline", 0x1F9D63, 0x46D39A),
        ("StatusError", 0xC6282D, 0xFF6B5E),
    ])
    func colorTokenHasTheDesignsLightAndDarkValues(_ name: String, light: Int, dark: Int) throws {
        #expect(try rgb(of: name, in: .light) == light)
        #expect(try rgb(of: name, in: .dark) == dark)
    }

    /// The design draws the same tag in a different shade per appearance: Production is #FF6B5E in
    /// dark mode and #E5484D in light mode, Homelab #7CCBFF and #2B8FD6, Staging #B9A4FF and #7C66E0.
    @Test(arguments: [
        (Tag.Color.red, 0xE5484D, 0xFF6B5E),
        (.blue, 0x2B8FD6, 0x7CCBFF),
        (.purple, 0x7C66E0, 0xB9A4FF),
    ])
    func tagColorUsesTheDesignsShadePerAppearance(_ color: Tag.Color, light: Int, dark: Int) throws {
        #expect(try rgb(of: Palette.assetName(of: color), in: .light) == light)
        #expect(try rgb(of: Palette.assetName(of: color), in: .dark) == dark)
    }

    @Test(arguments: Tag.Color.allCases)
    func everyTagColorHasAColorSetAndAName(_ color: Tag.Color) throws {
        _ = try rgb(of: Palette.assetName(of: color), in: .light)
        #expect(!color.displayName.isEmpty)
    }

    @Test func tagColorNamesAreDistinct() {
        let names = Tag.Color.allCases.map(\.displayName)

        #expect(Set(names).count == names.count)
    }

    /// The colour set's sRGB value in `style`, as 0xRRGGBB.
    private func rgb(of name: String, in style: UIUserInterfaceStyle) throws -> Int {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let color = try #require(UIColor(named: name, in: DesignSystem.resourceBundle, compatibleWith: traits))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return channels[0] << 16 | channels[1] << 8 | channels[2]
    }
}
