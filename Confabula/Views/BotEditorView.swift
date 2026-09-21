import SwiftUI
import SwiftData

/// Create or edit a bot’s identity and six-pillar configuration.
struct BotEditorView: View {
    /// nil means "create a new bot".
    var bot: Bot?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var colorHex = Theme.defaultAvatarHexes[0]
    @State private var role = ""
    @State private var negativeRules = ""
    @State private var systemPersonality = ""
    @State private var goldenExamples = ""
    @State private var agePerspective = 33.0
    @State private var hasLoaded = false
    @State private var saveError: String?
    @State private var greeting = ""
    @State private var model = ""
    @State private var creativity = 0.7
    @State private var showDeleteConfirm = false
    @State private var showEmojiPicker = false

    private var isEditing: Bool { bot != nil }
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                roleSection
                negativeRulesSection
                workflowSection
                examplesSection
                ageSection
                creativitySection
                Section("Greeting") {
                    TextField("Optional", text: $greeting, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityLabel("Greeting")
                }
                Section("Model") {
                    TextField("Provider default", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Model")
                }
                if isEditing { dangerSection }
            }
            .navigationTitle(isEditing ? "Edit bot" : "New bot")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .confirmationDialog(
                "Delete \(trimmedName.isEmpty ? "this bot" : trimmedName)?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: deleteBot)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The bot and its entire chat history will be removed.")
            }
            .alert("Couldn’t save bot", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
            .onAppear(perform: load)
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Bot") {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)

            Button {
                showEmojiPicker.toggle()
            } label: {
                HStack {
                    Text("Avatar")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(emoji).font(.system(size: 22))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if showEmojiPicker {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                          spacing: 10) {
                    ForEach(Theme.emojiPalette, id: \.self) { e in
                        Button {
                            emoji = e
                        } label: {
                            Text(e).font(.system(size: 26))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    emoji == e
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                          spacing: 10) {
                    ForEach(Theme.defaultAvatarHexes, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(height: 30)
                                .overlay(
                                    Circle().stroke(Color.primary,
                                                    lineWidth: colorHex == hex ? 2.5 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var roleSection: some View {
        Section("Role") {
            optionalInput($role, label: "Role", identifier: "bot.role")
        }
    }

    private var negativeRulesSection: some View {
        Section("Rules") {
            optionalInput($negativeRules, label: "Rules", identifier: "bot.negativeRules")
        }
    }

    private var workflowSection: some View {
        Section("Instructions") {
            optionalInput($systemPersonality, label: "Instructions", identifier: "bot.systemPersonality")
        }
    }

    private var examplesSection: some View {
        Section("Examples") {
            optionalInput($goldenExamples, label: "Examples", identifier: "bot.goldenExamples")
        }
    }

    private func optionalInput(_ text: Binding<String>, label: String, identifier: String) -> some View {
        TextField("Optional", text: text, axis: .vertical)
            .lineLimit(1...6)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var ageSection: some View {
        Section("Age") {
            HStack {
                Slider(value: $agePerspective, in: 12...50, step: 1)
                    .accessibilityLabel("Age")
                    .accessibilityValue("\(Int(agePerspective))")
                    .accessibilityIdentifier("bot.agePerspective")
                Text("\(Int(agePerspective))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var creativitySection: some View {
        Section("Creativity") {
            HStack {
                Slider(value: $creativity, in: 0...1, step: 0.05)
                    .accessibilityLabel("Creativity")
                    .accessibilityValue(String(format: "%.2f", creativity))
                    .accessibilityIdentifier("bot.creativity")
                Text(String(format: "%.2f", creativity))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete bot", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Actions

    /// SwiftUI keeps the software keyboard up until focus is cleared; resigning
    /// the responder directly is what actually dismisses it from a toolbar.
    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let bot else { return }
        name = bot.name
        emoji = bot.avatarEmoji
        colorHex = bot.avatarColorHex
        role = bot.role
        negativeRules = bot.negativeRules
        systemPersonality = bot.systemPersonality
        goldenExamples = bot.goldenExamples
        agePerspective = Double(max(12, min(50, bot.agePerspective)))
        greeting = bot.greeting
        creativity = bot.creativity.isFinite ? max(0, min(1, bot.creativity)) : 0.7
        model = bot.model
    }

    private func save() {
        hideKeyboard()
        let greetingText = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Untitled bot" : trimmedName
        let target = bot ?? Bot(name: resolvedName)
        let previous = (target.name, target.avatarEmoji, target.avatarColorHex, target.role,
                        target.negativeRules, target.systemPersonality, target.goldenExamples,
                        target.agePerspective, target.creativity, target.greeting, target.model)
        target.name = resolvedName
        target.avatarEmoji = emoji
        target.avatarColorHex = colorHex
        target.role = role
        target.negativeRules = negativeRules
        target.systemPersonality = systemPersonality
        target.goldenExamples = goldenExamples
        target.agePerspective = Int(agePerspective)
        target.creativity = creativity
        target.greeting = greetingText
        target.model = resolvedModel
        var opener: Message?
        if bot == nil {
            context.insert(target)
            if !greetingText.isEmpty {
                let message = Message(text: greetingText, author: .bot, delivery: .delivered)
                message.bot = target
                context.insert(message)
                opener = message
            }
        }
        do {
            try context.save()
            dismiss()
        } catch {
            if bot == nil {
                if let opener { context.delete(opener) }
                context.delete(target)
            } else {
                (target.name, target.avatarEmoji, target.avatarColorHex, target.role,
                 target.negativeRules, target.systemPersonality, target.goldenExamples,
                 target.agePerspective, target.creativity, target.greeting, target.model) = previous
            }
            saveError = error.localizedDescription
        }
    }

    private func deleteBot() {
        guard let bot else { return }
        context.delete(bot)
        try? context.save()
        dismiss()
    }
}
