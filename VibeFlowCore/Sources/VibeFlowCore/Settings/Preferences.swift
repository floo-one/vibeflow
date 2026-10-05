import Foundation
import Observation

/// The few settings that are not per-app presets, backed by UserDefaults. Everything else is
/// an opinionated constant (SessionConfiguration, DictationSetupFactory).
/// Shortcuts live in KeyboardShortcuts' own storage; keys live in the Keychain.
@MainActor
@Observable
public final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let vocabulary = "dictation.vocabulary"
        static let microphoneUID = "dictation.microphoneUID"
    }

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    /// Names and terms dictation cleanup should spell correctly, one per line or comma separated.
    public var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    /// nil = Automatic (D7).
    public var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
    }

    public var vocabularyTerms: [String] { Self.parseVocabulary(vocabulary) }

    /// One term per line or comma separated; blanks dropped.
    public static func parseVocabulary(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
