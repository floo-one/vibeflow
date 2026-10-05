import Foundation
import Testing
@testable import VibeFlowCore

final class FakeModelStore: OnDeviceModelStore, @unchecked Sendable {
    private let lock = NSLock()
    var current: OnDeviceModelState = .notInstalled
    var prepareResult: OnDeviceModelState = .ready
    private var _prepares = 0
    var prepares: Int { lock.withLock { _prepares } }

    func state(for language: String?) async -> OnDeviceModelState { lock.withLock { current } }
    func prepare(for language: String?) async -> OnDeviceModelState {
        lock.withLock { _prepares += 1; current = prepareResult }
        return prepareResult
    }
}

@Suite("On-device model readiness (D9)") @MainActor
struct OnDeviceModelStatusTests {
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func missingModelIsDownloadedInTheBackground() async {
        let store = FakeModelStore()
        let status = OnDeviceModelStatus(store: store)
        status.prepare(language: "de-DE")
        await settle()
        #expect(store.prepares == 1)
        #expect(status.state == .ready)
        #expect(status.summary == "Ready")
    }

    @Test func installedModelIsNotDownloadedAgain() async {
        let store = FakeModelStore()
        store.current = .ready
        let status = OnDeviceModelStatus(store: store)
        status.prepare(language: nil)
        await settle()
        #expect(store.prepares == 0)
        #expect(status.isReady)
    }

    @Test func failedDownloadOffersRetry() async {
        let store = FakeModelStore()
        store.prepareResult = .failed("no network")
        let status = OnDeviceModelStatus(store: store)
        status.prepare(language: nil)
        await settle()
        #expect(status.summary == "Download failed: no network")

        store.prepareResult = .ready
        store.current = .notInstalled
        status.retry()
        await settle()
        #expect(store.prepares == 2)
        #expect(status.isReady)
    }

    @Test func macOS15AndUnsupportedLanguagesNeverDownload() async {
        for unavailable in [OnDeviceModelState.unavailableOnThisMac, .unsupportedLanguage] {
            let store = FakeModelStore()
            store.current = unavailable
            let status = OnDeviceModelStatus(store: store)
            status.prepare(language: "xx")
            await settle()
            #expect(store.prepares == 0)
            #expect(status.state == unavailable)
        }
    }
}

@Suite("Dictation setup") @MainActor
struct DictationSetupFactoryTests {
    let http = FakeHTTPClient()
    let apple = FakeTranscriber()
    let speech = RecordedAudio(pcm16: Data(repeating: 0x40, count: 32_000))

    init() {
        apple.result = .success(Transcription(text: "on device"))
        http.body = Data(#"{"text":"from groq","segments":[{"no_speech_prob":0.01}]}"#.utf8)
    }

    @Test func groqWithAKeyCleansUpAndFallsBackToAppleOnDevice() async throws {
        let setup = DictationSetupFactory.make(vocabulary: ["Anna"], secrets: FakeSecrets([.groq: "gsk"]), http: http, onDevice: apple, microphoneUID: "mic")
        #expect(setup.transcriber.primaryName == "Groq")
        #expect(setup.transcriber.fallback != nil)
        #expect(setup.cleaner is ChatCompletionsCleaner)
        #expect(setup.notice == nil)
        #expect(setup.vocabulary == ["Anna"])
        #expect(setup.microphoneUID == "mic")
        let out = try await setup.transcriber.transcribe(speech, language: nil)
        #expect(out.transcription.text == "from groq")
        #expect(http.requests.first?.url?.host == "api.groq.com")
    }

    @Test func groqWithoutAKeyUsesAppleWithANoticeAndNoCleanup() async throws {
        let setup = DictationSetupFactory.make(vocabulary: [], secrets: FakeSecrets(), http: http, onDevice: apple, microphoneUID: nil)
        #expect(setup.notice == "Transcribed on device: no Groq key")
        #expect(setup.cleaner == nil)
        let out = try await setup.transcriber.transcribe(speech, language: nil)
        #expect(out.transcription.text == "on device")
        #expect(http.requests.isEmpty)
    }

    @Test func groqWithoutAKeyOnMacOS15SurfacesTheMissingKey() async {
        let setup = DictationSetupFactory.make(vocabulary: [], secrets: FakeSecrets(), http: http, onDevice: nil, microphoneUID: nil)
        await #expect(throws: TranscriptionFailure.unauthorized) { try await setup.transcriber.transcribe(speech, language: nil) }
    }
}
