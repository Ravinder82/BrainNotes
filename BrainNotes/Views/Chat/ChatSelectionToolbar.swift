import SwiftUI

/// Toolbar shown while messages are selected: a count, Cancel, and the export
/// and delete actions.
struct ChatSelectionToolbar: ToolbarContent {
    let count: Int
    var onCancel: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel", action: onCancel)
        }

        ToolbarItem(placement: .principal) {
            Text(count == 1 ? "1 selected" : "\(count) selected")
                .font(.headline)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: onExport) {
                    Label("Export as text", systemImage: "square.and.arrow.up")
                }
                .disabled(count == 0)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete selected", systemImage: "trash")
                }
                .disabled(count == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("selection-menu")
            .accessibilityLabel(Text("Selection actions"))
        }
    }
}