import SwiftUI

/// Web Search & Data: the owner's two research providers, one card each.
///
/// The screen follows the AI Providers card language — same corner radius,
/// same avatar tile, same status pills — because these are the same kind of
/// object: a key the owner pastes once so every bot can use a capability.
/// What it adds over a bare key field is the two things this feature needs to
/// be trustworthy: a live probe (so "saved" and "works" can't be confused) and
/// the price story, because Monid runs spend real balance.
struct WebToolsSettingsView: View {
    @Environment(WebToolStore.self) private var store

    /// Text being typed for a provider's key, before it is saved.
    @State private var drafts: [WebProviderID: String] = [:]
    /// Providers whose saved key is being replaced.
    @State private var replacing: Set<WebProviderID> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                introCard
                ForEach(WebProviderID.allCases) { id in
                    providerCard(id)
                }
                if let error = store.lastKeychainError {
                    keychainErrorCard(error)
                }
                howItWorksCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Web Search & Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Intro

    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "globe.desk.fill")
                .font(.system(size: 21))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Live web for every bot")
                    .font(.headline)
                Text("When a task needs current facts, prices, or sources, a bot asks for the web. "
                     + "The app runs the lookup and hands back the results, so answers cite real sources "
                     + "instead of guessing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(activeSummary)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(store.anyActive ? Theme.accent.opacity(0.15)
                                                    : Color.orange.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(store.anyActive ? Theme.accent : Color.orange)
                        .accessibilityIdentifier("webtools-active-summary")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var activeSummary: String {
        let active = WebProviderID.allCases.filter { store.isActive($0) }
        if active.isEmpty { return "No tools active" }
        return active.map(\.displayName).joined(separator: " + ") + " active"
    }

    // MARK: - Provider card

    private func providerCard(_ id: WebProviderID) -> some View {
        let hasKey = store.hasKey(for: id)
        let isActive = store.isActive(id)
        let isEditing = replacing.contains(id) || !hasKey

        return VStack(alignment: .leading, spacing: 0) {
            header(id, hasKey: hasKey, isActive: isActive)

            Text(id.blurb)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            capabilityChips(id)
                .padding(.top, 10)

            Divider().padding(.vertical, 12)

            keySection(id, hasKey: hasKey, isEditing: isEditing)

            probeRow(id)

            if id == .monid, let balance = store.monidBalance {
                HStack(spacing: 8) {
                    Image(systemName: "wallet.bifold.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                    Text("Balance \(balance.formatted)")
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("webtools-balance-monid")
            }

            Text(id.costNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(16)
        .background(cardBackground)
    }

    private func header(_ id: WebProviderID, hasKey: Bool, isActive: Bool) -> some View {
        HStack(spacing: 13) {
            providerTile(id, isActive: isActive)

            VStack(alignment: .leading, spacing: 5) {
                Text(id.displayName)
                    .font(.headline)
                Text(id.role)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    keyStatusPill(hasKey: hasKey)
                    if hasKey {
                        Label(isActive ? "On" : "Off",
                              systemImage: isActive ? "bolt.fill" : "bolt.slash")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isActive ? Theme.accent.opacity(0.15)
                                                 : Color(.tertiarySystemFill),
                                        in: Capsule())
                            .foregroundStyle(isActive ? Theme.accent : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Use for bots", isOn: Binding(
                get: { store.isEnabled(id) },
                set: { store.setEnabled($0, for: id) }))
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Use \(id.displayName) for bots")
                .accessibilityIdentifier("webtools-toggle-\(id.rawValue)")
        }
    }

    private func providerTile(_ id: WebProviderID, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(
                colors: isActive ? [Theme.accent, Theme.accentDeep]
                                 : [Color(.systemGray3), Color(.systemGray2)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 46, height: 46)
            .overlay(
                Image(systemName: id.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white))
    }

    private func capabilityChips(_ id: WebProviderID) -> some View {
        HStack(spacing: 6) {
            ForEach(id.capabilities, id: \.self) { capability in
                Text(capability)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func keyStatusPill(hasKey: Bool) -> some View {
        Label(hasKey ? "Key saved" : "No key",
              systemImage: hasKey ? "checkmark.seal.fill" : "key.slash")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hasKey ? Theme.accent.opacity(0.15) : Color.orange.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(hasKey ? Theme.accent : Color.orange)
            .accessibilityIdentifier("webtools-status-\(hasKey ? "saved" : "missing")")
    }

    // MARK: - Key entry

    @ViewBuilder
    private func keySection(_ id: WebProviderID, hasKey: Bool, isEditing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("API key")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if hasKey, let masked = store.maskedKey(for: id), !isEditing {
                    Text(masked)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("webtools-masked-\(id.rawValue)")
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    SecureField(id.keyPlaceholder, text: binding(for: id))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .submitLabel(.done)
                        .accessibilityIdentifier("webtools-key-field-\(id.rawValue)")

                    Button("Save") { save(id) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled((drafts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("webtools-save-\(id.rawValue)")
                }
                if hasKey {
                    Button("Cancel") {
                        drafts[id] = ""
                        replacing.remove(id)
                    }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Button("Replace") {
                        replacing.insert(id)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("webtools-replace-\(id.rawValue)")

                    Button("Remove", role: .destructive) {
                        store.removeKey(for: id)
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityIdentifier("webtools-remove-\(id.rawValue)")

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func binding(for id: WebProviderID) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" },
                set: { drafts[id] = $0 })
    }

    private func save(_ id: WebProviderID) {
        store.setKey(drafts[id] ?? "", for: id)
        drafts[id] = ""
        replacing.remove(id)
    }

    // MARK: - Probe

    private func probeRow(_ id: WebProviderID) -> some View {
        let probe = store.probes[id] ?? .idle
        return HStack(spacing: 10) {
            Button {
                Task { await store.probe(id) }
            } label: {
                switch probe {
                case .testing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                case .idle:
                    Text("Test connection")
                case .passed, .failed:
                    Text("Test again")
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .disabled(!store.hasKey(for: id) || probe == .testing)
            .accessibilityIdentifier("webtools-test-\(id.rawValue)")

            probeVerdict(probe)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func probeVerdict(_ probe: WebToolStore.Probe) -> some View {
        switch probe {
        case .idle:
            EmptyView()
        case .testing:
            EmptyView()
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .lineLimit(2)
                .accessibilityIdentifier("webtools-probe-passed")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(3)
                .accessibilityIdentifier("webtools-probe-failed")
        }
    }

    // MARK: - Footer

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How bots use the web")
                .font(.subheadline.weight(.semibold))
            Text("A bot that needs live data emits a small tool block in its reply. The app runs "
                 + "the search, extraction, or data call and sends the results back, then the bot "
                 + "writes its real answer with sources. The block itself never appears in the chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(destination: WebProviderID.tinyfish.docsURL) {
                    Label("TinyFish docs", systemImage: "arrow.up.right.square")
                }
                Link(destination: WebProviderID.monid.docsURL) {
                    Label("Monid docs", systemImage: "arrow.up.right.square")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
        }
        .padding(16)
        .background(cardBackground)
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
        .accessibilityIdentifier("webtools-keychain-error")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}