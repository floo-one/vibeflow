import Foundation
import Observation

/// The few settings that are not per-app presets, backed by UserDefaults: a model per job,
/// the audio devices and launch at login. Shortcuts live in KeyboardShortcuts' own storage;
/// keys live in the Keychain.
@MainActor
@Observable
public final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let voiceModel = "voiceModel"
        static let smartReadModel = "smartReadModel"
        static let transcriptionModel = "dictation.transcriptionModel"
        static let cleanupModel = "dictation.cleanupModel"
        static let vocabulary = "dictation.vocabulary"
        static let microphoneUID = "dictation.microphoneUID"
        static let speakerUID = "speakerUID"
        static let worldClocks = "clocks.worldClocks"
    }

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    /// ElevenLabs model for reads.
    public var voiceModel: String {
        didSet { defaults.set(voiceModel, forKey: Key.voiceModel) }
    }
    public var smartReadModel: String {
        didSet { defaults.set(smartReadModel, forKey: Key.smartReadModel) }
    }
    /// Groq Whisper model for dictation.
    public var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Key.transcriptionModel) }
    }
    /// Groq chat model for dictation cleanup; ModelOptions.cleanupOff turns cleanup off.
    public var cleanupModel: String {
        didSet { defaults.set(cleanupModel, forKey: Key.cleanupModel) }
    }
    /// Names and terms dictation cleanup should spell correctly. Not in Settings yet.
    public var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }
    /// nil = Automatic (D7).
    public var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) }
    }
    /// Output device for the ElevenLabs voice, nil = system output.
    public var speakerUID: String? {
        didSet { defaults.set(speakerUID, forKey: Key.speakerUID) }
    }

    /// Clocks in the menu bar, in order; empty hides the item. Starts with Berlin.
    public var worldClocks: [WorldClock] {
        didSet { defaults.set(try? JSONEncoder().encode(worldClocks), forKey: Key.worldClocks) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        voiceModel = defaults.string(forKey: Key.voiceModel) ?? ModelOptions.voice[0].id
        smartReadModel = defaults.string(forKey: Key.smartReadModel) ?? ModelOptions.smartRead[0].id
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel) ?? ModelOptions.transcription[0].id
        cleanupModel = defaults.string(forKey: Key.cleanupModel) ?? ModelOptions.cleanup[0].id
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
        speakerUID = defaults.string(forKey: Key.speakerUID)
        worldClocks = defaults.data(forKey: Key.worldClocks)
            .flatMap { try? JSONDecoder().decode([WorldClock].self, from: $0) } ?? [.berlin]
    }

    public var vocabularyTerms: [String] { Self.parseVocabulary(vocabulary) }

    /// One term per line or comma separated; blanks dropped.
    public static func parseVocabulary(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The read session's configuration with the chosen smart read model.
    public var sessionConfiguration: SessionConfiguration {
        var config = SessionConfiguration()
        config.smartReadModel = smartReadModel
        return config
    }
}
