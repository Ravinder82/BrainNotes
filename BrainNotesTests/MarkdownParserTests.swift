import XCTest
@testable import BrainNotes

/// Parser tests for the markdown renderer.
///
/// The cases that matter most are the ones tied to real model output: bare-URL
/// link syntax appearing as literal brackets, paragraph breaks drawn as literal
/// blank lines, and half-arrived markers during streaming.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Fast path

    func testPlainProseSkipsParsing() {
        // No markup at all: the renderer must take the cheap path.
        XCTAssertFalse(MarkdownParser.containsMarkup("Hey, how are you doing today?"))
        XCTAssertEqual(MessageContent.analyse("Just a normal sentence."), .plain("Just a normal sentence."))
    }

    func testIncidentalMarkersDoNotTriggerRichRendering() {
        // "a > b" and "issue #42" are not block markup.
        XCTAssertFalse(MarkdownParser.containsMarkup("a > b means greater"))
        XCTAssertFalse(MarkdownParser.containsMarkup("issue #42 is fixed"))
        // version "1.5" is a decimal, not a numbered-list marker.
        XCTAssertFalse(MarkdownParser.containsMarkup("version 1.5 released"))
        // "2 * 3 = 6" is arithmetic. The fast path is conservative (it flags
        // `*`), so the real contract is the analysis: it must fall back to plain.
        XCTAssertEqual(MessageContent.analyse("2 * 3 = 6"), .plain("2 * 3 = 6"))
    }

    func testMarkupIsDetected() {
        XCTAssertTrue(MarkdownParser.containsMarkup("this is **bold** text"))
        XCTAssertTrue(MarkdownParser.containsMarkup("- a list item"))
        XCTAssertTrue(MarkdownParser.containsMarkup("1. first"))
        XCTAssertTrue(MarkdownParser.containsMarkup("## Heading"))
        XCTAssertTrue(MarkdownParser.containsMarkup("> quoted"))
        XCTAssertTrue(MarkdownParser.containsMarkup("`code`"))
        XCTAssertTrue(MarkdownParser.containsMarkup("```\nblock\n```"))
        XCTAssertTrue(MarkdownParser.containsMarkup("[text](https://example.com)"))
    }

    // MARK: - The reported bug

    /// Exact shape of the text in the bug report: a markdown link whose text is
    /// itself a URL. Previously the brackets and parens were drawn literally.
    func testMarkdownLinkIsParsedNotShownLiterally() {
        let text = """
        Hey! How about this one? It's pretty catchy and I've been listening to it a lot recently! 😊

        [https://www.youtube.com/watch?v=F_f42sCj35E](https://www.youtube.com/watch?v=F_f42sCj35E)
        """
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2, "Expected two paragraphs")

        // The link must be a link run, with no literal brackets surviving.
        guard case .paragraph(let secondRuns) = blocks[1] else {
            return XCTFail("Second block should be a paragraph")
        }
        guard case .link(let linkText, let url) = secondRuns.first else {
            return XCTFail("Expected a link run, got \(secondRuns)")
        }
        XCTAssertEqual(linkText, "https://www.youtube.com/watch?v=F_f42sCj35E")
        XCTAssertEqual(url, "https://www.youtube.com/watch?v=F_f42sCj35E")

        // And nothing anywhere should still contain the raw bracket syntax.
        let rendered = blocks.plainText
        XCTAssertFalse(rendered.contains("]("), "Literal link syntax leaked into output")
        XCTAssertFalse(rendered.contains("["), "Literal opening bracket leaked into output")
    }

    /// The second half of the bug: `\n\n` was drawn as a literal empty line,
    /// producing a full line-height void between paragraphs.
    func testParagraphBreakDoesNotProduceAnEmptyBlock() {
        let blocks = MarkdownParser.parse("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            if case .paragraph(let runs) = block {
                XCTAssertFalse(MDInline.plainText(runs).isEmpty,
                               "Empty paragraph block would render as a blank line")
            }
        }
    }

    // MARK: - Blocks

    func testHeadings() {
        let blocks = MarkdownParser.parse("# Title\n## Subtitle\n### Third")
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(let l1, _) = blocks[0] else { return XCTFail("H1") }
        guard case .heading(let l2, _) = blocks[1] else { return XCTFail("H2") }
        guard case .heading(let l3, _) = blocks[2] else { return XCTFail("H3") }
        XCTAssertEqual([l1, l2, l3], [1, 2, 3])
    }

    func testHeadingRequiresSpace() {
        // CommonMark: "#hashtag" is not a heading — no space after the marker.
        XCTAssertFalse(MarkdownParser.containsMarkup("#hashtag"))
    }

    /// Intraword underscores must never be treated as emphasis, so
    /// `snake_case` and identifiers render literally.
    func testIntrawordUnderscoresAreLiteral() {
        let runs = InlineMarkdownParser.parse("snake_case_name")
        XCTAssertEqual(runs, [.text("snake_case_name")],
                       "Intraword underscore must not create italics")
        XCTAssertFalse(MarkdownParser.containsMarkup("snake_case_name"))
    }

    func testBulletList() {
        let blocks = MarkdownParser.parse("- one\n- two\n- three")
        guard case .bulletList(let items) = blocks.first else {
            return XCTFail("Expected bullet list")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].plainText, "one")
    }

    func testOrderedListPreservesStartNumber() {
        let blocks = MarkdownParser.parse("3. three\n4. four")
        guard case .numberedList(let start, let items) = blocks.first else {
            return XCTFail("Expected numbered list")
        }
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.count, 2)
    }

    func testFencedCodeBlockPreservesContent() {
        let text = "```swift\nlet x = 1\nprint(x)\n```"
        let blocks = MarkdownParser.parse(text)
        guard case .codeBlock(let language, let code) = blocks.first else {
            return XCTFail("Expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\nprint(x)")
    }

    func testUnterminatedFenceMidStreamIsTolerated() {
        // Streaming can deliver the opening fence with no closer yet.
        let blocks = MarkdownParser.parse("```swift\nlet x = 1")
        guard case .codeBlock(_, let code) = blocks.first else {
            return XCTFail("Expected a code block even when unterminated")
        }
        XCTAssertEqual(code, "let x = 1")
    }

    func testHorizontalRule() {
        XCTAssertEqual(MarkdownParser.parse("---").first, .rule)
        XCTAssertEqual(MarkdownParser.parse("***").first, .rule)
    }

    func testBlockquote() {
        let blocks = MarkdownParser.parse("> a wise line")
        guard case .quote(let inner) = blocks.first else {
            return XCTFail("Expected quote")
        }
        XCTAssertEqual(inner.plainText, "a wise line")
    }

    // MARK: - Inline

    func testInlineStyles() {
        XCTAssertEqual(InlineMarkdownParser.parse("**bold**"),
                       [.bold("bold")])
        XCTAssertEqual(InlineMarkdownParser.parse("*italic*"),
                       [.italic("italic")])
        XCTAssertEqual(InlineMarkdownParser.parse("`code`"),
                       [.code("code")])
        XCTAssertEqual(InlineMarkdownParser.parse("~~gone~~"),
                       [.strike("gone")])
    }

    func testMixedInlineRunsKeepOrder() {
        let runs = InlineMarkdownParser.parse("plain **bold** and `code` end")
        XCTAssertEqual(runs, [
            .text("plain "),
            .bold("bold"),
            .text(" and "),
            .code("code"),
            .text(" end"),
        ])
    }

    /// Streaming can deliver an opening marker before its closer. The partial
    /// marker must render as literal text so already-visible content does not
    /// reflow when the closing marker finally arrives.
    func testUnterminatedInlineMarkersRenderLiterally() {
        XCTAssertEqual(InlineMarkdownParser.parse("**bo"), [.text("**bo")])
        XCTAssertEqual(InlineMarkdownParser.parse("`cod"), [.text("`cod")])
        XCTAssertEqual(InlineMarkdownParser.parse("*it"), [.text("*it")])
        XCTAssertEqual(InlineMarkdownParser.parse("~~str"), [.text("~~str")])
        XCTAssertEqual(InlineMarkdownParser.parse("[link"), [.text("[link")])
        XCTAssertEqual(InlineMarkdownParser.parse("[link](http"), [.text("[link](http")])
    }

    func testBareAutolink() {
        let runs = InlineMarkdownParser.parse("see https://example.com for details")
        XCTAssertTrue(runs.contains(.link(text: "https://example.com",
                                          url: "https://example.com")))
    }

    func testAutolinkDropsTrailingPunctuation() {
        let runs = InlineMarkdownParser.parse("go to https://example.com.")
        XCTAssertTrue(runs.contains(.link(text: "https://example.com",
                                          url: "https://example.com")))
    }

    func testAsteriskArithmeticIsNotEmphasis() {
        // "2 * 3 * 4" must not turn into italics.
        let runs = InlineMarkdownParser.parse("2 * 3 * 4")
        XCTAssertEqual(MDInline.plainText(runs), "2 * 3 * 4")
    }

    func testEscapedMarkerIsLiteral() {
        XCTAssertEqual(InlineMarkdownParser.parse("\\*not italic\\*"),
                       [.text("*not italic*")])
    }

    // MARK: - Plain-text projection

    func testPlainTextStripsAllMarkup() {
        let text = "# Title\n\nSome **bold** and a [link](https://x.com)\n\n- item"
        let flat = MessageContent.plainText(from: text)
        XCTAssertFalse(flat.contains("**"))
        XCTAssertFalse(flat.contains("#"))
        XCTAssertFalse(flat.contains("]("))
        XCTAssertFalse(flat.contains("- "))
        XCTAssertTrue(flat.contains("link"))
    }

    func testPlainTextLeavesProseUntouched() {
        let prose = "Nothing to strip here."
        XCTAssertEqual(MessageContent.plainText(from: prose), prose)
    }

    // MARK: - Robustness

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(MarkdownParser.parse(""), [])
        XCTAssertFalse(MarkdownParser.containsMarkup(""))
        XCTAssertEqual(MessageContent.plainText(from: ""), "")
    }

    func testPathologicalInputDoesNotHang() {
        // Long runs of markers must not cause backtracking blowup.
        let nasty = String(repeating: "*", count: 2000)
        let start = Date()
        _ = MarkdownParser.containsMarkup(nasty)
        _ = InlineMarkdownParser.parse(nasty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                          "Parser appears to backtrack on marker-heavy input")
    }
}