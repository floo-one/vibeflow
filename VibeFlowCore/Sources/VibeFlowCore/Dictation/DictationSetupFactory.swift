import Foundation

/// Builds the DictationSetup for one dictation: Groq Whisper with Apple on-device as the
/// fallback, and Groq cleanup with the chosen model whenever a Groq key is set.
///
/// - With a Groq key: Groq transcribes, Apple takes over when offline, rate limited or down.
/// - Without one: Apple transcribes with a status note, no cleanup. On macOS 15 (no Apple
///   fallback) the missing key surfaces with Open Keys.
public enum DictationSetupFactory {
    public static let onDeviceName = "On-device dictation"

    public static func make(
        vocabulary: [String],
        transcriptionModel: String = ModelOptions.transcription[0].id,
        cleanupModel: String = ModelOptions.cleanup[0].id,
        secrets: any SecretsStore,
        http: any HTTPClient,
        onDevice: (any Transcriber)?,
        microphoneUID: String?
    ) -> DictationSetup {
        let hasKey = secrets.read(.groq) != nil
        if !hasKey, let onDevice {
            return DictationSetup(
                transcriber: FallbackTranscriber(primary: onDevice, fallback: nil, primaryName: onDeviceName),
                onDevice: onDevice, cleaner: nil, vocabulary: vocabulary, microphoneUID: microphoneUID,
                notice: "Transcribed on device: no Groq key")
        }
        let groq = OpenAITranscriber(http: http, model: transcriptionModel, apiKey: { secrets.read(.groq) })
        return DictationSetup(
            transcriber: FallbackTranscriber(primary: groq, fallback: onDevice, primaryName: "Groq"),
            onDevice: onDevice,
            cleaner: hasKey && cleanupModel != ModelOptions.cleanupOff
                ? ChatCompletionsCleaner(http: http, model: cleanupModel, apiKey: { secrets.read(.groq) }) : nil,
            vocabulary: vocabulary, microphoneUID: microphoneUID)
    }
}
