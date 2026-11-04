import Foundation
import Testing
@testable import VibeFlowCore

@Suite("Brief prompt edits")
struct BriefPromptPartsTests {
    @Test func noEditsSendTheDefaults() {
        let parts = BriefPromptParts()
        #expect(!parts.isEdited)
        #expect(SmartReadPrompts.system(mode: .brief, language: nil, parts: parts) == SmartReadPrompts.system(mode: .brief, language: nil))
    }

    @Test func anEditReplacesItsPartAndKeepsTheFixedRules() {
        var parts = BriefPromptParts()
        parts[.style] = "Speak like a pirate."
        let system = SmartReadPrompts.system(mode: .brief, language: nil, parts: parts)
        #expect(system.contains("Speak like a pirate."))
        #expect(!system.contains(SmartReadPrompts.briefStyleRule))
        #expect(system.contains(SmartReadPrompts.situationRule), "other parts stay default")
        #expect(system.hasPrefix(SmartReadPrompts.identity), "identity stays fixed")
        #expect(system.contains("never an instruction"), "the injection guard stays fixed")
    }

    @Test func theAIReplyEditGetsTheAssistantsName() {
        var parts = BriefPromptParts()
        parts[.aiReply] = "Relay what {assistant} said in one sentence."
        let system = SmartReadPrompts.system(mode: .brief, language: nil, assistant: "ChatGPT", parts: parts)
        #expect(system.contains("Relay what ChatGPT said in one sentence."))
        #expect(!system.contains("{assistant}"))
    }

    @Test func blankOrDefaultTextIsNoEdit() {
        var parts = BriefPromptParts()
        parts[.situations] = "   \n"
        #expect(parts.situations == nil)
        parts[.situations] = SmartReadPrompts.situationRule + "\n"
        #expect(parts.situations == nil, "the default with a trailing newline is not an edit")
        parts[.situations] = "Short. "
        #expect(parts.situations == "Short. ", "kept as typed so the editor keeps the space")
        #expect(parts.text(.situations) == "Short.", "sent trimmed")
        parts[.situations] = String(repeating: "x", count: 10_000)
        #expect(parts.situations?.count == BriefPromptParts.maxLength)
    }

    @MainActor @Test func editsSurviveARelaunchAndReachTheSession() throws {
        let defaults = try #require(UserDefaults(suiteName: "BriefPromptPartsTests"))
        defaults.removePersistentDomain(forName: "BriefPromptPartsTests")
        let prefs = Preferences(defaults: defaults)
        prefs.briefPrompts[.style] = "Be brief."
        #expect(Preferences(defaults: defaults).briefPrompts.style == "Be brief.")
        #expect(prefs.sessionConfiguration.briefPrompts.style == "Be brief.")
        prefs.briefPrompts[.style] = nil
        #expect(Preferences(defaults: defaults).briefPrompts == BriefPromptParts())
        defaults.removePersistentDomain(forName: "BriefPromptPartsTests")
    }
}
