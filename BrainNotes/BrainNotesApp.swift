import SwiftUI
import SwiftData

@main
struct BrainNotesApp: App {
    /// One on-device store for bots and their messages.
    @State private var container: ModelContainer?
    @State private var providers = ProviderStore()
    /// The owner's web-tool configuration (TinyFish, Monid) — read by the
    /// settings screen for keys and switches, and by the engine for every
    /// bot's research pass.
    @State private var webTools = WebToolStore()
    @State private var engine: ChatEngine

    init() {
        let schema = Schema([Bot.self, Message.self, ImportantNote.self, Crew.self])
        // UI tests run against a clean in-memory store so each launch starts
        // from the empty state.
        let isUITesting = CommandLine.arguments.contains("-ui-testing")
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isUITesting
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
        let opened: ModelContainer?
        #if DEBUG
        if isUITesting && CommandLine.arguments.contains("-simulate-store-open-failure") {
            opened = nil
        } else {
            opened = try? ModelContainer(for: schema, configurations: [config])
        }
        #else
        opened = try? ModelContainer(for: schema, configurations: [config])
        #endif
        _container = State(initialValue: opened)
        let store = ProviderStore()
        _providers = State(initialValue: store)
        let web = WebToolStore()
        _webTools = State(initialValue: web)
        _engine = State(initialValue: ChatEngine(providers: store, webTools: web))
        guard let container = opened else { return }
        do {
            let bots = try container.mainContext.fetch(FetchDescriptor<Bot>())
            for bot in bots { bot.migrateConfigurationIfNeeded() }
            try container.mainContext.save()
        } catch {
            assertionFailure("Could not migrate bot configurations: \(error)")
        }
        Self.backfillImageFlags(in: container.mainContext)

        // A long seeded thread, so UI tests can exercise scrolling behaviour
        // that only shows up with more content than fits on screen.
        if CommandLine.arguments.contains("-seed-long-chat") {
            Self.seedChat(in: container.mainContext, count: 60)
        } else if CommandLine.arguments.contains("-seed-short-chat") {
            // Small control thread used by the differential performance test.
            Self.seedChat(in: container.mainContext, count: 6)
        } else if CommandLine.arguments.contains("-seed-rich-chat") {
            // Every content shape a bubble can take, for visual checks.
            Self.seedRichChat(in: container.mainContext)
        } else if CommandLine.arguments.contains("-seed-captain-crew") {
            // Captain with a crew aboard and one manifest reply in its
            // thread, so UI checks can exercise the deck and the crew card
            // without a network round-trip.
            Self.seedCaptainCrew(in: container.mainContext)
        }
    }

