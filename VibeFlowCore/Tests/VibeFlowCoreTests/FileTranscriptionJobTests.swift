import Foundation
import Testing
@testable import VibeFlowCore

// MARK: - Fakes

/// Groq pieces: each call runs the next scripted step (or the default), and is counted.
private final class ScriptedPieces: PieceTranscriber, @unchecked Sendable {
    typealias Step = @Sendable (Int) async throws -> [WhisperSegment]
    private let lock = NSLock()
    private var steps: [Step]
    private let fallback: Step
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ steps: [Step] = [], default fallback: @escaping Step = { n in [WhisperSegment(start: 1, end: 2, text: "Teil \(n).", noSpeechProbability: 0.02)] }) {
        self.steps = steps
        self.fallback = fallback
    }

    func transcribeSegments(_ audio: RecordedAudio, language: String?) async throws -> [WhisperSegment] {
        let (n, step) = lock.withLock { () -> (Int, Step) in
            _calls += 1
            return (_calls, steps.isEmpty ? fallback : steps.removeFirst())
        }
        return try await step(n)
    }
}

private func fail(_ f: TranscriptionFailure) -> ScriptedPieces.Step { { _ in throw f } }

private final class FakeWholeFile: FileTranscriber, @unchecked Sendable {
    let result: Result<[SpeakerSegment], TranscriptionFailure>
    let delay: Duration?
    private let lock = NSLock()
    private var _options: [FileTranscriptionOptions] = []
    var options: [FileTranscriptionOptions] { lock.withLock { _options } }

    init(_ result: Result<[SpeakerSegment], TranscriptionFailure>, delay: Duration? = nil) {
        self.result = result
        self.delay = delay
    }

    func transcribe(file: URL, options: FileTranscriptionOptions) async throws -> [SpeakerSegment] {
        lock.withLock { _options.append(options) }
        if let delay { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

private struct FakeSummarizer: TranscriptSummarizer {
    let result: Result<Transcript.Summary, TranscriptionFailure>
    func summarize(_ transcript: Transcript) async throws -> Transcript.Summary { try result.get() }
}

/// Returns at once and remembers every wait.
private final class InstantClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [Duration] = []
    var waits: [Duration] { lock.withLock { _waits } }
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { _waits.append(duration) }
    }
}

private let loud = 0.046 * 0.046

// MARK: - Harness

@MainActor
private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vf-job-\(UUID().uuidString)")
    let store: TranscriptStore
    let clock = InstantClock()
    var engines: FileTranscriptionJob.Engines
    var info = AudioFileInfo(duration: 1_500, channels: 1, hasVideo: false)
    var envelope = Array(repeating: loud, count: 7_500)   // 25 minutes, no pauses: 3 pieces
    private(set) var wavURLs: [URL] = []
    private(set) var saved: [Transcript] = []
    private(set) var updated: [Transcript] = []
    lazy var job: FileTranscriptionJob = makeJob()

    init(engines: FileTranscriptionJob.Engines) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TranscriptStore(directory: directory.appendingPathComponent("Transcripts"))
        self.engines = engines
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func makeJob() -> FileTranscriptionJob {
        let info = self.info, envelope = self.envelope, directory = self.directory
        let job = FileTranscriptionJob(
            engines: { [unowned self] in self.engines }, store: store, clock: clock,
            now: { Date(timeIntervalSince1970: 1_793_780_000) },
            probe: { _ in info },
            decode: { _ in
                // A tiny WAV stands in for the decoded file; the envelope decides the pieces.
                let url = directory.appendingPathComponent("\(AudioFileDecoder.tempPrefix)\(UUID().uuidString).wav")
                try RecordedAudio(pcm16: Data(repeating: 0, count: 6_400)).wav.write(to: url)
                return DecodedAudio(wavURL: url, sampleCount: envelope.count * AudioFileDecoder.windowSamples, envelope: envelope)
            })
        job.onSaved = { [unowned self] in self.saved.append($0) }
        job.onUpdated = { [unowned self] in self.updated.append($0) }
        return job
    }

    func run(_ kind: FileTranscriptionJob.Kind, summarize: Bool = false, options: FileTranscriptionOptions = .init()) async -> FileTranscriptionJob.State {
        #expect(job.start(.init(file: URL(fileURLWithPath: "/tmp/sales-call.m4a"), kind: kind, options: options, summarize: summarize)))
        await job.waitUntilDone()
        return job.state
    }

    var finished: FileTranscriptionJob.Finished? {
        if case .finished(let f) = job.state { return f }
        return nil
    }

    var leftoverWAVs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".wav") }
    }
}

