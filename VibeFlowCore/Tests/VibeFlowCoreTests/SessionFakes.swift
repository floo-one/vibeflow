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
    let session: ReadSession

    init(configure: (SessionHarness) -> Void = { _ in }) {
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
            clock: clock
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
