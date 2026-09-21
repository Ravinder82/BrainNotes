import SwiftUI

/// One unified screen per provider: identity, endpoint, model and API key all
/// editable in place, with a connection test. Replaces the old flow where the
/// key lived behind separate "Add key" / "Replace key" screens.
struct ProviderDetailView: View {
    @State private var config: ProviderConfig
    private let onSave: (ProviderConfig) -> Void

    @Environment(ProviderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var key: String = ""
    @State private var revealed = false
    @State private var testState: TestState = .idle
    @State private var fetchedModels: [RemoteModel] = []
    @State private var showModels = false
    /// When on, the model picker hides text-only models.
    @State private var imagesOnly = false
    @State private var showPresets = false
    @State private var showDeleteConfirm = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case label, baseURL, model, key }

    private enum TestState: Equatable {
        case idle, testing, ok(Int), failed(String)
    }

    init(config: ProviderConfig, onSave: @escaping (ProviderConfig) -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
    }

    private var isNew: Bool {
        config.label.isEmpty && config.baseURL.isEmpty
    }

    private var canSave: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasStoredKey: Bool { !key.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                identitySection
                keySection
                modelSection
                verifySection
                if !isNew { dangerSection }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(isNew ? "New Provider" : (config.label.isEmpty ? "Provider" : config.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit).disabled(!canSave)
                        .accessibilityIdentifier("provider-save")
                }
            }
            .sheet(isPresented: $showModels) { modelPicker }
            .sheet(isPresented: $showPresets) { presetPicker }
            .confirmationDialog(
                "Delete \(config.label.isEmpty ? "provider" : config.label)?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.remove(config.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the provider and its stored API key.")
            }
            .onAppear {
                key = KeychainStore.read(account: config.id.uuidString) ?? ""
                store.lastKeychainError = nil
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                ProviderAvatar(label: config.label,
                               isActive: store.activeProviderID == config.id,
                               size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.label.isEmpty ? "New provider" : config.label)
                        .font(.title3.weight(.semibold))
                    Text(config.defaultModel.isEmpty
                         ? "Choose a model below" : config.defaultModel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private var identitySection: some View {
        Section {
            HStack {
                Text("Name")
                Spacer()
                TextField("OpenAI", text: $config.label)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .label)
                    .accessibilityIdentifier("provider-name")
            }
            HStack {
                Text("Base URL")
                Spacer()
                TextField("https://api.openai.com/v1", text: $config.baseURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .baseURL)
                    .accessibilityIdentifier("provider-baseurl")
            }
            Button {
                focusedField = nil
                showPresets = true
            } label: {
                Label("Quick fill from a known provider",
                      systemImage: "wand.and.stars")
                    .font(.subheadline)
            }
        } header: {
            Text("Endpoint")
        }
    }

    private var keySection: some View {
        Section {
            HStack(spacing: 8) {
                if revealed {
                    TextField("sk-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .key)
                        .accessibilityIdentifier("api-key-field")
                } else {
                    SecureField("sk-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .key)
                        .accessibilityIdentifier("api-key-field")
                }
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "Hide key" : "Show key")
            }

            if hasStoredKey {
                Button(role: .destructive) {
                    key = ""
                    store.setAPIKey("", for: config.id)
                } label: {
                    Label("Remove key", systemImage: "trash")
                        .font(.subheadline)
                }
            }

            if let error = store.lastKeychainError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(error)
                        .accessibilityIdentifier("keychain-error")
                }
                .font(.footnote)
                .foregroundStyle(.red)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text(hasStoredKey
                 ? "A key is saved in the iOS Keychain on this device."
                 : "Stored in the iOS Keychain on this device only; sent only to your provider.")
        }
    }

    private var modelSection: some View {
        Section {
            HStack {
                Text("Model")
                Spacer()
                TextField("gpt-4o-mini", text: $config.defaultModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)
                    .accessibilityIdentifier("provider-model")
            }
            if !fetchedModels.isEmpty {
                Button {
                    focusedField = nil
                    showModels = true
                } label: {
                    Label("Choose from \(fetchedModels.count) available models",
                          systemImage: "list.bullet")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Tip: run Test Connection first to pull the model list "
                 + "straight from your provider.")
        }
    }

    private var verifySection: some View {
        Section {
            Button {
                focusedField = nil
                Task { await test() }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                    Spacer()
                    testBadge
                }
            }
            .disabled(config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                      || testState == .testing)
        } header: {
            Text("Verify")
        } footer: {
            if case .failed(let msg) = testState {
                Text(msg).foregroundStyle(.red)
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete provider", systemImage: "trash")
            }
        }
    }

    // MARK: - Sheets

    private var modelPicker: some View {
        let shown = imagesOnly
            ? fetchedModels.filter { $0.visionSupport != .unsupported }
            : fetchedModels
        return NavigationStack {
            List(shown) { model in
                Button {
                    config.defaultModel = model.id
                    showModels = false
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.id).foregroundStyle(.primary)
                            visionBadge(model.visionSupport)
                        }
                        Spacer()
                        if model.id == config.defaultModel {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(
                        "No matching models",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("No models in this list accept images. "
                                          + "Turn off the filter to see all.")
                    )
                }
            }
            .navigationTitle("Models (\(shown.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showModels = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Toggle("Images", isOn: $imagesOnly)
                        .toggleStyle(.button)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private func visionBadge(_ support: VisionSupport) -> some View {
        switch support {
        case .supported:
            Label("Images", systemImage: "photo")
                .font(.caption2)
                .foregroundStyle(Theme.accent)
        case .unsupported:
            Label("Text only", systemImage: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var presetPicker: some View {
        NavigationStack {
            List(presets, id: \.label) { preset in
                Button {
                    apply(preset)
                    showPresets = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.label)
                            .foregroundStyle(.primary)
                            .font(.subheadline.weight(.medium))
                        Text(preset.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("preset-\(preset.label)")
                }
            }
            .navigationTitle("Providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPresets = false }
                }
            }
        }
    }

    // MARK: - Logic

    /// Clears focus and resigns the responder so a tap outside the field
    /// always closes the keyboard.
    private func hideKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func apply(_ preset: Preset) {
        config.label = preset.label
        config.baseURL = preset.url
        config.defaultModel = preset.model
        testState = .idle
        fetchedModels = []
    }

    private func commit() {
        var c = config
        c.label = c.label.trimmingCharacters(in: .whitespaces)
        c.baseURL = c.baseURL.trimmingCharacters(in: .whitespaces)
        c.defaultModel = c.defaultModel.trimmingCharacters(in: .whitespaces)
        if c.label.isEmpty { c.label = derivedLabel }
        onSave(c)

        // Persist the key in place — no separate screen, and surface failure
        // rather than dismissing as if it worked. An empty field means "delete",
        // so clearing the field and saving always removes the stored key too.
        store.setAPIKey(key, for: c.id)
        if store.lastKeychainError == nil {
            dismiss()
        }
    }

    private var derivedLabel: String {
        guard let host = URL(string: config.baseURL)?.host else { return "Provider" }
        return host.replacingOccurrences(of: "www.", with: "")
            .split(separator: ".").first.map(String.init)?.capitalized ?? host
    }

    @ViewBuilder
    private var testBadge: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .ok(let n):
            Label("\(n) models", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func test() async {
        testState = .testing
        let client = OpenAIClient(baseURL: config.baseURL, apiKey: key)
        do {
            let models = try await client.fetchModels()
            fetchedModels = models
            testState = .ok(models.count)
            // Share the capability map so the chat screen's attach button
            // reflects this provider's real model support.
            store.setAPIKey(key, for: config.id)
            await store.catalog.refresh(provider: config, apiKey: key)
        } catch {
            fetchedModels = []
            testState = .failed(error.localizedDescription)
        }
    }

    struct Preset {
        let label: String
        let url: String
        let model: String
    }

    /// OpenAI-compatible endpoints, including the Gemini compatibility API.
    private var presets: [Preset] {
        [
            Preset(label: "OpenAI", url: "https://api.openai.com/v1",
                   model: "gpt-4o-mini"),
            Preset(label: "OpenRouter", url: "https://openrouter.ai/api/v1",
                   model: "openai/gpt-4o-mini"),
            Preset(label: "Google Gemini",
                   url: "https://generativelanguage.googleapis.com/v1beta/openai",
                   model: "gemini-2.0-flash"),
            Preset(label: "Groq", url: "https://api.groq.com/openai/v1",
                   model: "llama-3.3-70b-versatile"),
            Preset(label: "Together", url: "https://api.together.xyz/v1",
                   model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
            Preset(label: "DeepSeek", url: "https://api.deepseek.com/v1",
                   model: "deepseek-chat"),
            Preset(label: "Mistral", url: "https://api.mistral.ai/v1",
                   model: "mistral-small-latest"),
            Preset(label: "xAI Grok", url: "https://api.x.ai/v1",
                   model: "grok-2-latest"),
            Preset(label: "Ollama (local)", url: "http://localhost:11434/v1",
                   model: "llama3.2"),
            Preset(label: "LM Studio (local)", url: "http://localhost:1234/v1",
                   model: "local-model"),
        ]
    }
}
