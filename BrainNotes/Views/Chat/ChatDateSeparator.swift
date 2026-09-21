import SwiftUI

/// The pill that separates days in a thread.
struct ChatDateSeparator: View {
    let text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.datePill(scheme), in: Capsule())
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}