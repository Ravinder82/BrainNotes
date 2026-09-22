import XCTest
import SwiftData
@testable import BrainNotes

/// The Important Notes page's rules in isolation: the box is seeded from the
/// store, Edit gates input, and Save is the only thing that writes — always to
/// the single notes row, never a second one.
@MainActor
final class ImportantNotesStateTests: XCTestCase {
    /// Held for the test's lifetime: `mainContext` does not keep its container
    /// alive on its own, and a deallocated container traps on the next fetch.
    private var container: ModelContainer?

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func makeContext() throws -> ModelContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let schema = Schema([Bot.self, Message.self, ImportantNote.self, Crew.self])
        let config = ModelConfiguration(schema: schema, url: directory)
        let made = try ModelContainer(for: schema, configurations: [config])
        container = made
        return made.mainContext
    }

    private func storedRows(in context: ModelContext) throws -> [ImportantNote] {
        try context.fetch(FetchDescriptor<ImportantNote>())
    }

    // MARK: - Edit gates input

    func testNothingIsWrittenBeforeSave() throws {
        let context = try makeContext()
        let state = ImportantNotesState()
        state.load(storedText: "")

        state.beginEditing()
        state.text = "Draft that was never saved"

        XCTAssertTrue(state.isEditing, "Edit must open the box")
        XCTAssertTrue(try storedRows(in: context).isEmpty,
                      "Typing must not write before Save")
    }

    func testBoxIsReadOnlyUntilEdit() throws {
        let state = ImportantNotesState()
        state.load(storedText: "Stored")

        XCTAssertFalse(state.isEditing, "The box starts read-only")
        state.beginEditing()
        XCTAssertTrue(state.isEditing)
    }

    // MARK: - Save

    func testSaveCreatesTheRowAndClosesEditing() throws {
        let context = try makeContext()
        let state = ImportantNotesState()
        state.load(storedText: "")

        state.beginEditing()
        state.text = "Wi-Fi password: hunter2\nGate code: 4815"

        XCTAssertTrue(state.save(existing: nil, in: context))
        XCTAssertFalse(state.isEditing, "Save must close the box")
        XCTAssertFalse(state.hasUnsavedChanges)

        let rows = try storedRows(in: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "Wi-Fi password: hunter2\nGate code: 4815")
    }

    func testSaveUpsertsTheSingleRow() throws {
        let context = try makeContext()

        let first = ImportantNotesState()
        first.load(storedText: "")
        first.beginEditing()
        first.text = "First"
        XCTAssertTrue(first.save(existing: nil, in: context))

        let existing = try XCTUnwrap(try storedRows(in: context).first)

        let second = ImportantNotesState()
        second.load(storedText: existing.text)
        second.beginEditing()
        second.text = "Second"
        XCTAssertTrue(second.save(existing: existing, in: context))

        let rows = try storedRows(in: context)
        XCTAssertEqual(rows.count, 1, "Saving must update the one notes row")
        XCTAssertEqual(rows.first?.text, "Second")
    }

    func testSavedTextSurvivesAFreshLoad() throws {
        let context = try makeContext()
        let writer = ImportantNotesState()
        writer.load(storedText: "")
        writer.beginEditing()
        writer.text = "Remember the milk"
        XCTAssertTrue(writer.save(existing: nil, in: context))

        // A later visit loads whatever the store holds.
        let stored = try XCTUnwrap(try storedRows(in: context).first)
        let reader = ImportantNotesState()
        reader.load(storedText: stored.text)
        XCTAssertEqual(reader.text, "Remember the milk")
    }

    // MARK: - Load

    func testLoadIsIdempotentAndDoesNotClobberEdits() throws {
        let state = ImportantNotesState()
        state.load(storedText: "Remember the milk")
        XCTAssertEqual(state.text, "Remember the milk")
        XCTAssertFalse(state.hasUnsavedChanges)

        // `onAppear` fires again when the page is re-shown.
        state.load(storedText: "Something else")
        XCTAssertEqual(state.text, "Remember the milk",
                       "Re-appearing must not overwrite the box")
    }

    func testEditsAreTrackedAsUnsaved() throws {
        let state = ImportantNotesState()
        state.load(storedText: "Stored")
        XCTAssertFalse(state.hasUnsavedChanges)

        state.beginEditing()
        state.text = "Stored and more"
        XCTAssertTrue(state.hasUnsavedChanges)

        state.text = "Stored"
        XCTAssertFalse(state.hasUnsavedChanges, "Undoing an edit leaves nothing to save")
    }
}
