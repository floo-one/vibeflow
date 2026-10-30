import Foundation
import Testing
@testable import VibeFlowCore

/// A throwaway UserDefaults suite per test so nothing touches the real settings.
func scratchDefaults() -> UserDefaults {
    let name = "vibeflow-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Suite("AppPresetStore") @MainActor
struct PresetStoreTests {
    @Test func firstRunDefaultIsElevenLabsBriefSpeedOne() {
        let store = AppPresetStore(defaults: scratchDefaults())
        #expect(store.defaultPreset.provider == .elevenLabs)
        #expect(store.defaultPreset.speed == 1.0)
        #expect(store.defaultPreset.smartReadEnabled)
        #expect(store.defaultPreset.smartReadMode == .brief)
        #expect(store.presets.isEmpty)
    }

    @Test func exactBundleMatchElseDefault() {
        let store = AppPresetStore(defaults: scratchDefaults())
        store.upsert(AppPreset(bundleID: "com.apple.Preview", provider: .apple, smartReadEnabled: false))
        #expect(store.preset(for: "com.apple.Preview").provider == .apple)
        #expect(store.preset(for: "com.apple.Preview").smartReadEnabled == false)
        #expect(store.preset(for: "com.apple.Safari") == store.defaultPreset)
        #expect(store.preset(for: nil) == store.defaultPreset)
    }

    @Test func persistsAcrossInstances() {
        let defaults = scratchDefaults()
        let a = AppPresetStore(defaults: defaults)
        a.defaultPreset.speed = 1.4
        a.upsert(AppPreset(bundleID: "com.tinyspeck.slackmacgap", elevenLabsVoiceID: "fast"))
        let b = AppPresetStore(defaults: defaults)
        #expect(b.defaultPreset.speed == 1.4)
        #expect(b.preset(for: "com.tinyspeck.slackmacgap").elevenLabsVoiceID == "fast")
    }

    @Test func upsertReplacesAndRemoveDeletes() {
        let store = AppPresetStore(defaults: scratchDefaults())
        store.upsert(AppPreset(bundleID: "a", speed: 1.0))
        store.upsert(AppPreset(bundleID: "a", speed: 1.2))
        #expect(store.presets.count == 1)
        #expect(store.preset(for: "a").speed == 1.2)
        store.remove(bundleID: "a")
        #expect(store.presets.isEmpty)
        store.upsert(AppPreset(bundleID: nil))
        #expect(store.presets.isEmpty, "a preset without a bundle id is never stored per app")
    }

    @Test func defaultPresetNeverKeepsABundleID() {
        let store = AppPresetStore(defaults: scratchDefaults())
        store.defaultPreset = AppPreset(bundleID: "oops", speed: 0.9)
        #expect(store.defaultPreset.bundleID == nil)
        #expect(store.defaultPreset.speed == 0.9)
    }
}

@Suite("Preferences") @MainActor
struct PreferencesTests {
    @Test func modelsDefaultToTheFirstOptionAndPersist() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        #expect(p.voiceModel == "eleven_flash_v2_5")
        #expect(p.smartReadModel == "claude-haiku-5-5")
        #expect(p.sessionConfiguration.smartReadModel == "claude-haiku-5-5")
        #expect(p.transcriptionModel == "whisper-large-v3")
        #expect(p.cleanupModel == "qwen/qwen3.8-27b")
        #expect(p.speakerUID == nil)
        p.voiceModel = "eleven_multilingual_v2"
        p.smartReadModel = "claude-sonnet-5-5"
        p.cleanupModel = ModelOptions.cleanupOff
        p.speakerUID = "BuiltInSpeakerDevice"
        let q = Preferences(defaults: defaults)
        #expect(q.voiceModel == "eleven_multilingual_v2")
        #expect(q.sessionConfiguration.smartReadModel == "claude-sonnet-5-5")
        #expect(q.cleanupModel == "")
        #expect(q.speakerUID == "BuiltInSpeakerDevice")
    }

    @Test func defaultsAndPersistence() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        #expect(p.launchAtLogin == false)
        #expect(p.vocabularyTerms.isEmpty)
        #expect(p.microphoneUID == nil)
        p.vocabulary = "Anna, VibeFlow"
        p.microphoneUID = "usb-mic"
        let q = Preferences(defaults: defaults)
        #expect(q.vocabularyTerms == ["Anna", "VibeFlow"])
        #expect(q.microphoneUID == "usb-mic")
    }

    @Test func dictationCuesDefaultOnAndPersist() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        #expect(p.dictationSounds)
        #expect(p.notchIndicator)
        p.dictationSounds = false
        p.notchIndicator = false
        let q = Preferences(defaults: defaults)
        #expect(!q.dictationSounds)
        #expect(!q.notchIndicator)
    }

    @Test func listeningStyleDefaultsToDotAndPersists() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        #expect(p.listeningStyle == .dot)
        p.listeningStyle = .bars
        #expect(Preferences(defaults: defaults).listeningStyle == .bars)
        defaults.set("sparkle", forKey: "feel.listeningStyle")
        #expect(Preferences(defaults: defaults).listeningStyle == .dot)
    }

    @Test func colorModeDefaultsToSystemAndPersists() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        #expect(p.colorMode == .system)
        p.colorMode = .dark
        #expect(Preferences(defaults: defaults).colorMode == .dark)
        defaults.set("sepia", forKey: "feel.colorMode")
        #expect(Preferences(defaults: defaults).colorMode == .system)
    }

    @Test func vocabularyAcceptsLinesAndCommas() {
        #expect(Preferences.parseVocabulary("VibeFlow, Groq\n  Kokoro \n\n,ElevenLabs") == ["VibeFlow", "Groq", "Kokoro", "ElevenLabs"])
    }
}

@Suite("Keep this app on this Mac") struct KeepOnThisMacTests {
    @Test func oneSwitchSetsAllThreePrivacyRules() {
        var p = AppPreset(bundleID: "com.apple.Notes")
        #expect(!p.keepsOnThisMac)
        p.keepsOnThisMac = true
        #expect(p.provider == .apple && !p.smartReadEnabled && p.dictationLocalOnly)
        p.keepsOnThisMac = false
        #expect(p.provider == .elevenLabs && p.smartReadEnabled && !p.dictationLocalOnly)
    }

    @Test func partlyLocalPresetsCountAsNotKept() {
        // A v1 preset with the Apple voice and smart read off still dictates through Groq.
        let p = AppPreset(bundleID: "a", provider: .apple, smartReadEnabled: false)
        #expect(!p.keepsOnThisMac)
    }
}

@Suite("AppPreset decoding") struct AppPresetDecodingTests {
    /// Presets saved before smartReadInstructions existed must still load.
    @Test func oldStoredPresetWithoutInstructionsDecodes() throws {
        let old = #"{"provider":"apple","elevenLabsVoiceID":"v","appleVoiceByLanguage":{},"speed":1.1,"smartReadEnabled":false,"smartReadMode":"brief"}"#
        let p = try JSONDecoder().decode(AppPreset.self, from: Data(old.utf8))
        #expect(p.smartReadInstructions == nil)
        #expect(p.speed == 1.1)
        #expect(p.provider == .apple)
    }
}
