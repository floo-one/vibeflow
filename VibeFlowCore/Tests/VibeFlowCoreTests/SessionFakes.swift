import Foundation
@testable import VibeFlowCore

@MainActor
final class FakeCapture: SelectionCapturing {
    var result = CaptureResult(text: "Hello there. This is a test. Goodbye.")
    /// When set, capture suspends on this clock first (to test presses during capturing).
    var delay: Duration = .zero
    var clock: FakeClock?
    private(set) var calls: [FrontmostApp?] = []

    func capture(from app: FrontmostApp?) async -> CaptureResult {
        calls.append(app)
        if delay > .zero, let clock { try? await clock.sleep(for: delay) }
        return result
    }
}

/// A live voice stream that records what it is fed.
@MainActor
final class FakeStreamingSpeech: StreamingSpeech {
    let events: AsyncThrowingStream<SpeechEvent, Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private(set) var pieces: [String] = []
    private(set) var finishedText = false
    private(set) var cancelCount = 0

    init() {
        var c: AsyncThrowingStream<SpeechEvent, Error>.Continuation!
        events = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func append(_ text: String) { pieces.append(text) }
    func finishText() { finishedText = true }
    func emit(_ event: SpeechEvent) { continuation.yield(event) }
    func fail(_ failure: SpeechFailure) { continuation.finish(throwing: failure) }
    func finish() { continuation.yield(.finished); continuation.finish() }
    func cancel() { cancelCount += 1; continuation.finish() }
}

@MainActor
final class FakeStreamingVoice: StreamingSpeechProvider {
    private(set) var requests: [SpeechRequest] = []
    private(set) var streams: [FakeStreamingSpeech] = []
    var last: FakeStreamingSpeech? { streams.last }

    func beginStream(_ request: SpeechRequest) -> any StreamingSpeech {
        requests.append(request)
        let s = FakeStreamingSpeech()
        streams.append(s)
        return s
    }
}

@MainActor
final class FakePresets: PresetResolving {
    var byBundle: [String: AppPreset] = [:]
    var defaultPreset = AppPreset.default
    private(set) var lookups: [String?] = []

    func preset(for bundleID: String?) -> AppPreset {
        lookups.append(bundleID)
        if let id = bundleID, let p = byBundle[id] { return p }
        return defaultPreset
    }
}

/// Everything a ReadSession test needs, wired to fakes, with sensible defaults:
/// trusted, Safari frontmost, both keys present, default preset, short text.
@MainActor
struct SessionHarness {
    let accessibility = FakeAccessibility()
    let capture = FakeCapture()
    let presets = FakePresets()
    let elevenLabs = FakeSpeechProvider()
    let apple = FakeSpeechProvider()
    let smartRead = FakeSmartReadClient()
    let secrets = FakeSecrets([.elevenLabs: "el", .anthropic: "an"])
    let clock = FakeClock()
    let answerVoice = FakeStreamingVoice()
    let session: ReadSession

    init(streamingAnswers: Bool = false, configuration: SessionConfiguration = SessionConfiguration(), configure: (SessionHarness) -> Void = { _ in }) {
        capture.clock = clock
        smartRead.clock = clock
        session = ReadSession(
            accessibility: accessibility,
            capture: capture,
            presets: presets,
            elevenLabs: elevenLabs,
            apple: apple,
            smartRead: smartRead,
            secrets: secrets,
            clock: clock,
            configuration: configuration,
            answerVoice: streamingAnswers ? answerVoice : nil
        )
        configure(self)
    }

    /// Lets queued main-actor tasks run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
        for _ in 0..<20 { await Task.yield() }
    }
}
