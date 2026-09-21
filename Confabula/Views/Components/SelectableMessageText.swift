import SwiftUI
import UIKit

// MARK: - Document builder

/// Renders a whole message — plain prose or markdown — as **one** attributed
/// string, laid out inside a single selectable text view.
///
/// This is the selection renderer. The bubble previously drew each markdown
/// block as its own SwiftUI view, which made beautiful lists and code surfaces
/// but stopped selection at every view's edge. One attributed document gives
/// the reader the entire reply as a single selectable surface: drag from a
/// heading through a list into a paragraph and copy exactly that span.
///
/// Fidelity decisions:
/// - Copying yields the rendered characters, not raw markdown. Copying the
///   source stays on the bubble's action menu.
/// - Quote bars are drawn as accent-coloured bar glyphs per line; rules as an
///   em-dash run; code tint travels on the characters. These read correctly
///   while keeping one text document.
/// - Long code lines wrap rather than scroll horizontally; the bubble width
///   cap still governs.
enum MessageDocumentBuilder {

    static func build(analysis: MessageContent.Analysis,
                      scheme: ColorScheme) -> NSAttributedString {
        switch analysis {
        case .plain(let text):
            return plain(text)
        case .rich(let blocks):
            return rich(blocks, scheme: scheme)
        }
    }

    /// Width the document needs when nothing wraps — the bubble's natural
    /// "hug" width for short content.
    static func idealWidth(of document: NSAttributedString) -> CGFloat {
        // A finite constraint avoids overflow in the text layout engine.
        let unbounded: CGFloat = 1_000_000
        return ceil(document.boundingRect(
            with: CGSize(width: unbounded, height: unbounded),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width)
    }

    // MARK: Plain prose

    private static func plain(_ text: String) -> NSAttributedString {
        let source = text.isEmpty ? " " : text
        let output = NSMutableAttributedString(string: source)
        apply(bodyParagraph(), to: output)
        guard LinkDetector.mightContainLink(source) else { return output }
        let length = output.length
        for link in LinkDetector.links(in: source) {
            let range = link.range
            guard range.location != NSNotFound,
                  range.location + range.length <= length
            else { continue }
            output.addAttribute(.link, value: link.url, range: range)
            output.addAttribute(.foregroundColor,
                                value: UIColor(Theme.linkBlue), range: range)
            output.addAttribute(.underlineStyle,
                                value: NSUnderlineStyle.single.rawValue,
                                range: range)
        }
        return output
    }

    // MARK: Markdown blocks

    private static func rich(_ blocks: [MDBlock],
                             scheme: ColorScheme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { appendBlockSeparator(to: output) }
            append(block: block, to: output, scheme: scheme, indent: 0)
        }
        // Block separators are inserted before blocks, so any terminal newline
        // belongs to the source (notably fenced code) and must not be trimmed.
        return output
    }

    /// Appends one block. `indent` carries nesting (list items, quotes) so
    /// wrapped lines align under their parent text.
    private static func append(block: MDBlock,
                               to output: NSMutableAttributedString,
                               scheme: ColorScheme,
                               indent: CGFloat) {
        switch block {
        case .paragraph(let runs):
            output.append(runs: runs, scheme: scheme,
                          paragraph: bodyParagraph(indent: indent))

        case .heading(let level, let runs):
            output.append(runs: runs, scheme: scheme,
                          font: UIFont.systemFont(
                              ofSize: MarkdownTheme.headingSize(level),
                              weight: .semibold
                          ).serif(),
                          color: nil,
                          paragraph: headingParagraph(level: level, indent: indent))

        case .bulletList(let items):
            appendList(items, markers: items.map { _ in "•" },
                       to: output, scheme: scheme, indent: indent)

        case .numberedList(let start, let items):
            appendList(items,
                       markers: (0..<items.count).map { "\(start + $0)." },
                       to: output, scheme: scheme, indent: indent)

        case .codeBlock(let language, let code):
            appendCode(language: language, code: code,
                       to: output, scheme: scheme, indent: indent)

        case .quote(let inner):
            appendQuote(inner, to: output, scheme: scheme, indent: indent)

        case .rule:
            let rule = NSMutableAttributedString(string: "———————")
            apply(bodyParagraph(indent: indent), to: rule)
            rule.addAttribute(.foregroundColor,
                              value: UIColor(MarkdownTheme.ruleColor(scheme)),
                              range: rule.fullRange())
            output.append(rule)
        }
    }

