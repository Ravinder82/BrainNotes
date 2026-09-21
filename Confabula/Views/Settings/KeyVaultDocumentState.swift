import Foundation
import SwiftData
import UIKit
import Observation

/// The editing state behind one vault item's document card.
///
/// The card is deliberately Google-Docs-shaped: title and body are one
/// continuous editable surface, everything persists as the user types, and
/// there is no Save button to forget. This type owns the rules that make that
/// safe, so the view stays declarative and the rules stay testable:
///
/// - Text edits are debounced (400ms) into one SwiftData write, not one per
///   keystroke.
/// - The Keychain secret is committed on focus loss and on close — never per
///   keystroke, because `SecItemCopyMatching` is a synchronous IPC round-trip.
/// - A brand-new item is inserted lazily, on the first autosave tick, so an
///   abandoned draft leaves no row behind; a draft that only ever held a
///   secret leaves no orphaned key behind either.
@MainActor
@Observable
final class KeyVaultDocumentState {
    /// What the header's status pill shows.
    enum SaveStatus: Equatable {
        /// Nothing edited yet.
        case idle
        /// Edits not yet written.
        case dirty
        /// A write is in flight.
        case saving
        /// Everything written.
        case saved
    }

    /// Which surface holds the keyboard focus.
    enum Field: Hashable {
        case title
        case notes
        case secret
    }

    static let defaultCategories = ["Passwords", "API Keys", "Accounts", "IDs", "Docs"]
    static let defaultDebounceMs: UInt64 = 400

    let item: SecureItem
    /// True when the caller handed us an unsaved draft that still needs
    /// `context.insert`.
    let isNew: Bool

    var title: String
    var notes: String
    var category: String
    /// The Keychain secret. Bound to the credential card's field; never
    /// rendered in plain text unless the reader reveals it.
    var secret: String = ""
    var isSecretRevealed = false
    var imageDatas: [Data] = []

    private(set) var saveStatus: SaveStatus = .idle
    /// Last persistence failure, surfaced on the card so a silent save failure
    /// is never mistaken for a successful one.
    var lastError: String?

    /// Debounce window; tests shorten it so autosave is observable quickly.
    var debounceMs: UInt64 = KeyVaultDocumentState.defaultDebounceMs

    /// The Keychain seam. Production wraps the app's shared Keychain; tests
    /// inject an in-memory double so no test touches a real credential.
    private let keys: WebKeyStore

    private var context: ModelContext?
    private var saveTask: Task<Void, Never>?
    private var didLoadSecret = false
    /// Whether the draft has been inserted into the store.
    private var didInsert = false

    init(item: SecureItem, isNew: Bool, keys: WebKeyStore = KeychainWebKeyStore()) {
        self.item = item
        self.isNew = isNew
        self.keys = keys
        self.title = item.title
        self.notes = item.notes
        self.category = item.category
    }

    /// Binds the store context. Called once from the view's `.task`, before any
    /// user interaction can schedule a save.
    func attach(context: ModelContext) {
        self.context = context
    }

    /// Reads the secret and attachments once, off the render path.
    func loadSecretOnce() {
        guard !didLoadSecret else { return }
        didLoadSecret = true
        secret = keys.read(item.keychainKey) ?? ""
        if let pathString = item.imagePath, !pathString.isEmpty {
            imageDatas = pathString.components(separatedBy: ",")
                .compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        }
    }

    // MARK: - Draft rules

    /// True when closing should leave nothing behind: a new draft whose title,
    /// notes and attachments are all empty. A secret typed into such a draft is
    /// deliberately not kept either — a key with no row is an orphan nobody can
    /// find again — so its Keychain entry is removed on close.
    var shouldLeaveNothingBehind: Bool {
        isNew
            && title.trimmingCharacters(in: .whitespaces).isEmpty
            && notes.trimmingCharacters(in: .whitespaces).isEmpty
            && imageDatas.isEmpty
    }

