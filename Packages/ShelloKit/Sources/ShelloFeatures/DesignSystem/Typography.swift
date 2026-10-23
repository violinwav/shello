import SwiftUI

/// The type roles of the UI design: Geist for interface text, JetBrains Mono for data such as
/// addresses and commands, and for section headers. Each role scales with Dynamic Type relative to
/// the system text style of the same size.
enum Typography {
    /// A title inside a screen's content, such as the locked screen's.
    static let title = Font.custom(FontFace.jetBrainsMonoSemiBold.postScriptName, size: 28, relativeTo: .title)
    /// Labels and running text.
    static let body = Font.custom(FontFace.geistRegular.postScriptName, size: 17, relativeTo: .body)
    /// A host's name in a list.
    static let rowTitle = Font.custom(FontFace.geistMedium.postScriptName, size: 17, relativeTo: .body)
    /// Explanations under a group of fields, and other small text.
    static let footnote = Font.custom(FontFace.geistRegular.postScriptName, size: 13, relativeTo: .footnote)
    /// Filter chips and tag names.
    static let chip = Font.custom(FontFace.geistMedium.postScriptName, size: 15, relativeTo: .subheadline)
    /// Values the user types or reads exactly: names, addresses, users, ports, commands.
    static let data = Font.custom(FontFace.jetBrainsMonoRegular.postScriptName, size: 16, relativeTo: .body)
    /// A host's user and address under its name.
    static let dataCaption = Font.custom(
        FontFace.jetBrainsMonoRegular.postScriptName, size: 13, relativeTo: .footnote)
    /// Section headers, set in capitals.
    static let sectionHeader = Font.custom(
        FontFace.jetBrainsMonoSemiBold.postScriptName, size: 12, relativeTo: .caption)
    /// The protocol on a host's badge.
    static let badge = Font.custom(FontFace.jetBrainsMonoSemiBold.postScriptName, size: 10, relativeTo: .caption2)
    /// A tab's name in the tab bar.
    static let tab = Font.custom(FontFace.jetBrainsMonoRegular.postScriptName, size: 13, relativeTo: .footnote)
    /// The selected tab's name in the tab bar.
    static let selectedTab = Font.custom(
        FontFace.jetBrainsMonoSemiBold.postScriptName, size: 13, relativeTo: .footnote)
}
