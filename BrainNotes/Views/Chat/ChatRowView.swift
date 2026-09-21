import SwiftUI

/// One row of the thread: an optional date pill above a swipeable bubble.
///
/// The row is `Equatable` so SwiftUI can skip re-evaluating it when nothing
/// about it changed. That matters on this screen: a streamed token arrives
/// several times a second, and without the skip every row in the thread would
/// re-run its body each time.
struct ChatRowView: View, Equatable {
    let row: ChatRow
    let isSelecting: Bool
    let isSelected: Bool
    @Binding var openRow: UUID?

    var onDelete: () -> Void
    var onReply: () -> Void
    var onRegenerate: () -> Void
    var onToggleSelect: () -> Void
    var onTap: () -> Void

    /// `Sendable` snapshot of the row, kept because a `nonisolated` comparison
    /// cannot read the main-actor-isolated `row` property itself.
    private let key: ChatRow.Key
    /// Snapshot of the shared open-row binding, for the same reason: the
    /// comparison below runs off the main actor and must not touch `Binding`.
    private let openRowID: UUID?

    init(row: ChatRow,
         isSelecting: Bool,
         isSelected: Bool,
         openRow: Binding<UUID?>,
         onDelete: @escaping () -> Void,
         onReply: @escaping () -> Void,
         onRegenerate: @escaping () -> Void,
         onToggleSelect: @escaping () -> Void,
         onTap: @escaping () -> Void) {
        self.row = row
        self.key = row.key
        self.openRowID = openRow.wrappedValue
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self._openRow = openRow
        self.onDelete = onDelete
        self.onReply = onReply
        self.onRegenerate = onRegenerate
        self.onToggleSelect = onToggleSelect
        self.onTap = onTap
    }

    /// `nonisolated` so SwiftUI can compare rows off the main actor. Only plain
    /// value data is compared — never `Message`, which is main-actor isolated.
    nonisolated static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.key == rhs.key
            && lhs.isSelecting == rhs.isSelecting
            && lhs.isSelected == rhs.isSelected
            && lhs.openRowID == rhs.openRowID
    }

    var body: some View {
        VStack(spacing: ChatLayout.rowSpacing) {
            if row.showsDateSeparator {
                ChatDateSeparator(text: row.dateSeparatorText)
            }

            SwipeActionRow(
                id: row.id,
                openRow: $openRow,
                onDelete: onDelete,
                selectionMode: isSelecting,
                isSelected: isSelected,
                onToggleSelect: onToggleSelect,
                onTap: onTap
            ) {
                MessageBubble(
                    message: row.message,
                    showTail: row.showTail,
                    timeText: row.timeText,
                    onReply: onReply,
                    onDelete: onDelete,
                    onRegenerate: onRegenerate,
                    canRegenerate: row.canRegenerate
                )
            }
        }
    }
}