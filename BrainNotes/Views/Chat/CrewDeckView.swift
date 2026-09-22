import SwiftUI
import SwiftData

/// Captain's crew deck: a horizontal rail of every crew Captain has assembled,
/// pinned above the thread like a mission-control strip.
///
/// The deck shows crews (not individual specialists) because Captain's primary
/// unit of work is the crew — when the user wants to know what is going on
/// right now they think "which crew is on this?", not "which specialist?".
///
/// Each crew card carries a live status pill — steady when idle, a tinted dot
/// while any member is streaming. Tapping a crew jumps into the crew detail
/// (mission, members, working count) and from there straight into a member's
/// private chat, so moving between Captain's plan and a specialist's work is
/// two gestures.
///
/// The deck only renders once a crew exists; before Captain has assembled his
/// first crew there is nothing to show and the strip stays hidden.
struct CrewDeckView: View {
    let engine: ChatEngine

    @Query private var crews: [Crew]
    @Environment(\.colorScheme) private var scheme

    private var sortedCrews: [Crew] {
        crews.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var workingBotIDs: Set<UUID> {
        guard let id = engine.streamingBotID else { return [] }
        return [id]
    }

    var body: some View {
        if sortedCrews.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                header
                rail
            }
            .background(.bar)
            .accessibilityIdentifier("crew-deck")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mutedText(scheme))
            Text("CREWS · \(sortedCrews.count)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.mutedText(scheme))
            Spacer(minLength: 6)
            if workingCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 5, height: 5)
                    Text(workingCount == 1
                         ? "1 working"
                         : "\(workingCount) working")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accentText(scheme))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .animation(.easeOut(duration: 0.2), value: workingCount)
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(sortedCrews) { crew in
                    NavigationLink {
                        CrewDetailView(crew: crew)
                    } label: {
                        CrewCard(crew: crew,
                                 workingBotIDs: workingBotIDs,
                                 style: .compact)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("crew-deck-card-\(crew.id.uuidString)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// Number of specialists currently streaming across all crews. Counts
    /// unique bots so two crews sharing the same member do not double-count.
    private var workingCount: Int {
        workingBotIDs.count
    }
}