private let twoSpeakers: [SpeakerSegment] = [
    .init(speaker: "speaker_0", start: 4, end: 5, text: "Hallo Frau Stürmer."),
    .init(speaker: "speaker_1", start: 6, end: 7, text: "Hallo."),
]

// MARK: - Tests

@Suite("FileTranscriptionJob") @MainActor
struct FileTranscriptionJobTests {
    @Test func callsGoToTheCallEngineWithSpeakers() async throws {
        let scribe = FakeWholeFile(.success(twoSpeakers))
        let h = Harness(engines: .init(pieces: ScriptedPieces(), call: scribe, onDevice: nil, summarizer: nil))
        _ = await h.run(.call, options: .init(speakers: 2, language: "de", multichannel: true))
        let f = try #require(h.finished)
        #expect(f.transcript.engine == .scribe)
        #expect(f.transcript.speakers.map(\.name) == ["Speaker 1", "Speaker 2"])
        #expect(f.note == nil)
        #expect(scribe.options == [.init(speakers: 2, language: "de", multichannel: false)], "multichannel only for 2-channel files")
        #expect(try h.store.load(f.transcript.id) == f.transcript)
        #expect(h.saved.map(\.id) == [f.transcript.id])
    }

    @Test func stereoCallsAskForChannels() async throws {
        let scribe = FakeWholeFile(.success(twoSpeakers))
        let h = Harness(engines: .init(pieces: nil, call: scribe, onDevice: nil, summarizer: nil))
        h.info.channels = 2
        _ = await h.run(.call, options: .init(multichannel: true))
        #expect(scribe.options.first?.multichannel == true)
    }

    @Test func aCallWithoutAnElevenLabsKeyStillTranscribesWithoutSpeakers() async throws {
        let h = Harness(engines: .init(pieces: ScriptedPieces(), call: nil, onDevice: nil, summarizer: nil))
        _ = await h.run(.call)
        let f = try #require(h.finished)
        #expect(f.note == "No ElevenLabs key: no speaker labels")
        #expect(f.transcript.engine == .groq)
        #expect(f.transcript.speakers.isEmpty)
    }

