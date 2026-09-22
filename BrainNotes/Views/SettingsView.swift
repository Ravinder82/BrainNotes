import SwiftUI

/// BYOK configuration. Each provider is a single self-contained screen: label,
/// endpoint, model and API key live together, so there is no separate
/// "add key" / "replace key" step to get lost in.
struct SettingsView: View {
    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Non-nil drives the unified provider detail sheet.
    @State private var detailTarget: ProviderConfig?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if store.providers.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.providers) { provider in
                            providerCard(provider)
                        }
                    }

                    addProviderButton

                    if let error = store.lastKeychainError {
                        keychainErrorCard(error)
                    }

                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI Providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $detailTarget) { provider in
                ProviderDetailView(config: provider) { saved in
                    store.upsert(saved)
                    if store.activeProviderID == nil {
                        store.setActive(saved.id)
                    }
                }
            }
        }
    }

    // MARK: - Provider card

    private func providerCard(_ provider: ProviderConfig) -> some View {
        // Served from the in-memory mirror: the previous implementation did a
        // synchronous Keychain read here, once per card per layout pass.
        let hasKey = store.hasKey(for: provider.id)
        let isActive = store.activeProviderID == provider.id

        return HStack(spacing: 14) {
            Button {
                detailTarget = provider
            } label: {
                HStack(spacing: 13) {
                    ProviderAvatar(label: provider.label, isActive: isActive)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.label.isEmpty ? "Untitled" : provider.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(provider.defaultModel.isEmpty
                             ? "No model selected" : provider.defaultModel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            keyStatusPill(hasKey: hasKey)
                            if isActive {
                                Text("Default")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.accent.opacity(0.15),
                                                in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("provider-card")
            .accessibilityLabel(provider.label)

            Button {
                store.setActive(provider.id)
            } label: {
                Image(systemName: isActive
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isActive ? Theme.accent : Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "Default provider" : "Set as default")
        }
        .padding(16)
        .background(cardBackground)
    }

    private func keyStatusPill(hasKey: Bool) -> some View {
        Label(hasKey ? "Key saved" : "No key",
              systemImage: hasKey ? "checkmark.seal.fill" : "key.slash")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hasKey ? Theme.accent.opacity(0.15)
                               : Color.orange.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(hasKey ? Theme.accent : Color.orange)
    }

    // MARK: - Other cards

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No providers yet")
                .font(.headline)
            Text("Add an OpenAI-compatible endpoint to start chatting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(cardBackground)
    }

    private var addProviderButton: some View {
        Button {
            detailTarget = ProviderConfig(
                id: UUID(), label: "", baseURL: "",
                defaultModel: "", isActive: false
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 21))
                Text("Add provider")
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(Theme.accent)
            .padding(16)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func keychainErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keychain unavailable")
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
        .accessibilityIdentifier("settings-keychain-error")
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("App", "BrainNotes")
            Divider().padding(.leading, 0)
            row("Version", "1.0")
            Divider()
            row("Storage", "Keychain")
        }
        .padding(.vertical, 4)
        .background(cardBackground)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Brand-tinted avatar tile used by provider cards and the detail header.
struct ProviderAvatar: View {
    let label: String
    var isActive: Bool = false
    var size: CGFloat = 46

    private var initial: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isActive
                            ? [Theme.accentDeep, Theme.accentDark]
                            : [Color(.systemGray3), Color(.systemGray2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