    /// A bullet or numbered list with hanging indents: the marker sits in a
    /// fixed column, wrapped lines align under the item's text.
    private static func appendList(_ items: [MDListItem],
                                   markers: [String],
                                   to output: NSMutableAttributedString,
                                   scheme: ColorScheme,
                                   indent: CGFloat) {
        let markerFont = UIFont.monospacedDigitSystemFont(
            ofSize: MarkdownTheme.bodySize, weight: .regular)
        let markerWidth = markers.map {
            ($0 as NSString).size(withAttributes: [.font: markerFont]).width
        }.max() ?? 0
        let column = max(MarkdownTheme.listMarkerColumnWidth, ceil(markerWidth))
            + MarkdownTheme.listMarkerGap
        let textIndent = indent + column

        for (index, item) in items.enumerated() {
            if index > 0 { appendBlockSeparator(to: output) }
            let itemText = NSMutableAttributedString()
            let marker = "\(markers.indices.contains(index) ? markers[index] : "•")\t"
            let style = listParagraph(headIndent: textIndent,
                                      firstLineIndent: indent,
                                      spaceBefore: index == 0 ? 0 : MarkdownTheme.listItemSpacing)
            itemText.append(NSAttributedString(string: marker, attributes: [
                .font: markerFont,
                .foregroundColor: UIColor(MarkdownTheme.listMarkerColor(scheme)),
                .paragraphStyle: style
            ]))

            for (blockIndex, sub) in item.blocks.enumerated() {
                // Nested structural blocks need their own paragraph; otherwise
                // the parent's tab and paragraph style swallow their indents.
                let sharesMarkerLine: Bool
                switch sub {
                case .bulletList, .numberedList, .quote: sharesMarkerLine = false
                default: sharesMarkerLine = true
                }
                if blockIndex > 0 || !sharesMarkerLine {
                    appendBlockSeparator(to: itemText)
                }
                let child = NSMutableAttributedString()
                append(block: sub, to: child, scheme: scheme, indent: textIndent)
                if blockIndex == 0, sharesMarkerLine, child.length > 0 {
                    let firstRange = (child.string as NSString).paragraphRange(
                        for: NSRange(location: 0, length: 0))
                    let firstStyle = (child.attribute(.paragraphStyle, at: 0,
                                                     effectiveRange: nil) as? NSParagraphStyle)?
                        .mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    firstStyle.firstLineHeadIndent = indent
                    firstStyle.headIndent = textIndent
                    firstStyle.tabStops = style.tabStops
                    firstStyle.paragraphSpacingBefore = style.paragraphSpacingBefore
                    child.addAttribute(.paragraphStyle, value: firstStyle, range: firstRange)
                    itemText.addAttribute(.paragraphStyle, value: firstStyle,
                                          range: itemText.fullRange())
                }
                itemText.append(child)
            }
            output.append(itemText)
        }
    }

    /// Fenced code on a recessed tint that travels with the characters.
    private static func appendCode(language: String?,
                                   code: String,
                                   to output: NSMutableAttributedString,
                                   scheme: ColorScheme,
                                   indent: CGFloat) {
        if let language, !language.isEmpty {
            let caption = NSMutableAttributedString(string: language.uppercased() + "\n")
            caption.addAttribute(.font,
                                 value: UIFont.systemFont(ofSize: 10, weight: .semibold),
                                 range: caption.fullRange())
            caption.addAttribute(.foregroundColor,
                                 value: UIColor.secondaryLabel,
                                 range: caption.fullRange())
            apply(codeParagraph(indent: indent), to: caption)
            output.append(caption)
        }
        let body = NSMutableAttributedString(string: code.isEmpty ? " " : code)
        let range = body.fullRange()
        body.addAttribute(.font,
                          value: UIFont.monospacedSystemFont(
                              ofSize: MarkdownTheme.codeSize, weight: .regular),
                          range: range)
        body.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        body.addAttribute(.backgroundColor,
                          value: UIColor(MarkdownTheme.codeBackground(scheme)),
                          range: range)
        apply(codeParagraph(indent: indent), to: body)
        output.append(body)
    }