    // MARK: - Editing

    /// A text or category edit. Marks dirty and schedules the debounced write.
    func markDirty() {
        saveStatus = .dirty
        scheduleSave()
    }

    /// An attachment was added or removed; same path as a text edit.
    func attachmentsChanged() {
        markDirty()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceMs ?? Self.defaultDebounceMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// One debounced write of the whole draft. Idempotent: calling it again
    /// with no changes writes the same values and bumps nothing else.
    func persistNow() {
        saveTask?.cancel()
        saveTask = nil

        guard let context else { return }
        saveStatus = .saving

        if isNew && !didInsert {
            context.insert(item)
            didInsert = true
        }
        guard didInsert || !isNew else {
            // An untouched draft has nothing to write and no row to create.
            saveStatus = .idle
            return
        }

        item.title = title
        item.notes = notes
        item.category = category
        saveAttachmentsIfNeeded()
        item.updatedAt = Date()
        do {
            try context.save()
            lastError = nil
            saveStatus = .saved
        } catch {
            lastError = error.localizedDescription
            saveStatus = .dirty
        }
    }

    // MARK: - Secret

    /// Commit the secret to the Keychain. Called on focus loss and on close —
    /// the two moments a reader is done typing — never per keystroke.
    func commitSecret() {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                keys.delete(item.keychainKey)
            } else {
                try keys.save(trimmed, account: item.keychainKey)
            }
            lastError = nil
        } catch let error as KeychainError {
            lastError = error.isMissingEntitlement
                ? "The app is not signed for Keychain access, so the secret was not saved."
                : error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Replace the secret with a strong random one and commit immediately.
    func generateSecret() {
        secret = Self.randomSecret()
        isSecretRevealed = true
        commitSecret()
    }

    /// Remove the secret from the Keychain and the field.
    func removeSecret() {
        secret = ""
        isSecretRevealed = false
        commitSecret()
    }

    // MARK: - Close

    /// Called from the view's `onDisappear`: the last write, plus the
    /// cleanup rules that keep abandoned drafts from leaving anything behind.
    func finalize() {
        saveTask?.cancel()
        saveTask = nil

        if shouldLeaveNothingBehind {
            // Never inserted; drop any secret the reader typed so no orphan
            // key survives in the Keychain.
            keys.delete(item.keychainKey)
            return
        }
        commitSecret()
        persistNow()
    }

    // MARK: - Shapes

    /// The masked form of a secret: one dot per character, at least eight so a
    /// short secret still reads as "something is here".
    static func maskedDots(for secret: String) -> String {
        String(repeating: "•", count: max(secret.count, 8))
    }

    /// Four hyphen-separated groups of eight hex characters — a strong secret
    /// a reader can read aloud over a phone call in groups.
    static func randomSecret() -> String {
        (0..<4).map { _ in String(UUID().uuidString.prefix(8)) }
            .joined(separator: "-")
    }

    /// Writes attached images as JPEGs and mirrors their paths on the model.
    /// Ported from the retired form editor; old paths are cleaned up when the
    /// set changes so removed photos never linger on disk.
    private func saveAttachmentsIfNeeded() {
        var savedPaths: [String] = []
        for (idx, data) in imageDatas.enumerated() {
            if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8),
               let url = Self.attachmentURL(for: item.id, index: idx) {
                try? jpeg.write(to: url, options: .atomic)
                savedPaths.append(url.path)
            }
        }
        if savedPaths.isEmpty {
            if let old = item.imagePath {
                for p in old.components(separatedBy: ",") {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }
            item.imagePath = nil
        } else {
            item.imagePath = savedPaths.joined(separator: ",")
        }
    }

    private static func attachmentURL(for id: UUID, index: Int = 0) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let filename = index == 0 ? "\(id.uuidString).jpg" : "\(id.uuidString)_\(index).jpg"
        return dir.appendingPathComponent(filename)
    }
}