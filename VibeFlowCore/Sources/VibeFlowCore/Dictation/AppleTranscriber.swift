import AVFoundation
import Foundation
import Speech

/// Readiness of Apple's on-device language model for one language (design D9).
public enum OnDeviceModelState: Sendable, Equatable {
    case unavailableOnThisMac   // macOS 15 (D8)
    case unsupportedLanguage
    case notInstalled
    case downloading
    case ready
    case failed(String)
}

/// Apple on-device dictation via SpeechAnalyzer + SpeechTranscriber (macOS 26, D8). DictationTranscriber was probed on 2026-10-03 and only emitted volatile, never final, results for a file, and rendered "four thousand francs" as "Fr.4000"; SpeechTranscriber with the transcription preset returns final segments with correct text.
/// Transcribes a finished recording from a temporary file; never touches the network.
/// Also the offline engine for whole files (file transcription D5): one pass, no speakers.
public final class AppleTranscriber: Transcriber, FileTranscriber {
    public init() {}

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func transcribe(_ audio: RecordedAudio, language: String?) async throws -> Transcription {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionFailure.unavailable("On-device dictation needs macOS 26")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibeflow-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.wav.write(to: url)
        } catch {
            throw TranscriptionFailure.unavailable(error.localizedDescription)
        }
        let segments = try await Self.analyze(wavAt: url, language: language)
        let text = segments.map(\.text).joined()
        return Transcription(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A whole audio or video file: decoded to 16 kHz mono first (AVAudioFile reads no video),
    /// then one pass in the system language unless `options.language` says otherwise (design Q3).
    public func transcribe(file: URL, options: FileTranscriptionOptions) async throws -> [SpeakerSegment] {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionFailure.unavailable("On-device transcription needs macOS 26")
        }
        let decoded = try await AudioFileDecoder.decode(file)
        defer { decoded.remove() }
        return try await Self.analyze(wavAt: decoded.wavURL, language: options.language).map {
            SpeakerSegment(speaker: nil, start: $0.start, end: $0.end,
                           text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.text.isEmpty }
    }

    /// Final results of SpeechTranscriber for a WAV, in order, with their time ranges. Text is
    /// returned as the analyzer gives it (dictation joins it with no separator, as before).
    @available(macOS 26.0, *)
    static func analyze(wavAt url: URL, language: String?) async throws -> [SpeakerSegment] {
        let wanted = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriptionFailure.unavailable("No on-device model for \(wanted.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionFailure.assetsMissing(language: locale.identifier)
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            async let collected: [SpeakerSegment] = {
                var segments: [SpeakerSegment] = []
                for try await result in transcriber.results where result.isFinal {
                    let range = result.range
                    segments.append(SpeakerSegment(speaker: nil, start: range.start.seconds,
                                                   end: range.end.seconds, text: String(result.text.characters)))
                }
                return segments
            }()
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collected
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.unavailable(error.localizedDescription)
        }
    }
}

/// Checks and prepares the on-device model in the background (D9).
public enum OnDeviceModel {
    public static func state(for language: String?) async -> OnDeviceModelState {
        guard #available(macOS 26.0, *) else { return .unavailableOnThisMac }
        let wanted = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return .unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .downloading: return .downloading
        case .supported: return .notInstalled
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .notInstalled
        }
    }

    /// Downloads and installs the model if missing. Returns the resulting state.
    public static func prepare(for language: String?) async -> OnDeviceModelState {
        guard #available(macOS 26.0, *) else { return .unavailableOnThisMac }
        let wanted = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return .unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            return await state(for: language)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