    /// Each explicit line gets a bar glyph. Soft-wrapped lines hang under
    /// the quoted text; a continuous bar would require custom view drawing.
    private static func appendQuote(_ inner: [MDBlock],
                                    to output: NSMutableAttributedString,
                                    scheme: ColorScheme,
                                    indent: CGFloat) {
        let innerDoc = NSMutableAttributedString()
        for (index, block) in inner.enumerated() {
            if index > 0 { appendBlockSeparator(to: innerDoc) }
            append(block: block, to: innerDoc, scheme: scheme, indent: 0)
        }
        guard innerDoc.length > 0 else { return }

        let prefix = "▎ "
        let prefixFont = UIFont.systemFont(ofSize: MarkdownTheme.bodySize)
        let inset = ceil((prefix as NSString).size(withAttributes: [.font: prefixFont]).width)
        let source = innerDoc.string as NSString
        var lineStart = 0
        while lineStart < source.length {
            let found = source.range(of: "\n", options: [],
                                     range: NSRange(location: lineStart,
                                                    length: source.length - lineStart))
            let lineEnd = found.location == NSNotFound ? source.length : found.location + 1
            // Include the newline itself, retaining both the break and its attributes.
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let content = NSMutableAttributedString(
                attributedString: innerDoc.attributedSubstring(from: lineRange))
            let style = (innerDoc.attribute(.paragraphStyle, at: lineStart,
                                             effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += indent
            style.headIndent += indent + inset
            style.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment,
                          location: $0.location + indent + inset, options: $0.options)
            }
            // Only ordinary foreground text becomes secondary. Keep link,
            // marker and nested quote colours, along with every font and URL.
            content.enumerateAttribute(.foregroundColor, in: content.fullRange()) { value, range, _ in
                if (value as? UIColor) == UIColor.label {
                    content.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                }
            }
            let line = NSMutableAttributedString(string: prefix, attributes: [
                .font: prefixFont, .foregroundColor: UIColor(Theme.accent)
            ])
            line.append(content)
            apply(style, to: line)
            output.append(line)
            lineStart = lineEnd
        }
    }

    // MARK: Paragraph styles

