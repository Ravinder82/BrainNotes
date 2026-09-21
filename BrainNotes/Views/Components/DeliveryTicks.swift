import SwiftUI

/// Delivery state as the ticks a messenger shows inside an outgoing bubble:
/// a clock while queued, one check when sent, two when delivered, two in blue
/// when read, and a red mark when it failed.
///
/// Colour is inherited from the bubble's meta line, so the ticks match the
/// timestamp beside them in both modes; only the states that must stand out —
/// read and failed — override it.
struct DeliveryTicks: View {
    let state: DeliveryState

    var body: some View {
        Group {
            switch state {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))

            case .sent:
                Checkmarks(overlap: false)

            case .delivered:
                Checkmarks(overlap: true)

            case .read:
                Checkmarks(overlap: true)
                    .foregroundStyle(Theme.tickBlue)

            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch state {
        case .sending:   return "Sending"
        case .sent:      return "Sent"
        case .delivered: return "Delivered"
        case .read:      return "Read"
        case .failed:    return "Failed to send"
        }
    }
}

/// One or two check marks, drawn in a fixed-width frame so the meta line never
/// shifts between states. The second mark is overlapped the way a messenger
/// draws a double tick.
///
/// Fixed point size rather than Dynamic Type: the ticks annotate the timestamp
/// and a scaled glyph would reflow the whole meta line at large text sizes.
private struct Checkmarks: View {
    let overlap: Bool

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .overlay(alignment: .leading) {
                if overlap {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .offset(x: 4)
                }
            }
            .frame(width: overlap ? 16 : 11, alignment: .leading)
    }
}