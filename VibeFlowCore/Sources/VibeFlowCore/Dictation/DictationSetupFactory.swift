import Foundation

/// Builds the DictationSetup for one dictation. Opinionated: Groq Whisper large-v3 with
/// Apple on-device as the fallback, and Groq cleanup whenever a Groq key is set.
///
/// - With a Groq key: Groq transcribes, Apple takes over when offline, rate limited or down.
/// - Without one: Apple transcribes with a status note, no cleanup. On macOS 15 (no Apple
///   fallback) the missing key surfaces with Open Keys.
public enum DictationSetupFactory {
    public static let onDeviceName = "On-device dictation"

    public static func make(
        vocabulary: [String],
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
        let groq = OpenAITranscriber(http: http, apiKey: { secrets.read(.groq) })
        return DictationSetup(
            transcriber: FallbackTranscriber(primary: groq, fallback: onDevice, primaryName: "Groq"),
            onDevice: onDevice,
            cleaner: hasKey ? ChatCompletionsCleaner(http: http, apiKey: { secrets.read(.groq) }) : nil,
            vocabulary: vocabulary, microphoneUID: microphoneUID)
    }
}
