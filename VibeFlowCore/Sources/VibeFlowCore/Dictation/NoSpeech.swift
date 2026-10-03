import Foundation

/// Decides whether a transcription is really silence (design R2-10 as revised by D11).
///
/// - Every segment's no_speech_prob above 0.6: silence.
/// - The text matches a known Whisper silence hallucination ("Thank you." and similar): silence
///   only when the audio agrees, i.e. the highest segment no_speech_prob is above 0.3 or the
///   recording's RMS is below the silence threshold. A spoken "Thank you." survives.
/// - Empty text after trimming: silence.
public enum NoSpeech {
    public static let allSegmentsThreshold = 0.6
    public static let corroborationThreshold = 0.3
    /// RMS below this is treated as a silent recording. T1 measured 0.043 to 0.049 for normal
    /// speech on the built-in mic and 0.007 for a quiet one.
    public static let silenceRMS = 0.005

    public static let hallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching",
        "you", "bye", "bye.", "subtitles by the amara.org community",
        "untertitel im auftrag des zdf, 2017", "untertitel im auftrag des zdf", "untertitelung des zdf, 2020",
        "vielen dank", "vielen dank.", "danke", "danke.", "tschüss",
    ]

    public static func isSilence(_ transcription: Transcription, audio: RecordedAudio) -> Bool {
        let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }

        let probs = transcription.noSpeechProbabilities
        if !probs.isEmpty && probs.allSatisfy({ $0 > allSegmentsThreshold }) { return true }

        let normalized = text.lowercased()
        let stripped = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, "))
        guard hallucinations.contains(normalized) || hallucinations.contains(stripped) else { return false }

        let corroborated = (probs.max() ?? 0) > corroborationThreshold || audio.rms < silenceRMS
        return corroborated
    }
}
