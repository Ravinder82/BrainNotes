import Foundation
import SwiftData
import Observation

/// The save rules behind the Important Notes page.
///
/// The page is one text box with an Edit/Save pair, so this type owns exactly
/// what that pair needs to be safe: the box is seeded from the stored note,
/// edits are gated behind Edit, and Save is the only thing that writes. Because
/// the rules live here instead of in the view, they stay testable.
@MainActor
@Observable
final class ImportantNotesState {
    /// What the text box currently shows.
    var text: String = ""
    /// What the store holds. `text` differs from it only while there are
    /// unwritten edits.
    private(set) var savedText: String = ""
    /// True while the box accepts input.
    private(set) var isEditing = false
    /// Last persistence failure, surfaced so a silent save failure is never
    /// mistaken for a successful one.
    private(set) var lastError: String?

    /// True when the box holds edits that Save would write.
    var hasUnsavedChanges: Bool { text != savedText }

    @ObservationIgnored private var didLoad = false

    /// Seeds the box from the stored note. Idempotent, because the view calls
    /// this from `onAppear`, which fires again whenever the page is re-shown.
    func load(storedText: String) {
        guard !didLoad else { return }
        didLoad = true
        text = storedText
        savedText = storedText
    }

    /// Opens the box for input.
    func beginEditing() {
        isEditing = true
    }

    /// Writes the box's contents into the single stored row, creating it on the
    /// first save. Returns whether the write reached the store.
    @discardableResult
    func save(existing: ImportantNote?, in context: ModelContext) -> Bool {
        let note = existing ?? ImportantNote()
        if existing == nil { context.insert(note) }
        note.text = text
        note.updatedAt = Date()
        do {
            try context.save()
            lastError = nil
            savedText = text
            isEditing = false
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
