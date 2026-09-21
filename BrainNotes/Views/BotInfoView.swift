import SwiftUI
import SwiftData

/// Read-only "contact info" screen for a bot, mirroring a messenger's profile
/// page: large avatar, stats, personality summary and destructive actions.
struct BotInfoView: View {
    @Bindable var bot: Bot

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderStore.self) private var providers

    @State private var showEditor = false
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false

    private var effectiveModel: String {
        if !bot.model.isEmpty { return bot.model }
        return providers.active?.defaultModel ?? "not set"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color(hex: bot.avatarColorHex),
                                             Color(hex: bot.avatarColorHex).opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                                .frame(width: 108, height: 108)
                            Text(bot.avatarEmoji).font(.system(size: 54))
                        }
                        Text(bot.name).font(.title2.weight(.semibold))
                        Text("AI contact").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("Details") {
                    LabeledContent("Messages", value: "\(bot.messages.count)")
                    LabeledContent("Model", value: effectiveModel)
                    LabeledContent("Creativity",
                                   value: String(format: "%.2f", bot.creativity))
                    LabeledContent("Age perspective", value: "\(bot.agePerspective)")
                    LabeledContent("Created", value: bot.createdAt.formatted(
                        date: .abbreviated, time: .shortened))
                    LabeledContent("Provider", value: providers.active?.label ?? "None")
                }

                if !bot.role.isEmpty {
                    Section("Role & Authority") { Text(bot.role) }
                }
                if !bot.negativeRules.isEmpty {
                    Section("Strict Negative Rules") { Text(bot.negativeRules) }
                }
                if !bot.systemPersonality.isEmpty {
                    Section("System Prompt & Workflow") { Text(bot.systemPersonality) }
                }
                if !bot.goldenExamples.isEmpty {
                    Section("Output as Examples") {
                        Text(bot.goldenExamples).font(.system(.body, design: .monospaced))
                    }
                }

                Section("Actions") {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit bot configuration", systemImage: "slider.horizontal.3")
                    }
                    Toggle(isOn: $bot.isPinned) {
                        Label("Pin to top", systemImage: "pin")
                    }
                    Toggle(isOn: $bot.isMuted) {
                        Label("Mute notifications", systemImage: "bell.slash")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear chat", systemImage: "eraser")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete bot", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Bot info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showEditor) {
                BotEditorView(bot: bot)
            }
            .confirmationDialog("Clear all messages?", isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive, action: clearHistory)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \(bot.name)?", isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteBot)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The bot and its entire chat history will be removed.")
            }
        }
    }

    private func clearHistory() {
        for m in bot.messages { context.delete(m) }
        bot.messages = []
        try? context.save()
    }

    private func deleteBot() {
        context.delete(bot)
        try? context.save()
        dismiss()
    }
}
