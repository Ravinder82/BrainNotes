import SwiftUI
import SwiftData

/// Important Notes: one text box, with an Edit and a Save button.
///
/// The screen is deliberately nothing more than that. Edit opens the box, Save
/// writes it to the on-device SwiftData store, and the stored text is what the
/// box shows on the next visit — so notes survive relaunches without a list, a
/// category, an attachment or a secret field to manage.
struct ImportantNotesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ImportantNote.updatedAt) private var notes: [ImportantNote]
    @State private var state = ImportantNotesState()
    @FocusState private var isFocused: Bool

    /// The single stored notes row, if it has ever been saved.
    private var storedNote: ImportantNote? { notes.first }

    var body: some View {
        VStack(spacing: 14) {
            editorCard
            actionBar
            if let error = state.lastError {
                errorRow(error)
            }
        }
        .padding(16)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Important Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
        .onAppear { state.load(storedText: storedNote?.text ?? "") }
    }

    // MARK: - Text box

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(state.isEditing ? "Editing" : "Saved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.isEditing ? .secondary : Theme.accent)
                    .accessibilityIdentifier("notes-status")
            }

            TextEditor(text: $state.text)
                .focused($isFocused)
                .disabled(!state.isEditing)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("notes-editor")
                .overlay(alignment: .topLeading) {
                    if state.text.isEmpty {
                        Text("Write anything worth keeping…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(cardBackground)
    }

    // MARK: - Edit / Save

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                state.beginEditing()
                isFocused = true
            } label: {
                Label("Edit", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(state.isEditing)
            .accessibilityIdentifier("notes-edit-button")

            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!state.isEditing)
            .accessibilityIdentifier("notes-save-button")
        }
    }

    private func save() {
        isFocused = false
        state.save(existing: storedNote, in: context)
    }

    // MARK: - Helpers

    private func errorRow(_ message: String) -> some View {
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
        .accessibilityIdentifier("notes-save-error")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}
