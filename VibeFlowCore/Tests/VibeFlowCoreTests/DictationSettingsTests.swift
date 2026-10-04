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

@Suite("Dictation setup from settings") @MainActor
struct DictationSetupFactoryTests {
    let http = FakeHTTPClient()
    let apple = FakeTranscriber()
    let speech = RecordedAudio(pcm16: Data(repeating: 0x40, count: 32_000))

    init() {
        apple.result = .success(Transcription(text: "on device"))
        http.body = Data(#"{"text":"from groq","segments":[{"no_speech_prob":0.01}]}"#.utf8)
    }

    @Test func groqWithAKeyFallsBackToAppleOnDevice() async throws {
        let setup = DictationSetupFactory.make(settings: DictationSettings(), secrets: FakeSecrets([.groq: "gsk"]), http: http, onDevice: apple, microphoneUID: "mic")
        #expect(setup.transcriber.primaryName == "Groq")
        #expect(setup.transcriber.fallback != nil)
        #expect(setup.notice == nil)
        #expect(setup.microphoneUID == "mic")
        let out = try await setup.transcriber.transcribe(speech, language: nil)
        #expect(out.transcription.text == "from groq")
        #expect(http.requests.first?.url?.host == "api.groq.com")
    }

    @Test func groqWithoutAKeyUsesAppleWithANotice() async throws {
        let setup = DictationSetupFactory.make(settings: DictationSettings(), secrets: FakeSecrets(), http: http, onDevice: apple, microphoneUID: nil)
        #expect(setup.notice == "Transcribed on device: no Groq key")
        let out = try await setup.transcriber.transcribe(speech, language: nil)
        #expect(out.transcription.text == "on device")
        #expect(http.requests.isEmpty)
    }

    @Test func groqWithoutAKeyOnMacOS15SurfacesTheMissingKey() async {
        let setup = DictationSetupFactory.make(settings: DictationSettings(), secrets: FakeSecrets(), http: http, onDevice: nil, microphoneUID: nil)
        await #expect(throws: TranscriptionFailure.unauthorized) { try await setup.transcriber.transcribe(speech, language: nil) }
    }

    @Test func customEndpointRunsWithoutAKeyAndFallsBack() async throws {
        let settings = DictationSettings(transcriber: .custom, customEndpoint: "http://localhost:8000/v1")
        let setup = DictationSetupFactory.make(settings: settings, secrets: FakeSecrets(), http: http, onDevice: apple, microphoneUID: nil)
        #expect(setup.transcriber.primaryName == "Custom endpoint")
        #expect(setup.transcriber.fallback != nil)
        _ = try await setup.transcriber.transcribe(speech, language: nil)
        #expect(http.requests.first?.url?.absoluteString == "http://localhost:8000/v1/audio/transcriptions")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func customEndpointWithoutAURLSaysWhatToSet() async {
        let setup = DictationSetupFactory.make(settings: DictationSettings(transcriber: .custom, customEndpoint: "localhost"), secrets: FakeSecrets(), http: http, onDevice: apple, microphoneUID: nil)
        await #expect(throws: TranscriptionFailure.unavailable("Set the custom endpoint URL in Settings > Dictation")) {
            try await setup.transcriber.transcribe(speech, language: nil)
        }
    }

    @Test func appleChoiceOnMacOS15SaysWhy() async {
        let setup = DictationSetupFactory.make(settings: DictationSettings(transcriber: .apple), secrets: FakeSecrets([.groq: "gsk"]), http: http, onDevice: nil, microphoneUID: nil)
        await #expect(throws: TranscriptionFailure.unavailable("On-device dictation needs macOS 26")) {
            try await setup.transcriber.transcribe(speech, language: nil)
        }
    }

    @Test func cleanupFollowsTheSettings() {
        let secrets = FakeSecrets([.groq: "gsk"])
        let off = DictationSetupFactory.make(settings: DictationSettings(cleanupEnabled: false), secrets: secrets, http: http, onDevice: apple, microphoneUID: nil)
        #expect(off.cleaner == nil)
        let groq = DictationSetupFactory.make(settings: DictationSettings(), secrets: secrets, http: http, onDevice: apple, microphoneUID: nil)
        #expect(groq.cleaner is ChatCompletionsCleaner)
        let claude = DictationSetupFactory.make(settings: DictationSettings(cleanupProvider: .anthropic), secrets: secrets, http: http, onDevice: apple, microphoneUID: nil)
        #expect(claude.cleaner is AnthropicCleaner)
    }

    @Test func vocabularyAcceptsLinesAndCommas() {
        #expect(DictationSettings.parseVocabulary("VibeFlow, Groq\n  Kokoro \n\n,ElevenLabs") == ["VibeFlow", "Groq", "Kokoro", "ElevenLabs"])
    }

    @Test func preferencesPersistTheDictationSettings() {
        let defaults = scratchDefaults()
        let a = Preferences(defaults: defaults)
        #expect(a.dictationSettings == DictationSettings())
        #expect(a.microphoneUID == nil)
        a.transcriber = .custom
        a.customEndpoint = "http://localhost:8000/v1"
        a.cleanupEnabled = false
        a.vocabulary = "Anna, VibeFlow"
        a.microphoneUID = "usb-mic"
        let b = Preferences(defaults: defaults)
        #expect(b.dictationSettings == DictationSettings(transcriber: .custom, customEndpoint: "http://localhost:8000/v1", cleanupEnabled: false, vocabulary: ["Anna", "VibeFlow"]))
        #expect(b.microphoneUID == "usb-mic")
    }
}