    /// One-time repair for messages saved before `hasImageAttachment` existed.
    ///
    /// The flag is the render path's source of truth so a bubble never has to
    /// fault the external-storage blob, so threads written by an older build
    /// would otherwise render every photo as absent.
    private static func backfillImageFlags(in context: ModelContext) {
        let key = "confabula.imageFlagBackfill.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        let withImages = try? context.fetch(
            FetchDescriptor<Message>(
                predicate: #Predicate { $0.imageData != nil }
            )
        )
        for message in withImages ?? [] where !message.hasImageAttachment {
            message.hasImageAttachment = true
        }
        try? context.save()
    }

    private static func seedChat(in context: ModelContext, count: Int) {
        let bot = Bot(name: "Scroll Test")
        bot.persona = "Seeded for scrolling."
        context.insert(bot)
        let now = Date()
        for i in 0..<count {
            let mine = i % 2 == 0
            let m = Message(
                text: mine
                    ? "Outgoing message number \(i) with enough words to wrap onto a second line in the bubble."
                    : "Incoming reply number \(i), also long enough to occupy a couple of lines so the thread is tall.",
                author: mine ? .me : .bot,
                timestamp: now.addingTimeInterval(Double(i) * 30),
                delivery: mine ? .read : .delivered
            )
            m.bot = bot
            context.insert(m)
        }
        try? context.save()
    }

    /// A thread covering every bubble shape: short and long prose, formatted
    /// replies, a link, a quoted answer, each delivery state and a photo.
    private static func seedRichChat(in context: ModelContext) {
        let bot = Bot(name: "Rich Test")
        bot.persona = "Seeded for visual checks."
        bot.avatarEmoji = "🦉"
        context.insert(bot)

        let now = Date()
        var index = 0

        @discardableResult
        func add(_ text: String,
                 mine: Bool,
                 quote: Message? = nil,
                 delivery: DeliveryState = .read) -> Message {
            index += 1
            let message = Message(
                text: text,
                author: mine ? .me : .bot,
                timestamp: now.addingTimeInterval(Double(index) * 60),
                delivery: delivery,
                replyToText: quote?.text,
                replyToAuthor: quote.map { $0.isFromMe ? "You" : bot.name },
                replyToIsMine: quote?.isFromMe ?? false
            )
            message.bot = bot
            context.insert(message)
            return message
        }

        add("Hi! Send me anything.", mine: false)
        add("Short one", mine: true)
        add("Got it — that one is short, so its timestamp rides along on the same line.",
            mine: false)
        let request = add("Can you draft a launch note? https://example.com/brief", mine: true)

        add("""
        ## Launch note

        Three things worth saying out loud:

        - The editor works offline, so **nothing is lost** on a train.
        - Photos attach straight from the camera roll.
        - Everything is stored on device; `API keys` live in the Keychain.

        > Ship the small thing, then make it good.

        ---

        Want me to trim it to one paragraph?
        """, mine: false, quote: request, delivery: .delivered)

        add("""
        Sure. Here's a one-paragraph version:

        ```
        BrainNotes keeps every idea safe on your device, with an editor that
        works offline and a private AI that never learns from your notes.
        ```

        1. Keep the opening sentence.
        2. Cut the list.
        """, mine: false, delivery: .read)

        add("That's the one. Saving it now.", mine: true, delivery: .read)

        // The three delivery states a bubble can show on its own.
        add("Delivered", mine: true, delivery: .delivered)
        add("Sent", mine: true, delivery: .sent)
        add("Still sending", mine: true, delivery: .sending)
        add("Failed to send", mine: true, delivery: .failed)

        try? context.save()
    }

    /// Captain and two crews it has already assembled — the exact shapes
