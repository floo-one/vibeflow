import AVFoundation
import Testing
@testable import VibeFlowCore

@Suite("AppleSpeech: selection and rate")
struct AppleSpeechTests {
    let catalog = [
        AppleVoice(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", name: "Samantha"),
        AppleVoice(identifier: "com.apple.voice.compact.en-GB.Daniel", language: "en-GB", name: "Daniel"),
        AppleVoice(identifier: "com.apple.voice.compact.de-DE.Anna", language: "de-DE", name: "Anna"),
    ]

    @Test func presetVoiceWinsWhenInstalled() {
        let s = AppleSpeech.select(language: "en-US", presetVoices: ["en-US": "com.apple.voice.compact.en-GB.Daniel"], catalog: catalog, systemLanguage: "en-US")
        #expect(s == AppleSpeech.Selection(voiceIdentifier: "com.apple.voice.compact.en-GB.Daniel", language: "en-US", missing: false))
    }

    @Test func presetVoiceThatIsNotInstalledIsIgnored() {
        let s = AppleSpeech.select(language: "en-US", presetVoices: ["en-US": "gone"], catalog: catalog, systemLanguage: "en-US")
        #expect(s.voiceIdentifier == "com.apple.voice.compact.en-US.Samantha")
    }

    @Test func detectedPrimaryLanguageFindsARegionalVoice() {
        let s = AppleSpeech.select(language: "de", presetVoices: [:], catalog: catalog, systemLanguage: "en-US")
        #expect(s.voiceIdentifier == "com.apple.voice.compact.de-DE.Anna")
        #expect(s.missing == false)
    }

    @Test func noVoiceForLanguageFallsToSystemDefaultAndSaysSo() {
        let s = AppleSpeech.select(language: "fr-FR", presetVoices: [:], catalog: catalog, systemLanguage: "en-US")
        #expect(s == AppleSpeech.Selection(voiceIdentifier: nil, language: "fr-FR", missing: true))
        #expect(AppleSpeech.missingVoiceNotice(for: "fr-FR").hasPrefix("No "))
        #expect(AppleSpeech.missingVoiceNotice(for: "fr-FR").hasSuffix(" voice installed"))
    }

    @Test func nilLanguageUsesTheSystemLanguage() {
        let s = AppleSpeech.select(language: nil, presetVoices: [:], catalog: catalog, systemLanguage: "de-DE")
        #expect(s.language == "de-DE")
        #expect(s.voiceIdentifier == "com.apple.voice.compact.de-DE.Anna")
    }

    @Test func rateScalesTheDefaultAndClamps() {
        #expect(AppleSpeech.rate(for: 1.0) == AVSpeechUtteranceDefaultSpeechRate)
        #expect(AppleSpeech.rate(for: 1.5) == min(AVSpeechUtteranceDefaultSpeechRate * 1.5, AVSpeechUtteranceMaximumSpeechRate))
        #expect(AppleSpeech.rate(for: 0.0) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(AppleSpeech.rate(for: 10.0) == AVSpeechUtteranceMaximumSpeechRate)
    }

    @MainActor
    @Test func missingVoiceEmitsANoticeBeforeSpeaking() async throws {
        struct EmptyCatalog: AppleVoiceCatalog {
            func voices() -> [AppleVoice] { [] }
            var systemLanguage: String { "en-US" }
        }
        let provider = AppleSpeechProvider(catalog: EmptyCatalog())
        let playback = provider.speak(SpeechRequest(text: "", voiceID: "ignored", language: "de-DE"))
        var events: [SpeechEvent] = []
        for try await e in playback.events { events.append(e) }
        #expect(events.first == .notice(AppleSpeech.missingVoiceNotice(for: "de-DE")))
        #expect(events.last == .finished, "empty text finishes immediately without the synthesizer")
    }
}
