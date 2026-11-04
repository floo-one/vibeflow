import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "file-transcription")

/// Transcribes one file at a time beside dictation (file transcription D2): picks the engine
/// (D3), runs Groq pieces or a whole-file engine, handles failures (D6), saves the transcript,
/// then asks for the optional summary (D7). Engines, store, clock and decoder are injected.
@MainActor @Observable
public final class FileTranscriptionJob {
    public enum Kind: String, Sendable, Codable { case call, memo }

    public struct Request: Sendable, Equatable {
        public var file: URL
        public var kind: Kind
        public var options: FileTranscriptionOptions
        public var summarize: Bool

        public init(file: URL, kind: Kind, options: FileTranscriptionOptions = .init(), summarize: Bool = false) {
            self.file = file
            self.kind = kind
            self.options = options
            self.summarize = summarize
        }
    }

    public enum Phase: Sendable, Equatable {
        case preparing
        /// Call engine: one request, no progress to report, so the menu shows elapsed time.
        case transcribingWhole
        /// Groq pieces: seconds of audio done out of the total (outside voice 8).
        case transcribingPieces(done: Double, total: Double)
        case waitingForRateLimit(seconds: Int)
        case summarizing
    }

    public struct Finished: Sendable, Equatable {
        public var transcript: Transcript
        /// "Transcribed on device: Groq unavailable", "No ElevenLabs key: no speaker labels".
        public var note: String?
        public var summaryError: String?
    }

    public enum State: Sendable, Equatable {
        case idle
        case running(file: String, phase: Phase, startedAt: Date, note: String?)
        case finished(Finished)
        case failed(file: String, message: String)
    }

    public struct Engines: Sendable {
        /// Groq for memos; nil without a Groq key.
        public var pieces: (any PieceTranscriber)?
        /// The call engine (ElevenLabs Scribe); nil without an ElevenLabs key.
        public var call: (any FileTranscriber)?
        /// Apple on-device; nil when unavailable or the system locale's model is missing.
        public var onDevice: (any FileTranscriber)?
        public var summarizer: (any TranscriptSummarizer)?

        public init(pieces: (any PieceTranscriber)?, call: (any FileTranscriber)?,
                    onDevice: (any FileTranscriber)?, summarizer: (any TranscriptSummarizer)?) {
            self.pieces = pieces
            self.call = call
            self.onDevice = onDevice
            self.summarizer = summarizer
        }
    }

    /// Waits after a 429 before retrying the same piece (eng review R1).
    public static let rateLimitBackoff: [Duration] = [.seconds(30), .seconds(60), .seconds(120)]

    public private(set) var state: State = .idle
    /// Called after a transcript is saved (complete or partial), before any summary: History
    /// adds its entry here so a crash during the summary loses nothing (outside voice 4).
    public var onSaved: (@MainActor (Transcript) -> Void)?
    /// Called again after the summary is saved.
    public var onUpdated: (@MainActor (Transcript) -> Void)?

    private let engines: @MainActor () -> Engines
    private let store: TranscriptStore
    private let clock: any SessionClock
    private let now: @Sendable () -> Date
    private let probe: @Sendable (URL) async throws -> AudioFileInfo
    private let decode: @Sendable (URL) async throws -> DecodedAudio
    private var task: Task<Void, Never>?