/// `CrewCard`, `CrewDeckView` and `CrewManifestCard` exist to render.
///
/// Each crew is a unit of work: the Content Squad drafts scripts and the
/// Research Crew sources them. The seed leaves Captain free as Chief of Staff
/// and lets UI tests exercise the deck and the manifest card without a network
/// round-trip.
    private static func seedCaptainCrew(in context: ModelContext) {
        let captain = CaptainProfile.makeBot()
        context.insert(captain)

        struct CrewSeed {
            let name: String
            let mission: String
            let emoji: String
            let accent: String
            let specialists: [(name: String, role: String, emoji: String)]
        }

        let seeds: [CrewSeed] = [
            CrewSeed(
                name: "Content Squad",
                mission: "Turns this week's AI trends into short-form video scripts.",
                emoji: "🎬",
                accent: "00A884",
                specialists: [
                    ("Trend Scout", "Ranks the week's biggest AI stories.", "🔭"),
                    ("Script Chef", "Turns approved trends into short video scripts.", "✍️"),
                    ("Fact Sentinel", "Checks every claim against a source.", "🛡️"),
                ]),
            CrewSeed(
                name: "Research Crew",
                mission: "Sources and verifies facts before any draft ships.",
                emoji: "🧪",
                accent: "6A5ACD",
                specialists: [
                    ("Source Finder", "Surfaces primary sources for every claim.", "📚"),
                    ("Verifier", "Cross-checks each claim across two sources.", "✅"),
                ]),
        ]

        for seed in seeds {
            var bots: [Bot] = []
            for entry in seed.specialists {
                let bot = Bot(name: entry.name, avatarEmoji: entry.emoji,
                              role: entry.role)
                bot.isCaptainManaged = true
                context.insert(bot)
                bots.append(bot)
            }
            let crew = Crew(
                name: seed.name,
                mission: seed.mission,
                emoji: seed.emoji,
                accentColorHex: seed.accent,
                members: bots)
            context.insert(crew)
        }

        let now = Date()
        let ask = Message(
            text: "Captain, assemble me a content crew and a research crew.",
            author: .me, timestamp: now.addingTimeInterval(-180),
            delivery: .read)
        ask.bot = captain
        context.insert(ask)

        let manifest = """
        Two crews on the deck, President. Each one owns a single outcome:

        ```confabula-actions
        [
          {
            "action": "create_crew",
            "name": "Content Squad",
            "mission": "Turns this week's AI trends into short-form video scripts.",
            "emoji": "🎬",
            "accentColorHex": "00A884",
            "members": [
              {
                "name": "Trend Scout",
                "role": "Ranks the week's biggest AI stories.",
                "responsibilities": ["Surface five stories", "Cite one source per story"],
                "negativeRules": "Never invent stats or sources.",
                "agePerspective": 33,
                "creativity": 0.5
              },
              {
                "name": "Script Chef",
                "role": "Turns approved trends into short video scripts.",
                "responsibilities": ["One script per approved trend"],
                "negativeRules": "Drafts only — never publishes.",
                "agePerspective": 28,
                "creativity": 0.8
              },
              {
                "name": "Fact Sentinel",
                "role": "Checks every claim against a source.",
                "responsibilities": ["Flag anything unsourced"],
                "negativeRules": "Never pass a claim without evidence.",
                "agePerspective": 40,
                "creativity": 0.2
              }
            ]
          },
          {
            "action": "create_crew",
            "name": "Research Crew",
            "mission": "Sources and verifies facts before any draft ships.",
            "emoji": "🧪",
            "accentColorHex": "6A5ACD",
            "members": [
              {
                "name": "Source Finder",
                "role": "Surfaces primary sources for every claim.",
                "responsibilities": ["One primary link per claim"],
                "negativeRules": "No aggregator-only citations.",
                "agePerspective": 35,
                "creativity": 0.3
              },
              {
                "name": "Verifier",
                "role": "Cross-checks each claim across two sources.",
                "responsibilities": ["Two-source rule on every fact"],
                "negativeRules": "Never pass a claim on a single source.",
                "agePerspective": 42,
                "creativity": 0.1
              }
            ]
          }
        ]
        ```

        I'm staying free to coordinate — tap a crew to see who's on it.
        """
        let reply = Message(text: manifest, author: .bot,
                            timestamp: now.addingTimeInterval(-60),
                            delivery: .delivered)
        reply.bot = captain
        context.insert(reply)
        try? context.save()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    Group {
                        if CommandLine.arguments.contains("-probe-layout") {
                            DebugLayoutProbe()
                        } else {
                            ChatListView()
                        }
                    }
                    .modelContainer(container)
                } else {
                    ContentUnavailableView {
                        Label("Unable to Open Saved Data", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved store has not been replaced or deleted. Chats are unavailable until it can be opened. Try again after checking available device storage. Do not uninstall the app if you need to preserve its data.")
                    } actions: {
                        Button("Try Again", action: retryStorage)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("storage-retry")
                    }
                }
            }
                .environment(providers)
                .environment(engine)
                .environment(webTools)
                .tint(Theme.accent)
                .preferredColorScheme(nil)
        }
    }

    private func retryStorage() {
        #if DEBUG
        if CommandLine.arguments.contains("-ui-testing")
            && CommandLine.arguments.contains("-simulate-store-open-failure") { return }
        #endif
        let schema = Schema([Bot.self, Message.self, ImportantNote.self, Crew.self])
        let config = ModelConfiguration(schema: schema,
            isStoredInMemoryOnly: CommandLine.arguments.contains("-ui-testing"))
        do {
            let reopened = try ModelContainer(for: schema, configurations: [config])
            let bots = try reopened.mainContext.fetch(FetchDescriptor<Bot>())
            for bot in bots { bot.migrateConfigurationIfNeeded() }
            try reopened.mainContext.save()
            Self.backfillImageFlags(in: reopened.mainContext)
            container = reopened
        } catch {
            container = nil
        }
    }
}
