import SwiftUI

/// Typography for rendered message content.
///
/// Editorial direction: headings and pull-quotes set in New York (Apple's
/// serif) for magazine character, body text in SF sans for long-form
/// readability. Colours stay in `Theme`; this file owns type and spacing only,
/// and every value is expressed in points rather than as a ratio of anything, so
/// body copy never shrinks from its designed size.
enum MarkdownTheme {

    // MARK: - Body

    static let bodySize: CGFloat = 16.5
    /// Extra leading on wrapped lines. Comfortable for prose without looking
    /// loose in a compact bubble.
    static let bodyLineSpacing: CGFloat = 3
    /// Space between consecutive paragraph blocks. Replaces the old behaviour of
    /// drawing a literal blank line, which cost a full line height.
    static let paragraphSpacing: CGFloat = 8

    static var body: Font { .system(size: bodySize) }
    static var bodyBold: Font { .system(size: bodySize, weight: .semibold) }
    static var bodyItalic: Font { .system(size: bodySize).italic() }
    static var bodyBoldItalic: Font {
        .system(size: bodySize, weight: .semibold).italic()
    }
    static var strike: Font { .system(size: bodySize) }

    // MARK: - Headings (serif)

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        default: return 16
        }
    }

    static func heading(_ level: Int) -> Font {
        .system(size: headingSize(level), weight: .semibold, design: .serif)
    }

    /// Headings get more air above than below, so they group with the text they
    /// introduce rather than floating between sections.
    static func headingTopPadding(_ level: Int) -> CGFloat {
        level == 1 ? 12 : 10
    }
    static let headingBottomPadding: CGFloat = 5

    /// A hairline under H1/H2, the classic editorial section break.
    static func headingRuleVisible(_ level: Int) -> Bool { level <= 2 }

    // MARK: - Lists

    static let listItemSpacing: CGFloat = 6
    /// Fixed marker column so "•" and "10." line up, and so wrapped lines hang
    /// under the text rather than the marker.
    static let listMarkerColumnWidth: CGFloat = 20
    /// Gap between the marker column and the item's text.
    static let listMarkerGap: CGFloat = 6

    // MARK: - Code

    static let codeSize: CGFloat = 13
    static let inlineCodeSize: CGFloat = 15
    static var code: Font { .system(size: codeSize, design: .monospaced) }
    static var inlineCode: Font {
        .system(size: inlineCodeSize, design: .monospaced)
    }
    static let codeCornerRadius: CGFloat = 6
    static let codePadding: CGFloat = 8
    static let codeTopPadding: CGFloat = 6

    // MARK: - Quote

    static let quoteBarWidth: CGFloat = 3
    static let quoteLeadingPadding: CGFloat = 10
    static let quoteTopPadding: CGFloat = 2

    // MARK: - Rule

    static let ruleThickness: CGFloat = 0.5
    static let ruleVerticalPadding: CGFloat = 10

    // MARK: - Tints
    //
    // Derived from existing Theme colours so the editorial layer never
    // introduces a second palette.

    /// Code surfaces sit slightly recessed against the bubble.
    static func codeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.045)
    }

    static func inlineCodeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.055)
    }

    static func ruleColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.12)
    }

    static func listMarkerColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Theme.accent.opacity(0.9) : Theme.accentDeep
    }
}
