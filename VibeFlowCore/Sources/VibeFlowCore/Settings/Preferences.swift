import Foundation
import Observation

/// User settings that are not per-app presets, backed by UserDefaults.
/// Shortcuts live in KeyboardShortcuts' own storage; keys live in the Keychain.
@MainActor
@Observable
public final class Preferences {
    public static let sizeCapRange = 1_000...SessionConfiguration.hardMax

    private let defaults: UserDefaults
    private enum Key {
        static let sizeCap = "sizeCap"
        static let smartReadModel = "smartReadModel"
        static let launchAtLogin = "launchAtLogin"
        static let transcriber = "dictation.transcriber"
        static let transcriptionModel = "dictation.transcriptionModel"
        static let customEndpoint = "dictation.customEndpoint"
        static let cleanupEnabled = "dictation.cleanupEnabled"
        static let cleanupProvider = "dictation.cleanupProvider"
        static let cleanupModel = "dictation.cleanupModel"
        static let vocabulary = "dictation.vocabulary"
        static let microphoneUID = "dictation.microphoneUID"
    }

    /// Selections above this need a confirmation. Clamped to 1,000 ... 40,000 (D1).
    public var sizeCap: Int {
        didSet {
            let clamped = min(max(sizeCap, Self.sizeCapRange.lowerBound), Self.sizeCapRange.upperBound)
            if clamped != sizeCap { sizeCap = clamped; return }
            defaults.set(sizeCap, forKey: Key.sizeCap)
        }
    }

    public var smartReadModel: String {
        didSet { defaults.set(smartReadModel, forKey: Key.smartReadModel) }
    }

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    // MARK: Dictation (VibeFlow 2)

    public var transcriber: TranscriberChoice {
        didSet { defaults.set(transcriber.rawValue, forKey: Key.transcriber) }
    }
    /// Whisper model for Groq or the custom endpoint.
    public var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Key.transcriptionModel) }
    }
    /// Base URL of a custom OpenAI-compatible endpoint, e.g. http://localhost:8000/v1.
    public var customEndpoint: String {
        didSet { defaults.set(customEndpoint, forKey: Key.customEndpoint) }
    }
    public var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }
    public var cleanupProvider: CleanupProvider {
        didSet { defaults.set(cleanupProvider.rawValue, forKey: Key.cleanupProvider) }
    }
    /// Groq chat model for cleanup. Anthropic cleanup uses Haiku.
    public var cleanupModel: String {
        didSet { defaults.set(cleanupModel, forKey: Key.cleanupModel) }
    }
    /// Names and terms the cleanup should spell correctly, one per line or comma separated.
    public var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }
    /// nil = Automatic (D7).
    public var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) }
    }

    public var dictationSettings: DictationSettings {
        DictationSettings(transcriber: transcriber, transcriptionModel: transcriptionModel, customEndpoint: customEndpoint,
                          cleanupEnabled: cleanupEnabled, cleanupProvider: cleanupProvider, cleanupModel: cleanupModel,
                          vocabulary: DictationSettings.parseVocabulary(vocabulary))
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = SessionConfiguration()
        let storedCap = defaults.object(forKey: Key.sizeCap) as? Int ?? config.sizeCap
        sizeCap = min(max(storedCap, Self.sizeCapRange.lowerBound), Self.sizeCapRange.upperBound)
        smartReadModel = defaults.string(forKey: Key.smartReadModel) ?? config.smartReadModel
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        transcriber = defaults.string(forKey: Key.transcriber).flatMap(TranscriberChoice.init(rawValue:)) ?? .groq
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel) ?? OpenAITranscriber.defaultModel
        customEndpoint = defaults.string(forKey: Key.customEndpoint) ?? ""
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        cleanupProvider = defaults.string(forKey: Key.cleanupProvider).flatMap(CleanupProvider.init(rawValue:)) ?? .groq
        cleanupModel = defaults.string(forKey: Key.cleanupModel) ?? ChatCompletionsCleaner.defaultModel
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
    }

    /// The session configuration reflecting these preferences.
    public var sessionConfiguration: SessionConfiguration {
        var config = SessionConfiguration()
        config.sizeCap = sizeCap
        config.smartReadModel = smartReadModel
        return config
    }
}
