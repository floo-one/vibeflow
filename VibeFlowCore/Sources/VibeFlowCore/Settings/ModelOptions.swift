import Foundation

/// One entry in a Settings model picker.
public struct ModelOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public init(_ id: String, _ name: String) {
        self.id = id
        self.name = name
    }
}

/// The curated model choices. Each list was checked against the live APIs: ElevenLabs on
/// 2026-10-06 (all four accept stream/with-timestamps with language_code and speed), Groq and
/// Anthropic in the T1 spike. The first entry is the default.
public enum ModelOptions {
    public static let voice = [
        ModelOption("eleven_flash_v2_5", "Flash v2.5 (fastest)"),
        ModelOption("eleven_turbo_v2_5", "Turbo v2.5"),
        ModelOption("eleven_multilingual_v2", "Multilingual v2 (most natural)"),
        ModelOption("eleven_v3", "v3 (most expressive, slower)"),
    ]

    public static let smartRead = [
        ModelOption("claude-haiku-5-5", "Claude Haiku 5.5 (fastest)"),
        ModelOption("claude-haiku-4-5", "Claude Haiku 4.5"),
        ModelOption("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ModelOption("claude-opus-5-5", "Claude Opus 5.5 (most careful)"),
    ]

    public static let transcription = [
        ModelOption("whisper-large-v3", "Whisper large v3 (most accurate)"),
        ModelOption("whisper-large-v3-turbo", "Whisper large v3 turbo (faster)"),
    ]

    /// "" turns cleanup off.
    public static let cleanupOff = ""
    public static let cleanup = [
        ModelOption("qwen/qwen3.8-27b", "Qwen 3.8 27B (fastest)"),
        ModelOption("openai/gpt-oss-20b", "GPT-OSS 20B"),
        ModelOption("openai/gpt-oss-120b", "GPT-OSS 120B"),
        ModelOption(cleanupOff, "Off: paste the raw transcript"),
    ]
}
