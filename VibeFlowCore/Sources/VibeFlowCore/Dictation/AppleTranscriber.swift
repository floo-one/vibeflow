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
public final class AppleTranscriber: Transcriber {
    public init() {}

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func transcribe(_ audio: RecordedAudio, language: String?) async throws -> Transcription {
        guard #available(macOS 26.0, *) else {
            throw TranscriptionFailure.unavailable("On-device dictation needs macOS 26")
        }
        return try await Self.transcribe26(audio, language: language)
    }

    @available(macOS 26.0, *)
    private static func transcribe26(_ audio: RecordedAudio, language: String?) async throws -> Transcription {
        let wanted = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriptionFailure.unavailable("No on-device model for \(wanted.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionFailure.assetsMissing(language: locale.identifier)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibeflow-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.wav.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            async let collected: String = {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
                return text
            }()
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await collected
            return Transcription(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
