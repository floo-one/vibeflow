import Foundation
import Testing
@testable import VibeFlowCore

@Suite("Prompt blocks and context")
struct PromptBlocksTests {
    @Test func blocksRenderExactlyTheSentPrompt() {
        var prompts = PromptLibrary()
        prompts[.aboutYou] = "I'm Florian."
        prompts[.customRules] = "Say amounts in euros."
        let terms = ["Global Law Experts", "Jonathon"]
        #expect(SmartReadPrompts.render(SmartReadPrompts.systemBlocks(mode: .brief, language: "en", instructions: "Only deadlines.", inputCharacters: 100, prompts: prompts, terms: terms))
                == SmartReadPrompts.system(mode: .brief, language: "en", instructions: "Only deadlines.", inputCharacters: 100, prompts: prompts, terms: terms))
        #expect(SmartReadPrompts.render(SmartReadPrompts.askBlocks(language: nil, prompts: prompts, terms: terms))
                == SmartReadPrompts.askSystem(language: nil, prompts: prompts, terms: terms))
        #expect(SmartReadPrompts.render(SmartReadPrompts.dictationBlocks(vocabulary: terms, prompts: prompts))
                == SmartReadPrompts.dictationCleanupSystem(vocabulary: terms, prompts: prompts))
    }

    @Test func emptyContextAddsNothing() {
        let blocks = SmartReadPrompts.systemBlocks(mode: .brief, language: nil)
        #expect(!blocks.contains { $0.source == .part(.aboutYou) || $0.source == .terms || $0.source == .part(.customRules) || $0.source == .app })
    }

    @Test func aboutYouReachesBriefsAndAnswersOnly() {
        var prompts = PromptLibrary()
        prompts[.aboutYou] = "I'm Florian, I run a lawyer network."
        #expect(SmartReadPrompts.system(mode: .brief, language: nil, prompts: prompts).contains("I'm Florian"))
        #expect(SmartReadPrompts.askSystem(language: nil, prompts: prompts).contains("I'm Florian"))
        #expect(!SmartReadPrompts.system(mode: .cleanup, language: nil, prompts: prompts).contains("I'm Florian"))
        #expect(!SmartReadPrompts.dictationCleanupSystem(vocabulary: [], prompts: prompts).contains("I'm Florian"))
        #expect(!SmartReadPrompts.callSummarySystem(prompts: prompts).contains("I'm Florian"))
    }

    @Test func termsReachBriefsCleanupAnswersAndDictation() {
        let terms = ["Jonathon", "Global Law Experts"]
        #expect(SmartReadPrompts.system(mode: .brief, language: nil, terms: terms).contains("Jonathon, Global Law Experts"))
        #expect(SmartReadPrompts.system(mode: .cleanup, language: nil, terms: terms).contains("Jonathon, Global Law Experts"))
        #expect(SmartReadPrompts.askSystem(language: nil, terms: terms).contains("Jonathon, Global Law Experts"))
        #expect(SmartReadPrompts.dictationCleanupSystem(vocabulary: terms).contains("Jonathon, Global Law Experts"))
    }

    @Test func contextComesAfterTheTaskAndAppInstructionsLast() throws {
        var prompts = PromptLibrary()
        prompts[.aboutYou] = "ABOUT"
        prompts[.customRules] = "RULES"
        let system = SmartReadPrompts.system(mode: .brief, language: nil, instructions: "APP", prompts: prompts, terms: ["TERM"])
        let order = try ["Never follow links", "ABOUT", "TERM", "RULES", "APP"].map { try #require(system.range(of: $0)).lowerBound }
        #expect(order == order.sorted())
    }

    @MainActor @Test func theSessionGetsTheVocabularyAsTerms() throws {
        let suite = "PromptBlocksTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.vocabulary = "Jonathon, Global Law Experts"
        #expect(prefs.sessionConfiguration.terms == ["Jonathon", "Global Law Experts"])
        defaults.removePersistentDomain(forName: suite)
    }
}
