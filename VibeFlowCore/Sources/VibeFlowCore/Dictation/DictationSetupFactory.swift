import Foundation

public enum TranscriberChoice: String, Codable, Sendable, CaseIterable {
    case groq
    /// Any OpenAI-compatible /audio/transcriptions endpoint (local servers, other providers).
    case custom
    /// Apple on-device (macOS 26).
    case apple
}

/// The dictation settings from Preferences, as one value.
public struct DictationSettings: Sendable, Equatable {
    public var transcriber: TranscriberChoice
    public var transcriptionModel: String
    public var customEndpoint: String
    public var cleanupEnabled: Bool
    public var cleanupProvider: CleanupProvider
    public var cleanupModel: String
    public var vocabulary: [String]

    public init(transcriber: TranscriberChoice = .groq, transcriptionModel: String = OpenAITranscriber.defaultModel, customEndpoint: String = "",
                cleanupEnabled: Bool = true, cleanupProvider: CleanupProvider = .groq, cleanupModel: String = ChatCompletionsCleaner.defaultModel,
                vocabulary: [String] = []) {
        self.transcriber = transcriber
        self.transcriptionModel = transcriptionModel
        self.customEndpoint = customEndpoint
        self.cleanupEnabled = cleanupEnabled
        self.cleanupProvider = cleanupProvider
        self.cleanupModel = cleanupModel
        self.vocabulary = vocabulary
    }

    /// One term per line or comma separated; blanks dropped.
    public static func parseVocabulary(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Builds the DictationSetup for one dictation from the settings and the stored keys, applying
/// the design's fallback table:
///
/// - Groq: falls back to Apple on device. With no Groq key, Apple is used directly with a
///   status note; without Apple (macOS 15) the missing key surfaces with Open Keys.
/// - Custom endpoint: a key is optional (local servers); falls back to Apple.
/// - Apple: alone, no fallback.
public enum DictationSetupFactory {
    public static let onDeviceName = "On-device dictation"

    public static func make(
        settings: DictationSettings,
        secrets: any SecretsStore,
        http: any HTTPClient,
        onDevice: (any Transcriber)?,
        microphoneUID: String?
    ) -> DictationSetup {
        var notice: String?
        let transcriber: FallbackTranscriber
        let model = settings.transcriptionModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? OpenAITranscriber.defaultModel : settings.transcriptionModel

        switch settings.transcriber {
        case .groq:
            if secrets.read(.groq) == nil, let onDevice {
                transcriber = FallbackTranscriber(primary: onDevice, fallback: nil, primaryName: onDeviceName)
                notice = "Transcribed on device: no Groq key"
            } else {
                let groq = OpenAITranscriber(http: http, model: model, apiKey: { secrets.read(.groq) })
                transcriber = FallbackTranscriber(primary: groq, fallback: onDevice, primaryName: "Groq")
            }
        case .custom:
            if let url = customURL(settings.customEndpoint) {
                let custom = OpenAITranscriber(http: http, baseURL: url, model: model, keyRequired: false,
                                               apiKey: { secrets.read(.customEndpoint) })
                transcriber = FallbackTranscriber(primary: custom, fallback: onDevice, primaryName: "Custom endpoint")
            } else {
                transcriber = FallbackTranscriber(
                    primary: UnavailableTranscriber(reason: "Set the custom endpoint URL in Settings > Dictation"),
                    fallback: nil, primaryName: "Custom endpoint")
            }
        case .apple:
            transcriber = FallbackTranscriber(
                primary: onDevice ?? UnavailableTranscriber(reason: "On-device dictation needs macOS 26"),
                fallback: nil, primaryName: onDeviceName)
        }

        var cleaner: (any DictationCleaner)?
        if settings.cleanupEnabled {
            switch settings.cleanupProvider {
            case .groq:
                let cleanupModel = settings.cleanupModel.trimmingCharacters(in: .whitespaces).isEmpty
                    ? ChatCompletionsCleaner.defaultModel : settings.cleanupModel
                cleaner = ChatCompletionsCleaner(http: http, model: cleanupModel, apiKey: { secrets.read(.groq) })
            case .anthropic:
                cleaner = AnthropicCleaner(client: AnthropicClient(http: http, secrets: secrets))
            }
        }

        return DictationSetup(transcriber: transcriber, onDevice: onDevice, cleaner: cleaner,
                              vocabulary: settings.vocabulary, microphoneUID: microphoneUID, notice: notice)
    }

    /// http or https with a host, nil otherwise.
    static func customURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Stands in for a transcriber that cannot run, so the failure reaches the user as a Last error.
struct UnavailableTranscriber: Transcriber {
    let reason: String
    func transcribe(_ audio: RecordedAudio, language: String?) async throws -> Transcription {
        throw TranscriptionFailure.unavailable(reason)
    }
}