    @Test func memoPiecesAreOffsetByWhereEachPieceStarts() async throws {
        let groq = ScriptedPieces()
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: nil, summarizer: nil))
        _ = await h.run(.memo)
        let f = try #require(h.finished)
        #expect(groq.calls == 3)
        #expect(f.transcript.segments.map(\.start) == [1, 601, 1_201])
        #expect(f.transcript.segments.map(\.text) == ["Teil 1.", "Teil 2.", "Teil 3."])
        #expect(f.transcript.completion == .complete)
        #expect(h.leftoverWAVs.isEmpty, "the decoded WAV is deleted")
    }

    @Test func silentPiecesAreSkippedAndInventedPhrasesDropped() async throws {
        let groq = ScriptedPieces([
            { _ in [.init(start: 0, end: 1, text: "Hallo.", noSpeechProbability: 0.02),
                    .init(start: 5, end: 6, text: "Untertitel im Auftrag des ZDF, 2017", noSpeechProbability: 0.5)] },
        ])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: nil, summarizer: nil))
        for i in 3_000..<6_000 { h.envelope[i] = 0 }   // minutes 10 to 20 are silent
        _ = await h.run(.memo)
        let f = try #require(h.finished)
        #expect(groq.calls == 2, "the silent middle piece is never sent")
        #expect(f.transcript.segments.map(\.text) == ["Hallo.", "Teil 2."])
    }

    @Test func groqDownOnTheFirstPieceSendsTheWholeFileOnDevice() async throws {
        let groq = ScriptedPieces([fail(.offline), fail(.offline)])
        let apple = FakeWholeFile(.success([.init(speaker: nil, start: 0, end: 2, text: "Alles auf dem Mac.")]))
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: apple, summarizer: nil))
        _ = await h.run(.memo)
        let f = try #require(h.finished)
        #expect(groq.calls == 2, "retried once before falling back")
        #expect(f.transcript.engine == .apple)
        #expect(f.note == "Transcribed on device: Groq unavailable")
        #expect(f.transcript.segments.map(\.text) == ["Alles auf dem Mac."], "never a mix of two engines")
    }

    @Test func rateLimitWaitsThenContinues() async throws {
        let groq = ScriptedPieces([fail(.rateLimited)])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: nil, summarizer: nil))
        _ = await h.run(.memo)
        #expect(h.clock.waits == [.seconds(30)])
        #expect(h.finished?.transcript.completion == .complete)
    }

    @Test func theHourlyLimitStopsWithThePartialTranscript() async throws {
        let groq = ScriptedPieces([
            { n in [.init(start: 1, end: 2, text: "Teil \(n).", noSpeechProbability: 0)] },
            fail(.rateLimited), fail(.rateLimited), fail(.rateLimited), fail(.rateLimited),
        ])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: ScriptedOnDeviceNeverUsed(), summarizer: nil))
        _ = await h.run(.memo)
        let f = try #require(h.finished)
        #expect(h.clock.waits == [.seconds(30), .seconds(60), .seconds(120)])
        #expect(f.transcript.completion == .stopped(at: 600, reason: "Groq hourly limit"))
        #expect(f.transcript.segments.map(\.text) == ["Teil 1."])
        #expect(try h.store.load(f.transcript.id).completion == f.transcript.completion, "partial status is saved")
    }

    @Test func otherFailuresAfterTheFirstPieceAreRetriedOnceThenStop() async throws {
        let groq = ScriptedPieces([
            { _ in [.init(start: 1, end: 2, text: "Eins.", noSpeechProbability: 0)] },
            fail(.serverError(503)), fail(.serverError(503)),
        ])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: nil, summarizer: nil))
        _ = await h.run(.memo)
        #expect(groq.calls == 3)
        #expect(h.finished?.transcript.completion == .stopped(at: 600, reason: "Service unavailable (HTTP 503)"))
    }

    @Test func aRejectedKeyFailsWithoutSavingAnything() async throws {
        let groq = ScriptedPieces([fail(.unauthorized)])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: FakeWholeFile(.success([])), summarizer: nil))
        let state = await h.run(.memo)
        #expect(state == .failed(file: "sales-call.m4a", message: "Key rejected or missing"))
        #expect(groq.calls == 1, "401 is never retried and never falls back")
        #expect(h.store.storedIDs().isEmpty)
    }

    @Test func theTranscriptIsSavedBeforeTheSummary() async throws {
        let summary = Transcript.Summary(text: "{S1} greets {S9}.", actionItems: [.init(ownerID: "S2", text: "Reply", segmentID: 1)])
        let h = Harness(engines: .init(pieces: nil, call: FakeWholeFile(.success(twoSpeakers)), onDevice: nil,
                                       summarizer: FakeSummarizer(result: .success(summary))))
        _ = await h.run(.call, summarize: true)
        let f = try #require(h.finished)
        #expect(h.saved.count == 1 && h.saved[0].summary == nil, "saved and in History before Claude is asked")
        #expect(f.transcript.summary?.text == "{S1} greets someone.", "validated against the transcript")
        #expect(h.updated.map(\.summary) == [f.transcript.summary])
        #expect(try h.store.load(f.transcript.id).summary == f.transcript.summary)
    }

    @Test func aFailedSummaryKeepsTheTranscript() async throws {
        let h = Harness(engines: .init(pieces: nil, call: FakeWholeFile(.success(twoSpeakers)), onDevice: nil,
                                       summarizer: FakeSummarizer(result: .failure(.offline))))
        _ = await h.run(.call, summarize: true)
        let f = try #require(h.finished)
        #expect(f.summaryError == "Summary failed: Offline")
        #expect(f.transcript.summary == nil)
        #expect(try h.store.load(f.transcript.id).segments.count == 2)
    }

    @Test func noSummaryUnlessAsked() async throws {
        let h = Harness(engines: .init(pieces: nil, call: FakeWholeFile(.success(twoSpeakers)), onDevice: nil,
                                       summarizer: FakeSummarizer(result: .success(.init(text: "x", actionItems: [])))))
        _ = await h.run(.call, summarize: false)
        #expect(h.finished?.transcript.summary == nil)
        #expect(h.updated.isEmpty)
    }

    @Test func oneFileAtATimeAndCancelBeforeAnythingIsSavedGoesBackToIdle() async throws {
        let h = Harness(engines: .init(pieces: nil, call: FakeWholeFile(.success(twoSpeakers), delay: .seconds(30)),
                                       onDevice: nil, summarizer: nil))
        #expect(h.job.start(.init(file: URL(fileURLWithPath: "/tmp/a.m4a"), kind: .call)))
        #expect(!h.job.start(.init(file: URL(fileURLWithPath: "/tmp/b.m4a"), kind: .call)), "already transcribing")
        h.job.cancel()
        await h.job.waitUntilDone()
        #expect(h.job.state == .idle)
        #expect(h.store.storedIDs().isEmpty)
    }

    @Test func cancellingAMemoKeepsTheFinishedPieces() async throws {
        let groq = ScriptedPieces([
            { _ in [.init(start: 1, end: 2, text: "Eins.", noSpeechProbability: 0)] },
            { _ in try await Task.sleep(for: .seconds(30)); return [] },
        ])
        let h = Harness(engines: .init(pieces: groq, call: nil, onDevice: ScriptedOnDeviceNeverUsed(), summarizer: nil))
        #expect(h.job.start(.init(file: URL(fileURLWithPath: "/tmp/memo.m4a"), kind: .memo)))
        for _ in 0..<200 where groq.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        h.job.cancel()
        await h.job.waitUntilDone()
        let f = try #require(h.finished)
        #expect(f.transcript.completion == .cancelled(at: 600))
        #expect(f.transcript.segments.map(\.text) == ["Eins."])
        #expect(h.leftoverWAVs.isEmpty)
    }

    @Test func filesOverTwoHoursAreRefused() async throws {
        let h = Harness(engines: .init(pieces: ScriptedPieces(), call: nil, onDevice: nil, summarizer: nil))
        h.info.duration = 2 * 3600 + 1
        let state = await h.run(.memo)
        #expect(state == .failed(file: "sales-call.m4a", message: "Longer than 2 hours (2:00:01)"))
    }

    @Test func noEngineAtAllSaysWhatToDo() async throws {
        let h = Harness(engines: .init(pieces: nil, call: nil, onDevice: nil, summarizer: nil))
        let state = await h.run(.memo)
        #expect(state == .failed(file: "sales-call.m4a", message: "Add a Groq key in Settings > Accounts, or install the on-device model"))
    }

    @Test func progressReportsAudioDoneWhenEachPieceStarts() async throws {
        // Each Groq call records the phase the menu shows at that moment.
        let seen = PhaseLog()
        let h = Harness(engines: .init(pieces: nil, call: nil, onDevice: nil, summarizer: nil))
        let groq = ScriptedPieces(default: { [weak h] n in
            if let phase = await MainActor.run(body: { () -> FileTranscriptionJob.Phase? in
                if case .running(_, let phase, _, _) = h?.job.state { return phase }
                return nil
            }) { seen.append(phase) }
            return [.init(start: 1, end: 2, text: "Teil \(n).", noSpeechProbability: 0)]
        })
        h.engines.pieces = groq
        _ = await h.run(.memo)
        #expect(seen.phases == [.preparing, .transcribingPieces(done: 600, total: 1_500), .transcribingPieces(done: 1_200, total: 1_500)])
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [FileTranscriptionJob.Phase] = []
    var phases: [FileTranscriptionJob.Phase] { lock.withLock { _phases } }
    func append(_ phase: FileTranscriptionJob.Phase) { lock.withLock { _phases.append(phase) } }
}

