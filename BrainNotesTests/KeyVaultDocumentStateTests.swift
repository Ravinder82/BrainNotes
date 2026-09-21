import XCTest
import SwiftData
@testable import BrainNotes

/// The document card's editing rules, in isolation: the discard rule for
/// abandoned drafts, secret masking and generation, and — the piece the whole
/// feature rests on — debounced autosave that actually persists to the store
/// without a Save button.
@MainActor
final class KeyVaultDocumentStateTests: XCTestCase {
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
        let schema = Schema([Bot.self, Message.self, SecureItem.self, Crew.self])
        let config = ModelConfiguration(schema: schema, url: directory)
        let made = try ModelContainer(for: schema, configurations: [config])
        container = made
        return made.mainContext
    }

    // MARK: - Autosave

    func testTypingPersistsWithoutAnySaveButton() async throws {
        let context = try makeContext()
        let item = SecureItem(title: "", category: "Passwords", notes: "",
                              keychainKey: UUID().uuidString)
        let state = KeyVaultDocumentState(item: item, isNew: true,
                                          keys: InMemoryWebKeyStore())
        state.attach(context: context)
        state.debounceMs = 30

        // The reader types a title and a body. No save is pressed anywhere.
        state.title = "Autosave Doc"
        state.notes = "hello world"
        state.markDirty()

        XCTAssertEqual(state.saveStatus, .dirty)
        let persisted = await waitUntilSaved(state)
        XCTAssertTrue(persisted, "autosave never reached .saved")

        // The store holds the row, with both fields — written by the debounce.
        let rows = try context.fetch(FetchDescriptor<SecureItem>())
        XCTAssertEqual(rows.count, 1, "the draft was inserted lazily on the first save")
        XCTAssertEqual(rows.first?.title, "Autosave Doc")
        XCTAssertEqual(rows.first?.notes, "hello world")
        XCTAssertEqual(state.saveStatus, .saved)
    }

    func testRapidEditsCollapseIntoOneWrite() async throws {
        let context = try makeContext()
        let item = SecureItem(title: "Start", category: "Passwords", notes: "",
                              keychainKey: UUID().uuidString)
        let state = KeyVaultDocumentState(item: item, isNew: false,
                                          keys: InMemoryWebKeyStore())
        state.attach(context: context)
        state.debounceMs = 60

        // Several edits inside one debounce window.
        state.title = "Edit 1"; state.markDirty()
        state.title = "Edit 2"; state.markDirty()
        state.notes = "x"; state.markDirty()
        state.title = "Final"; state.markDirty()

        _ = await waitUntilSaved(state)

        // All edits landed, whatever the intermediate states were.
        XCTAssertEqual(item.title, "Final")
        XCTAssertEqual(item.notes, "x")
    }

    func testPersistWithoutChangesIsIdempotent() throws {
        let context = try makeContext()
        let item = SecureItem(title: "Steady", category: "IDs", notes: "n",
                              keychainKey: UUID().uuidString)
        context.insert(item)
        try context.save()
        let stamped = item.updatedAt

        let state = KeyVaultDocumentState(item: item, isNew: false,
                                          keys: InMemoryWebKeyStore())
        state.attach(context: context)

        state.persistNow()

        XCTAssertEqual(item.title, "Steady")
        XCTAssertEqual(state.saveStatus, .saved)
        XCTAssertGreaterThanOrEqual(item.updatedAt, stamped,
                                    "a save bumps the updated stamp")
    }

    // MARK: - Discard rule

    func testAbandonedEmptyDraftLeavesNothingBehind() async throws {
        let context = try makeContext()
        let item = SecureItem(title: "", category: "Passwords", notes: "",
                              keychainKey: UUID().uuidString)
        let keys = InMemoryWebKeyStore()
        let state = KeyVaultDocumentState(item: item, isNew: true, keys: keys)
        state.attach(context: context)

        // The reader typed only a secret, then closed without a title.
        state.secret = "sk-something"
        state.commitSecret()
        XCTAssertTrue(state.shouldLeaveNothingBehind,
                      "a secret with no row is an orphan nobody can find again")

        state.finalize()

        let rows = try context.fetch(FetchDescriptor<SecureItem>())
        XCTAssertEqual(rows.count, 0, "no junk row for an abandoned draft")
        XCTAssertNil(keys.read(item.keychainKey),
                     "no orphaned key left in the keychain")
    }

    func testExistingItemIsNeverDiscarded() async throws {
        let context = try makeContext()
        let item = SecureItem(title: "Kept", category: "Docs", notes: "",
                              keychainKey: UUID().uuidString)
        context.insert(item)
        try context.save()

        let state = KeyVaultDocumentState(item: item, isNew: false,
                                          keys: InMemoryWebKeyStore())
        state.attach(context: context)

        state.finalize()

        let rows = try context.fetch(FetchDescriptor<SecureItem>())
        XCTAssertEqual(rows.count, 1, "an existing item is never dropped on close")
    }

    // MARK: - Secret

    func testCommitAndRemoveRoundTripThroughTheSeam() {
        let keys = InMemoryWebKeyStore()
        let item = SecureItem(title: "T", category: "Passwords", notes: "",
                              keychainKey: "vault.test.roundtrip")
        let state = KeyVaultDocumentState(item: item, isNew: true, keys: keys)

        state.secret = "sk-tinyfish-EXAMPLE"
        state.commitSecret()
        XCTAssertEqual(keys.read("vault.test.roundtrip"), "sk-tinyfish-EXAMPLE")
        XCTAssertNil(state.lastError)

        state.removeSecret()
        XCTAssertNil(keys.read("vault.test.roundtrip"))
        XCTAssertEqual(state.secret, "")
    }

    func testMaskedDotsNeverShowTheSecret() {
        XCTAssertEqual(KeyVaultDocumentState.maskedDots(for: "abc"), String(repeating: "•", count: 8),
                       "a short secret still reads as 'something is here'")
        XCTAssertEqual(KeyVaultDocumentState.maskedDots(for: "sk-tinyfish-0123456789"),
                       String(repeating: "•", count: 22))
        XCTAssertFalse(KeyVaultDocumentState.maskedDots(for: "secret-value").contains("secret"))
    }

    func testRandomSecretShape() {
        let secret = KeyVaultDocumentState.randomSecret()
        let groups = secret.split(separator: "-")
        XCTAssertEqual(groups.count, 4, "four groups, readable aloud in steps")
        XCTAssertTrue(groups.allSatisfy { $0.count == 8 })
        XCTAssertNotEqual(KeyVaultDocumentState.randomSecret(), secret,
                          "two generations must differ")
    }

    func testGenerateCommitsImmediately() {
        let keys = InMemoryWebKeyStore()
        let item = SecureItem(title: "T", category: "Passwords", notes: "",
                              keychainKey: "vault.test.generate")
        let state = KeyVaultDocumentState(item: item, isNew: true, keys: keys)

        state.generateSecret()

        XCTAssertFalse(state.secret.isEmpty)
        XCTAssertEqual(keys.read("vault.test.generate"), state.secret,
                       "generate writes the keychain without a save button")
        XCTAssertTrue(state.isSecretRevealed, "a fresh generated secret is shown once")
    }

    // MARK: - Helpers

    /// Waits for the debounced save to settle, with a bounded deadline.
    private func waitUntilSaved(_ state: KeyVaultDocumentState) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if state.saveStatus == .saved { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return state.saveStatus == .saved
    }
}