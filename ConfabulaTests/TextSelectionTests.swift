import XCTest
import UIKit
@testable import Confabula

final class TextSelectionTests: XCTestCase {
    @MainActor
    func testSelectionSpansUnicodeAndParagraphsInLongReply() {
        let view = BubbleTextView.makeTextView()
        let selected = "chosen words 🦉\nacross paragraphs"
        let text = String(repeating: "Long introduction. ", count: 100)
            + selected + String(repeating: " More content.", count: 100)
        let document = MessageDocumentBuilder.build(analysis: .plain(text), scheme: .light)
        BubbleTextView.update(view, document: document)
        view.selectedRange = (text as NSString).range(of: selected)
        XCTAssertEqual(view.selectedTextRange.flatMap { view.text(in: $0) }, selected)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isScrollEnabled)
        XCTAssertTrue(view.canBecomeFirstResponder)
    }

    @MainActor
    func testUnchangedUpdatePreservesSelection() {
        let view = BubbleTextView.makeTextView()
        let document = MessageDocumentBuilder.build(
            analysis: .plain(String(repeating: "Line of output\n", count: 100)), scheme: .light)
        BubbleTextView.update(view, document: document)
        let selection = NSRange(location: 10, length: 30)
        view.selectedRange = selection
        BubbleTextView.update(view, document: document.copy() as! NSAttributedString)
        XCTAssertEqual(view.selectedRange, selection)
    }

    @MainActor
    func testSelectionCrossesRenderedMarkdownBlocks() {
        let source = "## Heading\n\nFirst **important** paragraph.\n\n```swift\n  let x = 1\n```\n\nLast paragraph."
        let view = BubbleTextView.makeTextView()
        let document = MessageDocumentBuilder.build(analysis: MessageContent.analyse(source), scheme: .light)
        BubbleTextView.update(view, document: document)
        XCTAssertTrue(view.text.contains("First important paragraph."))
        XCTAssertTrue(view.text.contains("  let x = 1"))
        let start = (view.text as NSString).range(of: "important").location
        let end = (view.text as NSString).range(of: "Last paragraph.")
        view.selectedRange = NSRange(location: start, length: NSMaxRange(end) - start)
        let selection = view.selectedTextRange.flatMap { view.text(in: $0) }
        XCTAssertTrue(selection?.hasPrefix("important paragraph.") == true)
        XCTAssertTrue(selection?.contains("  let x = 1") == true)
        XCTAssertTrue(selection?.hasSuffix("Last paragraph.") == true)
    }

    @MainActor
    func testRowGesturesLeaveTextAndControlsAlone() {
        let view = BubbleTextView.makeTextView()
        let child = UIView()
        view.addSubview(child)
        XCTAssertTrue(RowTouchPolicy.isInteractive(child))
        XCTAssertTrue(RowTouchPolicy.isInteractive(UIButton()))
        XCTAssertFalse(RowTouchPolicy.isInteractive(UIView()))
    }

    @MainActor
    func testDocumentCacheIncludesLinkDestination() {
        let cache = MessageTextCache()
        let id = UUID()
        let first = "[Docs](https://example.com/one)"
        let second = "[Docs](https://example.com/two)"
        _ = cache.document(for: id, source: first, analysis: MessageContent.analyse(first), scheme: .light)
        let updated = cache.document(for: id, source: second, analysis: MessageContent.analyse(second), scheme: .light)
        XCTAssertEqual(updated.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/two"))
    }
}
