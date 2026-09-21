import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// One vault item as a Google-Docs-style document card.
///
/// The card is always editable and there is no Save button: title and body are
/// one continuous text surface, edits are debounced into the store as the
/// reader types, and the header's status pill says where that stands — the
/// same "Saved to Drive" reassurance, on-device. What a document has no
/// equivalent for sits outside the surface: the category, the attachments and
/// the Keychain secret, in a compact header and a protected credential card.
///
/// Layout, in the order it matters:
///
/// - The header carries the category menu, the save-status pill and an
///   overflow menu holding Delete (with confirmation) — metadata the reader
///   sets once, not while writing.
/// - The document card is the only large editable surface: a bold inline
///   title, then an auto-growing body that behaves like a page.
/// - The credential card keeps the secret in its own clearly separated row
///   with reveal, copy, generate and remove actions, committed to the
///   Keychain on focus loss — never per keystroke.
struct KeyVaultDocumentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let item: SecureItem
    /// True when the caller handed us an unsaved draft.
    let isNew: Bool

    @State private var state: KeyVaultDocumentState?
    @FocusState private var focusedField: KeyVaultDocumentState.Field?
    @State private var selectedImage: PhotosPickerItem?
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if let state {
                content(state)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
        // The state owns the save rules and needs the context; it is wired
        // here, before any interaction can schedule a save.
        .task {
            if state == nil {
                let made = KeyVaultDocumentState(item: item, isNew: isNew)
                made.loadSecretOnce()
                made.attach(context: context)
                state = made
            }
        }
        // The last write, plus the discard rules for abandoned drafts.
        .onDisappear { state?.finalize() }
    }

    // MARK: - Content

    private func content(_ made: KeyVaultDocumentState) -> some View {
        @Bindable var state = made

        // The sheet needs its own navigation stack: without it the title bar,
        // the Done button and the keyboard toolbar have nothing to attach to.
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerRow(state)
                    documentCard(state)
                    credentialCard(state)
                    if let error = state.lastError {
                        errorCard(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            // Like a document, the top bar carries the item's own title.
            .navigationTitle(state.title.isEmpty ? "Untitled" : state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("vault-done")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        pasteIntoBody(state)
                    } label: {
                        Label("Paste", systemImage: "doc.on.doc")
                    }
                    Button {
                        insertDate(state)
                    } label: {
                        Label("Date", systemImage: "calendar.badge.plus")
                    }
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onChange(of: selectedImage) { _, newValue in
                Task {
                    guard let data = try? await newValue?.loadTransferable(type: Data.self) else { return }
                    state.imageDatas.append(data)
                    state.attachmentsChanged()
                }
            }
            // The secret is committed when the reader is done typing, not per
            // keystroke: on focus loss, and again on close via `finalize`.
            .onChange(of: focusedField) { previous, current in
                if previous == .secret, current != .secret {
                    state.commitSecret()
                }
            }
        }
    }

    // MARK: - Header

    private func headerRow(_ state: KeyVaultDocumentState) -> some View {
        HStack(spacing: 10) {
            categoryMenu(state)

            Spacer(minLength: 0)

            saveStatusPill(state.saveStatus)

            Menu {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete item", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Item actions")
            .accessibilityIdentifier("vault-overflow")
        }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteItem() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func categoryMenu(_ state: KeyVaultDocumentState) -> some View {
        Menu {
            ForEach(KeyVaultDocumentState.defaultCategories, id: \.self) { category in
                Button {
                    state.category = category
                    state.markDirty()
                } label: {
                    if category == state.category {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                Text(state.category)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.accent)
        }
        .accessibilityLabel("Category: \(state.category)")
        .accessibilityIdentifier("vault-category-menu")
    }

    private func saveStatusPill(_ status: KeyVaultDocumentState.SaveStatus) -> some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .dirty:
                Label("Editing", systemImage: "pencil.line")
            case .saving:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Saving…")
                }
            case .saved:
                Label("Saved", systemImage: "checkmark.circle.fill")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(status == .saved ? Theme.accent : .secondary)
        .accessibilityIdentifier("vault-save-status")
    }

    // MARK: - Document card

    private func documentCard(_ state: KeyVaultDocumentState) -> some View {
        @Bindable var state = state

        return VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled", text: $state.title)
                .font(.title2.weight(.bold))
                .focused($focusedField, equals: .title)
                .onChange(of: state.title) { _, _ in state.markDirty() }
                .accessibilityIdentifier("vault-title-field")

            Divider()
                .padding(.top, 10)

            TextField("Notes, recovery codes, URLs…", text: $state.notes, axis: .vertical)
                .lineLimit(6...Int.max)
                .padding(.top, 10)
                .focused($focusedField, equals: .notes)
                .onChange(of: state.notes) { _, _ in state.markDirty() }
                .accessibilityIdentifier("vault-notes-field")

            attachmentsRow(state)
        }
        .padding(16)
        .background(cardBackground)
    }

    @ViewBuilder
    private func attachmentsRow(_ state: KeyVaultDocumentState) -> some View {
        if !state.imageDatas.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.top, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(state.imageDatas.indices, id: \.self) { idx in
                            if let uiImage = UIImage(data: state.imageDatas[idx]) {
                                thumbnail(uiImage) {
                                    state.imageDatas.remove(at: idx)
                                    state.attachmentsChanged()
                                }
                            }
                        }
                    }
                }
            }
        }
        PhotosPicker(selection: $selectedImage, matching: .images) {
            Label("Add image", systemImage: "photo")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, state.imageDatas.isEmpty ? 12 : 8)
        }
        .accessibilityIdentifier("vault-add-image")
    }

    private func thumbnail(_ image: UIImage, onRemove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 2)
                }
                .offset(x: 5, y: -5)
                .accessibilityLabel("Remove image")
            }
    }

    // MARK: - Credential card

    private func credentialCard(_ state: KeyVaultDocumentState) -> some View {
        @Bindable var state = state

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                Text("Secret")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("Keychain")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Group {
                    if state.isSecretRevealed {
                        TextField("Type or paste a secret…", text: $state.secret)
                    } else {
                        SecureField("Type or paste a secret…", text: $state.secret)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
                .focused($focusedField, equals: .secret)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .submitLabel(.done)
                .accessibilityIdentifier("vault-secret-field")

                Button {
                    state.isSecretRevealed.toggle()
                } label: {
                    Image(systemName: state.isSecretRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(state.isSecretRevealed ? "Hide secret" : "Reveal secret")
                .accessibilityIdentifier("vault-reveal-secret")
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = state.secret
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(state.secret.isEmpty)
                .accessibilityIdentifier("vault-copy-secret")

                Button {
                    state.generateSecret()
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("vault-generate-secret")

                Button(role: .destructive) {
                    state.removeSecret()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(state.secret.isEmpty)
                .tint(.red)
                .accessibilityIdentifier("vault-remove-secret")

                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - Helpers

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("Could not save")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vault-save-error")
    }

    /// Paste appends to the document body — the surface a reader is writing.
    private func pasteIntoBody(_ state: KeyVaultDocumentState) {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        state.notes += state.notes.isEmpty ? pasted : "\n" + pasted
        state.markDirty()
    }

    /// Insert today's date at the end of the body, like a document editor's
    /// "insert date".
    private func insertDate(_ state: KeyVaultDocumentState) {
        let stamp = Date().formatted(date: .abbreviated, time: .omitted)
        state.notes += state.notes.isEmpty ? stamp : "\n" + stamp
        state.markDirty()
    }

    private func deleteItem() {
        KeychainStore.delete(account: item.keychainKey)
        if let path = item.imagePath {
            for p in path.components(separatedBy: ",") {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
        context.delete(item)
        try? context.save()
        dismiss()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}