import AVFoundation
import Foundation

/// One installed system voice, decoupled from AVSpeechSynthesisVoice for tests.
public struct AppleVoice: Sendable, Equatable {
    public let identifier: String
    /// BCP-47, e.g. "de-DE".
    public let language: String
    public let name: String
    public init(identifier: String, language: String, name: String) {
        self.identifier = identifier
        self.language = language
        self.name = name
    }
}

/// Installed voices and the system language, behind a protocol so selection is testable.
public protocol AppleVoiceCatalog: Sendable {
    func voices() -> [AppleVoice]
    var systemLanguage: String { get }
}

/// Installed system voices, read from macOS once per launch. `speechVoices()` costs
/// 50 to 130 ms per call (180 voices), so it must never run inside a view body or per read.
public struct SystemVoiceCatalog: AppleVoiceCatalog {
    public init() {}

    /// Lazily loaded on first use; `static let` initialization is thread-safe.
    private static let cached: [AppleVoice] = AVSpeechSynthesisVoice.speechVoices()
        .map { AppleVoice(identifier: $0.identifier, language: $0.language, name: $0.name) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    private static let cachedSystemLanguage = AVSpeechSynthesisVoice.currentLanguageCode()

    public func voices() -> [AppleVoice] { Self.cached }
    public var systemLanguage: String { Self.cachedSystemLanguage }

    /// Warms the cache off the main thread so the first Settings open or Apple read is instant.
    public static func preload() {
        Task.detached(priority: .utility) { _ = cached; _ = cachedSystemLanguage }
    }
}

/// Pure selection and mapping rules (design: Speed, Language, D7).
public enum AppleSpeech {
    /// AVSpeechUtterance.rate from the preset multiplier: default rate times speed, clamped.
    public static func rate(for speed: Double) -> Float {
        let raw = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        return min(max(raw, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    public struct Selection: Equatable, Sendable {
        /// nil = let the synthesizer use the system default voice.
        public let voiceIdentifier: String?
        public let language: String
        /// True when no installed voice matches the language.
        public let missing: Bool
    }

    /// Precedence: preset's voice for the language, then the best installed voice for that
    /// language (exact tag, then same primary subtag), else the system default with `missing`.
    public static func select(language: String?, presetVoices: [String: String], catalog: [AppleVoice], systemLanguage: String) -> Selection {
        let language = language ?? systemLanguage
        let primary = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()

        if let pinned = presetVoices[language] ?? presetVoices[primary], catalog.contains(where: { $0.identifier == pinned }) {
            return Selection(voiceIdentifier: pinned, language: language, missing: false)
        }
        if let exact = catalog.first(where: { $0.language.lowercased() == language.lowercased() }) {
            return Selection(voiceIdentifier: exact.identifier, language: language, missing: false)
        }
        if let sameLanguage = catalog.first(where: { $0.language.lowercased().hasPrefix(primary + "-") || $0.language.lowercased() == primary }) {
            return Selection(voiceIdentifier: sameLanguage.identifier, language: language, missing: false)
        }
        return Selection(voiceIdentifier: nil, language: language, missing: true)
    }

    public static func missingVoiceNotice(for language: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: String(language.split(separator: "-").first ?? Substring(language))) ?? language
        return "No \(name) voice installed"
    }
}

/// Apple voices through AVSpeechSynthesizer. Speaks directly (not through the AudioPlayer);
/// cancel is stopSpeaking(.immediate) (design: Read flow, R2-12).
@MainActor
public final class AppleSpeechProvider: SpeechProvider {
    private let catalog: any AppleVoiceCatalog

    public init(catalog: any AppleVoiceCatalog = SystemVoiceCatalog()) {
        self.catalog = catalog
    }

    public func speak(_ request: SpeechRequest) -> any SpeechPlayback {
        let selection = AppleSpeech.select(language: request.language, presetVoices: request.appleVoiceByLanguage, catalog: catalog.voices(), systemLanguage: catalog.systemLanguage)
        let text = Sentences.suffix(of: request.text, from: request.startOffset)
        let playback = ApplePlayback(startOffset: request.startOffset)
        if selection.missing {
            playback.notify(AppleSpeech.missingVoiceNotice(for: selection.language))
        }
        playback.start(text: text, voiceIdentifier: selection.voiceIdentifier, rate: AppleSpeech.rate(for: request.speed))
        return playback
    }
}

@MainActor
final class ApplePlayback: NSObject, SpeechPlayback, AVSpeechSynthesizerDelegate {
    let events: AsyncThrowingStream<SpeechEvent, Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private let synthesizer = AVSpeechSynthesizer()
    private let startOffset: Int
    private var cancelled = false

    init(startOffset: Int) {
        self.startOffset = startOffset
        var c: AsyncThrowingStream<SpeechEvent, Error>.Continuation!
        events = AsyncThrowingStream { c = $0 }
        continuation = c
        super.init()
        synthesizer.delegate = self
    }

    func notify(_ text: String) { continuation.yield(.notice(text)) }

    func start(text: String, voiceIdentifier: String?, rate: Float) {
        guard !text.isEmpty else {
            continuation.yield(.finished)
            continuation.finish()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        synthesizer.stopSpeaking(at: .immediate)
        continuation.finish()
    }

    // Delegate callbacks are not guaranteed on the main actor; hop explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.emit(.started) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        let offset = range.location
        Task { @MainActor in self.emit(.progress(characterOffset: self.startOffset + offset)) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.emit(.finished)
            self.continuation.finish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.continuation.finish() }
    }

    private func emit(_ event: SpeechEvent) {
        guard !cancelled else { return }
        continuation.yield(event)
    }
}