    public init(engines: @escaping @MainActor () -> Engines, store: TranscriptStore = TranscriptStore(),
                clock: any SessionClock = ContinuousSessionClock(), now: @escaping @Sendable () -> Date = { Date() },
                probe: @escaping @Sendable (URL) async throws -> AudioFileInfo = { try await AudioFileDecoder.probe($0) },
                decode: @escaping @Sendable (URL) async throws -> DecodedAudio = { try await AudioFileDecoder.decode($0) }) {
        self.engines = engines
        self.store = store
        self.clock = clock
        self.now = now
        self.probe = probe
        self.decode = decode
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Starts a job. Returns false while another file is running ("Already transcribing ...").
    @discardableResult
    public func start(_ request: Request) -> Bool {
        guard !isRunning else { return false }
        state = .running(file: request.file.lastPathComponent, phase: .preparing, startedAt: now(), note: nil)
        task = Task { await self.run(request) }
        return true
    }

    /// Stops the running job. Groq memos keep what is done ("Cancelled at"); a whole-file engine
    /// keeps nothing; a cancelled summary keeps the saved transcript.
    public func cancel() {
        task?.cancel()
    }

    /// For tests and the app's quit path: waits for the current job to end.
    public func waitUntilDone() async {
        await task?.value
    }

    /// Back to idle after the result has been shown.
    public func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: Run

    private func run(_ request: Request) async {
        let name = request.file.lastPathComponent
        let engines = engines()
        do {
            let info = try await probe(request.file)
            guard info.duration <= AudioFileDecoder.maxDuration else { throw AudioFileError.tooLong(seconds: info.duration) }
            let options = FileTranscriptionOptions(
                speakers: request.options.speakers, language: request.options.language,
                multichannel: request.options.multichannel && info.channels >= 2)

            var outcome: Outcome
            if request.kind == .call, let call = engines.call {
                setPhase(.transcribingWhole)
                let segments = try await call.transcribe(file: request.file, options: options)
                outcome = Outcome(segments: segments, engine: .scribe, completion: .complete, note: nil)
            } else {
                let note = request.kind == .call ? "No ElevenLabs key: no speaker labels" : nil
                outcome = try await memo(request, info: info, engines: engines, note: note)
            }

            var transcript = Transcript.make(
                from: outcome.segments, date: now(), sourceFileName: name, sourceBookmark: Transcript.bookmark(for: request.file),
                duration: info.duration, engine: outcome.engine, language: request.options.language, completion: outcome.completion)
            try store.save(transcript)
            onSaved?(transcript)
            log.notice("File transcribed: \(transcript.segments.count, privacy: .public) segments, \(String(describing: outcome.completion), privacy: .public)")

            var summaryError: String?
            if request.summarize, let summarizer = engines.summarizer, !transcript.segments.isEmpty, !Task.isCancelled {
                setPhase(.summarizing)
                do {
                    let summary = try await summarizer.summarize(transcript)
                    transcript.summary = transcript.validated(summary)
                    try store.save(transcript)
                    onUpdated?(transcript)
                } catch {
                    summaryError = error is CancellationError || Task.isCancelled
                        ? "Summary cancelled" : "Summary failed: \(Self.describe(error))"
                }
            }
            state = .finished(Finished(transcript: transcript, note: outcome.note, summaryError: summaryError))
        } catch {
            if error is CancellationError || Task.isCancelled {
                log.notice("File transcription cancelled before anything was saved")
                state = .idle
                return
            }
            log.notice("File transcription failed: \(Self.describe(error), privacy: .public)")
            state = .failed(file: name, message: Self.describe(error))
        }
    }

    private struct Outcome {
        var segments: [SpeakerSegment]
        var engine: Transcript.Engine
        var completion: Transcript.Completion
        var note: String?
    }

    // MARK: Memo engine

    private func memo(_ request: Request, info: AudioFileInfo, engines: Engines, note: String?) async throws -> Outcome {
        let language = request.options.language
        guard let groq = engines.pieces else {
            guard let onDevice = engines.onDevice else {
                throw TranscriptionFailure.unavailable("Add a Groq key in Settings > Accounts, or install the on-device model")
            }
            return try await whole(onDevice, request, note: note)
        }

        let decoded = try await decode(request.file)
        defer { decoded.remove() }
        let pieces = AudioFileDecoder.pieces(envelope: decoded.envelope)
        let total = decoded.duration
        var segments: [SpeakerSegment] = []
        var sentAny = false

        for piece in pieces {
            let pieceEnd = Double(piece.windows.upperBound) * AudioFileDecoder.windowSeconds
            if piece.isSilent {
                setPhase(.transcribingPieces(done: min(pieceEnd, total), total: total))
                continue
            }
            if Task.isCancelled {
                return Outcome(segments: segments, engine: .groq, completion: .cancelled(at: piece.start), note: note)
            }
            let audio = try await Self.read(decoded, piece)
            do {
                let result = try await transcribePiece(groq, audio, language: language)
                segments += NoSpeech.keptSegments(result).map {
                    SpeakerSegment(speaker: nil, start: piece.start + $0.start, end: piece.start + $0.end, text: $0.text)
                }
                sentAny = true
                setPhase(.transcribingPieces(done: min(pieceEnd, total), total: total))
            } catch {
                // A cancelled upload surfaces as URLError.cancelled, which the engines report as
                // "offline": check cancellation first so Stop never looks like Groq being down.
                if error is CancellationError || Task.isCancelled {
                    if segments.isEmpty { throw CancellationError() }
                    return Outcome(segments: segments, engine: .groq, completion: .cancelled(at: piece.start), note: note)
                }
                guard let failure = error as? TranscriptionFailure else { throw error }
                // First request failing because Groq is down: the whole file goes on device (D6).
                if !sentAny, let onDevice = engines.onDevice, FallbackTranscriber.fallbackReason(for: failure) != nil, failure != .rateLimited {
                    return try await whole(onDevice, request, note: "Transcribed on device: Groq unavailable")
                }
                if segments.isEmpty { throw failure }
                return Outcome(segments: segments, engine: .groq,
                               completion: .stopped(at: piece.start, reason: Self.stopReason(failure)), note: note)
            }
        }
        return Outcome(segments: segments, engine: .groq, completion: .complete, note: note)
    }

    /// One piece with the retry rules: 429 waits 30, 60, 120 s (R1); any other failure after the
    /// first piece is retried once; 401 never retries.
    private func transcribePiece(_ groq: any PieceTranscriber, _ audio: RecordedAudio, language: String?) async throws -> [WhisperSegment] {
        var backoff = Self.rateLimitBackoff[...]
        var retriedOnce = false
        while true {
            do {
                return try await groq.transcribeSegments(audio, language: language)
            } catch TranscriptionFailure.rateLimited {
                guard let wait = backoff.popFirst() else { throw TranscriptionFailure.rateLimited }
                setPhase(.waitingForRateLimit(seconds: Int(wait.components.seconds)))
                try await clock.sleep(for: wait)
            } catch let failure as TranscriptionFailure where failure != .unauthorized && !retriedOnce {
                retriedOnce = true
            }
        }
    }

    private func whole(_ engine: any FileTranscriber, _ request: Request, note: String?) async throws -> Outcome {
        setPhase(.transcribingWhole, note: note)
        let segments = try await engine.transcribe(
            file: request.file, options: FileTranscriptionOptions(language: request.options.language))
        return Outcome(segments: segments, engine: .apple, completion: .complete, note: note)
    }

    nonisolated private static func read(_ decoded: DecodedAudio, _ piece: AudioPiece) async throws -> RecordedAudio {
        try decoded.audio(windows: piece.windows)
    }

    // MARK: State and text

    private func setPhase(_ phase: Phase, note: String? = nil) {
        guard case .running(let file, _, let startedAt, let oldNote) = state else { return }
        state = .running(file: file, phase: phase, startedAt: startedAt, note: note ?? oldNote)
    }

    nonisolated static func stopReason(_ failure: TranscriptionFailure) -> String {
        switch failure {
        case .rateLimited: "Groq hourly limit"
        case .unauthorized: "Groq key rejected"
        default: describe(failure)
        }
    }

    /// The status text for any failure the job can meet.
    nonisolated public static func describe(_ error: Error) -> String {
        switch error {
        case let failure as TranscriptionFailure:
            switch failure {
            case .unauthorized: return "Key rejected or missing"
            case .rejected(let status, let message, _): return status == 401 || status == 403 ? message : "Error \(status): \(message)"
            case .rateLimited: return "Rate limited"
            case .serverError(let code): return "Service unavailable (HTTP \(code))"
            case .offline: return "Offline"
            case .timeout: return "Timed out"
            case .malformed: return "Unreadable response"
            case .assetsMissing(let language): return "Download the on-device model for \(language) in Settings > Dictation"
            case .unavailable(let reason): return reason
            }
        case let claude as SmartReadFailure:
            switch claude {
            case .unauthorized: return "Anthropic key rejected or missing"
            case .rateLimited: return "Claude is rate limited"
            case .overloaded: return "Claude is overloaded"
            case .offline: return "Offline"
            case .timeout: return "Timed out"
            case .other(let reason): return reason.prefix(1).uppercased() + reason.dropFirst()
            }
        case let file as AudioFileError:
            switch file {
            case .noAudio: return "No audio in this file"
            case .unreadable(let name): return "Couldn't read \(name)"
            case .tooLong(let seconds): return "Longer than 2 hours (\(Transcript.clock(seconds)))"
            }
        default:
            return error.localizedDescription
        }
    }
}