/// An on-device engine that fails the test if the job ever uses it.
private struct ScriptedOnDeviceNeverUsed: FileTranscriber {
    func transcribe(file: URL, options: FileTranscriptionOptions) async throws -> [SpeakerSegment] {
        Issue.record("on-device must not be used after Groq has transcribed a piece")
        return []
    }
}

// MARK: - Review fixes (pre-landing review, 2026-11-04)

/// Renames speaker S1 in the stored transcript while "Claude" is busy, like the window would.
private struct RenamingSummarizer: TranscriptSummarizer {
    let store: TranscriptStore
    func summarize(_ transcript: Transcript) async throws -> Transcript.Summary {
        var stored = try store.load(transcript.id)
        stored.rename("S1", to: "Florian")
        try store.save(stored)
        return .init(text: "{S1} greets {S2}.", actionItems: [])
    }
}

@Suite("FileTranscriptionJob review fixes") @MainActor
struct FileTranscriptionJobReviewFixTests {
    @Test func aRenameMadeWhileSummarizingIsKept() async throws {
        let h = Harness(engines: .init(pieces: nil, call: FakeWholeFile(.success(twoSpeakers)), onDevice: nil, summarizer: nil))
        h.engines.summarizer = RenamingSummarizer(store: h.store)
        _ = await h.run(.call, summarize: true)
        let saved = try h.store.load(try #require(h.finished).transcript.id)
        #expect(saved.name(of: "S1") == "Florian", "the summary must not overwrite the rename")
        #expect(saved.summary?.text == "{S1} greets {S2}.")
    }
}

@Suite("Temporary file sweep")
struct TemporaryFileSweepTests {
    @Test func removesOnlyVibeFlowLeftovers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["vibeflow-file-a.wav", "vibeflow-file-b.m4a", "vibeflow-file-c.body", "someone-else.wav", "vibeflow-1.wav"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        #expect(AudioFileDecoder.removeLeftovers(in: dir) == 3)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["someone-else.wav", "vibeflow-1.wav"],
                "dictation's own temp files and other apps' files are left alone")
    }
}
