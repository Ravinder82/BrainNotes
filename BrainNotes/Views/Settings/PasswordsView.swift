import SwiftUI
import SwiftData

/// Personal vault: API keys, account credentials, ID scans, CVs. Metadata is
/// SwiftData; every secret lives only in the Keychain.
struct PasswordsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SecureItem.updatedAt, order: .reverse) private var items: [SecureItem]

    @State private var editorTarget: EditorTarget?
    @State private var searchText = ""
    /// `nil` means "All".
    @State private var selectedCategory: String?

    private struct EditorTarget: Identifiable {
        let id: UUID
        let item: SecureItem
        let isNew: Bool
    }

    private var categories: [String] {
        Array(Set(items.map(\.category))).sorted()
    }

    private var filteredItems: [SecureItem] {
        items.filter { item in
            let matchesCategory = selectedCategory == nil || item.category == selectedCategory
            guard matchesCategory else { return false }
            guard !searchText.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(searchText)
                || item.notes.localizedCaseInsensitiveContains(searchText)
                || item.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if categories.count > 1 {
                Section {
                    categoryPicker
                }
            }

            if filteredItems.isEmpty {
                Section { emptyState }
            } else {
                ForEach(filteredItems) { item in
                    NavigationLink {
                        KeyVaultDocumentView(item: item, isNew: false)
                    } label: {
                        PasswordsRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("KeyVault")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search title, notes, category")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addItem) {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("add-secure-item")
                .accessibilityLabel("Add new item")
            }
        }
        .sheet(item: $editorTarget) { target in
            // The document card is always editable and autosaves; `isNew` only
            // decides whether the draft is inserted lazily on the first edit,
            // so an abandoned tap on + leaves no row behind.
            KeyVaultDocumentView(item: target.item, isNew: target.isNew)
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: "All", value: nil)
                ForEach(categories, id: \.self) { category in
                    categoryChip(title: category, value: category)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func categoryChip(title: String, value: String?) -> some View {
        let isSelected = selectedCategory == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedCategory = value }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Theme.accent : Color(.tertiarySystemFill),
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No items yet" : "No matches")
                .font(.headline)
            Text(searchText.isEmpty
                 ? "Tap + to store an API key, login, ID scan or CV."
                 : "Try a different title or category.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func addItem() {
        let item = SecureItem(
            title: "",
            category: selectedCategory ?? "Passwords",
            notes: "",
            keychainKey: UUID().uuidString
        )
        editorTarget = EditorTarget(id: item.id, item: item, isNew: true)
    }

    private func delete(_ item: SecureItem) {
        KeychainStore.delete(account: item.keychainKey)
        if let path = item.imagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        context.delete(item)
        try? context.save()
    }
}

struct PasswordsRow: View {
    let item: SecureItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.imagePath != nil {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        item.notes.isEmpty
            ? item.category
            : "\(item.category) · \(item.notes.replacingOccurrences(of: "\n", with: " "))"
    }

    private var iconName: String {
        switch item.category {
        case "API Keys": return "key.horizontal.fill"
        case "Accounts": return "person.crop.circle.fill"
        case "IDs": return "creditcard.fill"
        case "Docs": return "doc.text.fill"
        default: return "lock.fill"
        }
    }
}