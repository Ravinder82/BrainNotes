import SwiftUI

/// The app palette, plus the scheme-aware accessors every chat surface resolves
/// through.
///
/// Views never branch on `colorScheme` themselves. A surface asks `Theme` for
/// the colour it needs — `Theme.chatBackground(scheme)` — and gets the right one
/// for the current mode, so light/dark behaviour lives in exactly one place.
enum Theme {

    // MARK: - Palette

    static let accent = Color(hex: "00A884")
    static let accentHex = "00A884"
    static let accentDeep = Color(hex: "008069")
    static let linkBlue = Color(hex: "027EB5")
    static let tickBlue = Color(hex: "53BDEB")
    static let unreadBadge = Color(hex: "25D366")

    // Light surfaces
    static let chatBackgroundLight = Color(hex: "EFEAE2")
    static let barLight = Color(hex: "F7F7F7")
    static let incomingLight = Color(hex: "FFFFFF")
    static let outgoingLight = Color(hex: "D9FDD3")
    static let composerFieldLight = Color(hex: "FFFFFF")

    // Dark surfaces
    static let chatBackgroundDark = Color(hex: "0B141A")
    static let barDark = Color(hex: "1F2C34")
    static let incomingDark = Color(hex: "202C33")
    static let outgoingDark = Color(hex: "005C4B")
    static let composerFieldDark = Color(hex: "2A3942")

    // MARK: - Chat surfaces

    /// Wallpaper behind the thread. Chosen to sit *behind* the bubbles rather
    /// than match them: an incoming bubble is white, so the thread needs a
    /// tinted ground or the bubble disappears into it.
    static func chatBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? chatBackgroundDark : chatBackgroundLight
    }

    /// Navigation bar and composer bar.
    static func bar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? barDark : barLight
    }

    /// The text field the user types into.
    static func composerField(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? composerFieldDark : composerFieldLight
    }

    /// The date pill that separates days in the thread.
    static func datePill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "182229") : Color.white.opacity(0.92)
    }

    static func outgoingBubble(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? outgoingDark : outgoingLight
    }

    static func incomingBubble(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? incomingDark : incomingLight
    }

    /// Hairline that keeps a bubble's edge legible when its fill is close to
    /// the wallpaper — a white bubble on a light thread, or two darks.
    static func bubbleBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    /// Incoming bubbles get the messenger's subtle drop shadow. Outgoing ones
    /// stay flat, matching the design where only received messages lift off the
    /// wallpaper.
    static func bubbleShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.12)
    }

    /// Timestamp and delivery ticks inside a bubble. Fixed opacities rather than
    /// `.secondary`, which is tuned for the app background and reads too light
    /// on a coloured bubble.
    static func bubbleMeta(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.60) : Color.black.opacity(0.45)
    }

    /// Body text inside a bubble. `.primary` adapts per mode, and both bubble
    /// fills are dark enough in dark mode for label white to stay readable.
    static func bubbleText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.87)
    }

    // MARK: - Bot editor choices

    /// Avatar tints offered in the bot editor.
    static let defaultAvatarHexes = [
        "6A5ACD", "E67E22", "16A085", "C0392B", "2980B9",
        "8E44AD", "D35400", "27AE60", "F39C12", "2C3E50",
    ]

    /// Selectable model presets for the BYOK picker.
    static let modelPresets = [
        "gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini",
        "o4-mini", "llama-3.3-70b-versatile", "gemini-2.0-flash",
        "claude-3-5-sonnet", "deepseek-chat", "qwen2.5-72b-instruct",
    ]

    static let emojiPalette = [
        "🤖", "🧠", "🦉", "🐙", "🦊", "🐼", "🐝", "🦄", "👩‍💻", "🧑‍🍳",
        "🧑‍🏫", "🧑‍⚕️", "🧑‍🚀", "🕵️", "🎨", "📚", "⚡️", "🌙", "🍀", "🔥",
        "💡", "🎯", "🧘", "🎬", "🎵", "🏋️", "✈️", "🧾", "🛠️", "🗂️",
    ]
}

extension Color {
    /// Builds a colour from "RRGGBB" or "AARRGGBB". Anything else falls back to
    /// mid grey rather than trapping, because the string can come from stored
    /// model data.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
