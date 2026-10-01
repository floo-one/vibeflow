import Foundation
import Observation

/// Per-app presets plus the global default, persisted as JSON in UserDefaults.
/// Resolution is exact bundle id match, else the default (design: preset schema).
@MainActor
@Observable
public final class AppPresetStore: PresetResolving {
    private static let storageKey = "presets.v1"

    private struct Stored: Codable {
        var defaultPreset: AppPreset
        var presets: [AppPreset]
    }

    private let defaults: UserDefaults

    /// The global default (bundleID is always nil).
    public var defaultPreset: AppPreset {
        didSet {
            // @Observable makes this a computed property: assigning here re-enters didSet,
            // so normalize only when needed and let the re-entry do the save.
            if defaultPreset.bundleID != nil { defaultPreset.bundleID = nil; return }
            save()
        }
    }

    /// Per-app presets, each with a non-nil, unique bundleID.
    public private(set) var presets: [AppPreset] {
        didSet { save() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            defaultPreset = stored.defaultPreset
            presets = stored.presets.filter { $0.bundleID != nil }
        } else {
            // First run: ElevenLabs unconditionally; provider selection handles the no-key case (R2-2).
            defaultPreset = .default
            presets = []
        }
    }

    public func preset(for bundleID: String?) -> AppPreset {
        guard let bundleID, let match = presets.first(where: { $0.bundleID == bundleID }) else { return defaultPreset }
        return match
    }

    /// Adds or replaces the preset for its bundleID. Ignored when bundleID is nil.
    public func upsert(_ preset: AppPreset) {
        guard let id = preset.bundleID, !id.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.bundleID == id }) {
            presets[i] = preset
        } else {
            presets.append(preset)
            presets.sort { ($0.bundleID ?? "") < ($1.bundleID ?? "") }
        }
    }

    public func remove(bundleID: String) {
        presets.removeAll { $0.bundleID == bundleID }
    }

    /// A new per-app preset seeded from the default.
    public func newPreset(bundleID: String) -> AppPreset {
        var p = defaultPreset
        p.bundleID = bundleID
        return p
    }

    private func save() {
        let stored = Stored(defaultPreset: defaultPreset, presets: presets)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
