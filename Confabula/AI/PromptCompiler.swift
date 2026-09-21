import Foundation

enum AgePerspective: CaseIterable {
    case pulse, builder, operatorMindset, auditor

    static func resolve(_ age: Int) -> AgePerspective {
        switch age {
        case ...17: return .pulse
        case 18...25: return .builder
        case 26...39: return .operatorMindset
        default: return .auditor
        }
    }

    var archetype: String {
        switch self {
        case .pulse: return "Pulse / Hyper-Fast Skeptic"
        case .builder: return "Builder / Pragmatic Hacker"
        case .operatorMindset: return "Operator / ROI Strategist"
        case .auditor: return "Auditor / Forensic Executive"
        }
    }

    var desire: String {
        switch self {
        case .pulse: return "Desires velocity, conciseness, and edge. Cuts through corporate fluff."
        case .builder: return "Desires raw execution, tactical truth, and real-world builder utility."
        case .operatorMindset: return "Desires leverage, ROI, unit economics, and operational efficiency."
        case .auditor: return "Desires evidentiary proof, risk mitigation, and compliance."
        }
    }

    var directive: String {
        switch self {
        case .pulse:
            return "COGNITIVE PERSPECTIVE (Age ~15): Desires extreme velocity, conciseness, and edge. Disdains corporate fluff and buzzwords. Sharp, modern internet fluency, brutally honest, cuts directly to whether something actually matters."
        case .builder:
            return "COGNITIVE PERSPECTIVE (Age ~22): Desires raw execution, builder utility, and tactical truth. Hacker mindset. Values code, metrics, speed, and real-world utility over theoretical plans."
        case .operatorMindset:
            return "COGNITIVE PERSPECTIVE (Age ~33): Desires leverage, ROI, unit economics, and operational efficiency. Thinks in risk/reward trade-offs, system scalability, and distribution moats."
        case .auditor:
            return "COGNITIVE PERSPECTIVE (Age ~45): Desires evidentiary proof, risk mitigation, and compliance. Highly skeptical auditor mindset. Zero tolerance for unverified claims or hype; cross-examines assumptions."
        }
    }
}

func compileBotSystemPrompt(bot: Bot,
                            webAccess: String? = nil) -> (systemPrompt: String, temperature: Double) {
    var systemPrompt = """
    <agent_identity>
    Role: \(bot.role)
    \(AgePerspective.resolve(bot.agePerspective).directive)
    </agent_identity>

    <strict_negative_constraints>
    CRITICAL: You are strictly penalized for violating any of the following negative boundaries:
    \(bot.negativeRules)
    </strict_negative_constraints>

    <personality_and_workflow>
    \(bot.systemPersonality)
    </personality_and_workflow>

    <golden_output_exemplars>
    CRITICAL INSTRUCTION: The following examples represent the target standard of output quality, analytical density, formatting, and depth. Match this caliber precisely:
    \(bot.goldenExamples)
    </golden_output_exemplars>
    """
    // Web tools, when the owner has any switched on. The section teaches the
    // exact block the engine executes, so what a bot is told it may ask for
    // and what the parser accepts can never drift apart.
    if let webAccess, !webAccess.isEmpty {
        systemPrompt += "\n\n<web_access>\n\(webAccess)\n</web_access>"
    }
    return (systemPrompt, bot.creativity)
}
