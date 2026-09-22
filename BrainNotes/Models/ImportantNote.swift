import Foundation
import SwiftData

/// The owner's single free-form notes page, edited from Settings.
///
/// Deliberately one row: the screen is a notes page, not a list of documents,
/// so `id` is a fixed key and saving is an upsert rather than a new document.
@Model
final class ImportantNote {
    /// The one key this store is allowed to hold.
    static let singletonID = "important-notes"

    @Attribute(.unique) var id: String
    var text: String
    var updatedAt: Date

    init(id: String = ImportantNote.singletonID,
         text: String = "",
         updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }
}
