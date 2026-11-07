import Foundation

/// Which provider produced the text, and why the fallback ran if it did.
public struct TranscriptionOutcome: Sendable, Equatable {
    public var transcription: Transcription
    /// nil = the primary answered. Otherwise the reason shown in the status line.
    public var fellBackBecause: String?

    public init(transcription: Transcription, fellBackBecause: String? = nil) {
        self.transcription = transcription
        self.fellBackBecause = fellBackBecause
    }
}

/// Applies the design's fallback table between the selected provider and Apple on-device.
///
/// Falls back on: offline, timeout, 429, 5xx, and (Groq only) a missing key.
/// Surfaces without fallback: 401/403, any other 4xx, malformed responses, and a custom
/// endpoint's missing key. Every fallback reports its reason for the status line.
public struct FallbackTranscriber: Sendable {
    public let primary: any Transcriber
    /// nil when no on-device fallback exists (macOS 15, or the user picked Apple as primary).
    public let fallback: (any Transcriber)?
    public let primaryName: String

    public init(primary: any Transcriber, fallback: (any Transcriber)?, primaryName: String) {
        self.primary = primary
        self.fallback = fallback
        self.primaryName = primaryName
    }

    public func transcribe(_ audio: RecordedAudio, language: String?) async throws -> TranscriptionOutcome {
        do {
            return TranscriptionOutcome(transcription: try await primary.transcribe(audio, language: language))
        } catch let failure as TranscriptionFailure {
            guard let reason = Self.fallbackReason(for: failure), let fallback else { throw failure }
            let transcription = try await fallback.transcribe(audio, language: language)
            return TranscriptionOutcome(transcription: transcription, fellBackBecause: "\(primaryName) \(reason)")
        }
    }

    /// nil = surface the error; otherwise a short reason ("unavailable (offline)").
    public static func fallbackReason(for failure: TranscriptionFailure) -> String? {
        switch failure {
        case .offline: return "unavailable (offline)"
        case .timeout: return "unavailable (timed out)"
        case .rateLimited: return "unavailable (rate limited)"
        case .serverError(let code): return "unavailable (HTTP \(code))"
        case .unauthorized, .rejected, .malformed, .assetsMissing, .unavailable: return nil
        }
    }
}