    private static func bodyParagraph(indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = MarkdownTheme.bodyLineSpacing
        style.paragraphSpacing = MarkdownTheme.paragraphSpacing
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private static func headingParagraph(level: Int, indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = MarkdownTheme.headingBottomPadding
        style.paragraphSpacingBefore =
            max(0, MarkdownTheme.headingTopPadding(level) - MarkdownTheme.paragraphSpacing)
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private static func codeParagraph(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 4
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    private static func listParagraph(headIndent: CGFloat,
                                      firstLineIndent: CGFloat,
                                      spaceBefore: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = MarkdownTheme.bodyLineSpacing
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = spaceBefore
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineIndent
        style.tabStops = [NSTextTab(textAlignment: .left,
                                    location: headIndent,
                                    options: [:])]
        return style
    }

    // MARK: Helpers

    /// Every character needs a font for measurement as well as display.
    /// Fill missing attributes without replacing inline fonts or link colours.
    private static func apply(_ style: NSParagraphStyle,
                              to string: NSMutableAttributedString) {
        let range = string.fullRange()
        string.addAttribute(.paragraphStyle, value: style, range: range)
        string.enumerateAttribute(.font, in: range) { value, span, _ in
            if value == nil {
                string.addAttribute(.font,
                                    value: UIFont.systemFont(ofSize: MarkdownTheme.bodySize),
                                    range: span)
            }
        }
        string.enumerateAttribute(.foregroundColor, in: range) { value, span, _ in
            if value == nil {
                string.addAttribute(.foregroundColor, value: UIColor.label, range: span)
            }
        }
    }

    private static func appendBlockSeparator(to string: NSMutableAttributedString) {
        // The terminator belongs to the preceding paragraph. Carry its font and
        // paragraph style, but never turn an inserted separator into a link.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: MarkdownTheme.bodySize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: bodyParagraph()
        ]
        if string.length > 0 {
            for key in [NSAttributedString.Key.font, .paragraphStyle] {
                if let value = string.attribute(key, at: string.length - 1, effectiveRange: nil) {
                    attributes[key] = value
                }
            }
        }
        string.append(NSAttributedString(string: "\n", attributes: attributes))
    }
}

extension NSAttributedString {
    /// The string's full range, guarding zero-length strings.
    func fullRange() -> NSRange {
        NSRange(location: 0, length: length)
    }
}

// MARK: - Inline runs to UIKit attributes

private extension NSMutableAttributedString {
    /// Appends inline runs with UIKit attributes. A heading's base font still
    /// preserves italic traits and terminal inline-code typography.
    func append(runs: [MDInline],
                scheme: ColorScheme,
                font: UIFont? = nil,
                color: UIColor? = nil,
                paragraph: NSParagraphStyle) {
        for run in runs {
            let rendered = MessageDocumentBuilder.attributes(for: run, scheme: scheme)
            let span = NSMutableAttributedString(string: rendered.text)
            let range = span.fullRange()
            let spanFont: UIFont
            if let font {
                switch run {
                case .code: spanFont = rendered.font
                case .italic, .boldItalic: spanFont = font.italic()
                default: spanFont = font
                }
            } else {
                spanFont = rendered.font
            }
            span.addAttribute(.font, value: spanFont, range: range)
            span.addAttribute(.foregroundColor,
                              value: color ?? rendered.color,
                              range: range)
            for (name, value) in rendered.extra where name != .foregroundColor {
                span.addAttribute(name, value: value, range: range)
            }
            span.addAttribute(.paragraphStyle, value: paragraph, range: range)
            append(span)
        }
    }
}

/// The UIKit presentation of one inline run, shared by every block type.
extension MessageDocumentBuilder {

    struct RunStyle {
        let text: String
        let font: UIFont
        let color: UIColor
        let extra: [(NSAttributedString.Key, Any)]
    }

    static func attributes(for run: MDInline,
                           scheme: ColorScheme) -> RunStyle {
        let size = MarkdownTheme.bodySize
        switch run {
        case .text(let string):
            return RunStyle(text: string,
                            font: .systemFont(ofSize: size),
                            color: .label,
                            extra: [])

        case .bold(let string):
            return RunStyle(text: string,
                            font: .systemFont(ofSize: size, weight: .semibold),
                            color: .label,
                            extra: [])

        case .italic(let string):
            return RunStyle(text: string,
                            font: .systemFont(ofSize: size).italic(),
                            color: .label,
                            extra: [])

        case .boldItalic(let string):
            return RunStyle(text: string,
                            font: .systemFont(ofSize: size, weight: .semibold).italic(),
                            color: .label,
                            extra: [])

        case .code(let string):
            return RunStyle(
                text: string,
                font: .monospacedSystemFont(ofSize: MarkdownTheme.inlineCodeSize,
                                            weight: .regular),
                color: .label,
                extra: [(.backgroundColor,
                         UIColor(MarkdownTheme.inlineCodeBackground(scheme)))]
            )

        case .strike(let string):
            return RunStyle(text: string,
                            font: .systemFont(ofSize: size),
                            color: .secondaryLabel,
                            extra: [(.strikethroughStyle,
                                     NSUnderlineStyle.single.rawValue)])

        case .link(let text, let urlString):
            var extra: [(NSAttributedString.Key, Any)] = [
                (.underlineStyle, NSUnderlineStyle.single.rawValue),
            ]
            if let url = URL(string: urlString) {
                extra.append((.link, url))
            }
            return RunStyle(text: text,
                            font: .systemFont(ofSize: size),
                            color: UIColor(Theme.linkBlue),
                            extra: extra)
        }
    }
}

private extension UIFont {
    func italic() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    /// New York when available, falling back to the base font.
    func serif() -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(.serif) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - The selectable view

/// One non-scrolling, selectable text view carrying a whole message.
///
/// Sizing is SwiftUI's job: `sizeThatFits` lays the text out at the proposed
/// width and reports the exact height it needs, so the bubble never clips a
/// line — and the view never scrolls, which keeps selection inside the
/// thread's own scroll view.
struct SelectableMessageText: View {
    /// The analysed body. Rebuilt by the caller only when content changes.
    let document: NSAttributedString
    /// Bubble body width cap; the document hugs below it.
    var maxWidth: CGFloat

    var body: some View {
        let width = min(maxWidth, max(1, MessageDocumentBuilder.idealWidth(of: document)))
        BubbleTextView(document: document)
            .frame(width: width)
    }
}

struct BubbleTextView: UIViewRepresentable {
    let document: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.selectedRange.length > 0,
                  textView.window != nil,
                  !textView.isFirstResponder else { return }
            // Read-only selection must own the responder chain for keyboard copy.
            textView.becomeFirstResponder()
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = Self.makeTextView()
        view.delegate = context.coordinator
        return view
    }

    static func makeTextView() -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = "message-text"
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.contentInsetAdjustmentBehavior = .never
        view.layoutMargins = .zero
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        Self.update(view, document: document)
    }

    static func update(_ view: UITextView, document: NSAttributedString) {
        // Reassigning resets the reader's selection; content is immutable per
        // message, so an equal document must be left alone.
        if view.attributedText != document {
            view.attributedText = document
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return nil
        }
        let height = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height.rounded(.up)
        return CGSize(width: width, height: height)
    }
}

// MARK: - Cache
// The document cache lives on `MessageTextCache` itself (see MessageText.swift),
// alongside the inline caches it shares storage with.
