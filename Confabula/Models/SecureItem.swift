import Foundation
import SwiftData

@Model
final class SecureItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var category: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var keychainKey: String
    var imagePath: String?
    
    init(id: UUID = UUID(), title: String, category: String = "Passwords", notes: String = "", keychainKey: String) {
        self.id = id
        self.title = title
        self.category = category
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.keychainKey = keychainKey
        self.imagePath = nil
    }
}
