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
    @Test func defaultsMatchTheSessionConfiguration() {
        let p = Preferences(defaults: scratchDefaults())
        #expect(p.sizeCap == SessionConfiguration().sizeCap)
        #expect(p.smartReadModel == SessionConfiguration().smartReadModel)
        #expect(p.launchAtLogin == false)
    }

    @Test func sizeCapIsClampedToTheModelLimitAndPersisted() {
        let defaults = scratchDefaults()
        let p = Preferences(defaults: defaults)
        p.sizeCap = 90_000
        #expect(p.sizeCap == 40_000)
        p.sizeCap = 10
        #expect(p.sizeCap == 1_000)
        p.sizeCap = 25_000
        #expect(Preferences(defaults: defaults).sizeCap == 25_000)
        #expect(p.sessionConfiguration.sizeCap == 25_000)
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
