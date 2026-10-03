import Foundation
import Testing
@testable import VibeFlowCore

private let speech = RecordedAudio(pcm16: {
    var d = Data()
    for i in 0..<16_000 { withUnsafeBytes(of: Int16(i % 2 == 0 ? 1_500 : -1_500).littleEndian) { d.append(contentsOf: $0) } }
    return d
}()) // RMS about 0.046, like T1's real speech
private let silent = RecordedAudio(pcm16: Data(repeating: 0, count: 32_000))

@Suite("OpenAITranscriber")
struct OpenAITranscriberTests {
    let http = FakeHTTPClient()

    func transcriber(key: String? = "gsk-test", keyRequired: Bool = true, base: URL = OpenAITranscriber.groqBaseURL) -> OpenAITranscriber {
        OpenAITranscriber(http: http, baseURL: base, keyRequired: keyRequired, apiKey: { key })
    }

    static func ok(_ text: String, probs: [Double] = [0.02]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["text": text, "segments": probs.map { ["text": "x", "no_speech_prob": $0] }])
    }

    @Test func postsMultipartVerboseJSONWithLargeV3AndLanguage() async throws {
        http.body = Self.ok(" Hello there. ", probs: [0.03])
        let result = try await transcriber().transcribe(speech, language: "de-DE")
        #expect(result == Transcription(text: "Hello there.", noSpeechProbabilities: [0.03]))
        let req = http.requests[0]
        #expect(req.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(body.contains("name=\"language\"\r\n\r\nde\r\n"))
        #expect(!body.contains("service_tier"), "Groq rejects service_tier (T1)")
        #expect(body.contains("filename=\"dictation.wav\""))
    }

    @Test func statusesMapToTheFallbackClasses() async {
        let cases: [(Int, TranscriptionFailure)] = [
            (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .serverError(500)), (503, .serverError(503)),
        ]
        for (status, expected) in cases {
            http.status = status
            await #expect(throws: expected) { try await transcriber().transcribe(speech, language: nil) }
        }
    }

    @Test func otherClientErrorsCarryTheProviderMessage() async {
        http.status = 413
        http.body = Data(#"{"error":{"message":"file too large"}}"#.utf8)
        await #expect(throws: TranscriptionFailure.rejected(status: 413, message: "file too large")) {
            try await transcriber().transcribe(speech, language: nil)
        }
    }

    @Test func networkErrorsAreOfflineOrTimeout() async {
        http.connectError = URLError(.notConnectedToInternet)
        await #expect(throws: TranscriptionFailure.offline) { try await transcriber().transcribe(speech, language: nil) }
        http.connectError = URLError(.timedOut)
        await #expect(throws: TranscriptionFailure.timeout) { try await transcriber().transcribe(speech, language: nil) }
    }

    @Test func malformedOKIsMalformed() async {
        http.body = Data("nope".utf8)
        await #expect(throws: TranscriptionFailure.malformed) { try await transcriber().transcribe(speech, language: nil) }
    }

    @Test func groqWithoutAKeyFailsBeforeAnyRequest() async {
        await #expect(throws: TranscriptionFailure.unauthorized) { try await transcriber(key: nil).transcribe(speech, language: nil) }
        #expect(http.requests.isEmpty)
    }

    @Test func customEndpointMayRunWithoutAKey() async throws {
        http.body = Self.ok("local")
        let t = transcriber(key: nil, keyRequired: false, base: URL(string: "http://localhost:8000/v1")!)
        let result = try await t.transcribe(speech, language: nil)
        #expect(result.text == "local")
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(http.requests[0].url?.absoluteString == "http://localhost:8000/v1/audio/transcriptions")
    }

    @Test func isoLanguageTakesThePrimarySubtag() {
        #expect(OpenAITranscriber.isoLanguage("de-DE") == "de")
        #expect(OpenAITranscriber.isoLanguage("EN") == "en")
        #expect(OpenAITranscriber.isoLanguage("x") == nil)
    }
}

@Suite("NoSpeech (D11)")
struct NoSpeechTests {
    @Test func emptyTextIsSilence() {
        #expect(NoSpeech.isSilence(Transcription(text: "  "), audio: speech))
    }

    @Test func allSegmentsAboveThresholdIsSilence() {
        #expect(NoSpeech.isSilence(Transcription(text: "anything", noSpeechProbabilities: [0.7, 0.9]), audio: speech))
        #expect(!NoSpeech.isSilence(Transcription(text: "anything", noSpeechProbabilities: [0.7, 0.1]), audio: speech))
    }

    @Test func spokenHallucinationPhrasesSurvive() {
        for phrase in ["Thank you.", "Thank you", "Danke.", "Vielen Dank.", "Bye."] {
            #expect(!NoSpeech.isSilence(Transcription(text: phrase, noSpeechProbabilities: [0.03]), audio: speech), "\(phrase) was spoken")
        }
    }

    @Test func silentHallucinationPhrasesAreDropped() {
        for phrase in ["Thank you.", "Thanks for watching!", "Untertitel im Auftrag des ZDF, 2017", "Vielen Dank."] {
            #expect(NoSpeech.isSilence(Transcription(text: phrase, noSpeechProbabilities: [0.03]), audio: silent), "\(phrase) on a silent recording")
            #expect(NoSpeech.isSilence(Transcription(text: phrase, noSpeechProbabilities: [0.45]), audio: speech), "\(phrase) with Whisper unsure")
        }
    }

    @Test func ordinarySpeechIsNotSilence() {
        #expect(!NoSpeech.isSilence(Transcription(text: "Hi, this is an audio test again.", noSpeechProbabilities: [0.03]), audio: speech))
    }
}

@Suite("FallbackTranscriber")
struct FallbackTranscriberTests {
    @Test func primaryAnswerHasNoFallbackReason() async throws {
        let primary = FakeTranscriber(); let apple = FakeTranscriber()
        let outcome = try await FallbackTranscriber(primary: primary, fallback: apple, primaryName: "Groq").transcribe(speech, language: nil)
        #expect(outcome.fellBackBecause == nil)
        #expect(apple.callCount == 0)
    }

    @Test func availabilityFailuresFallBackWithAReason() async throws {
        let cases: [(TranscriptionFailure, String)] = [
            (.offline, "Groq unavailable (offline)"), (.timeout, "Groq unavailable (timed out)"),
            (.rateLimited, "Groq unavailable (rate limited)"), (.serverError(502), "Groq unavailable (HTTP 502)"),
        ]
        for (failure, reason) in cases {
            let primary = FakeTranscriber(); primary.result = .failure(failure)
            let apple = FakeTranscriber(); apple.result = .success(Transcription(text: "on device"))
            let outcome = try await FallbackTranscriber(primary: primary, fallback: apple, primaryName: "Groq").transcribe(speech, language: "de")
            #expect(outcome.transcription.text == "on device")
            #expect(outcome.fellBackBecause == reason)
            #expect(apple.lastLanguage == "de")
        }
    }

    @Test func configurationFailuresSurfaceWithoutFallback() async {
        for failure in [TranscriptionFailure.unauthorized, .rejected(status: 400, message: "bad"), .malformed] {
            let primary = FakeTranscriber(); primary.result = .failure(failure)
            let apple = FakeTranscriber()
            await #expect(throws: failure) {
                try await FallbackTranscriber(primary: primary, fallback: apple, primaryName: "Groq").transcribe(speech, language: nil)
            }
            #expect(apple.callCount == 0, "a bad key must not silently use Apple forever")
        }
    }

    @Test func withoutAFallbackTheErrorSurfaces() async {
        let primary = FakeTranscriber(); primary.result = .failure(.offline)
        await #expect(throws: TranscriptionFailure.offline) {
            try await FallbackTranscriber(primary: primary, fallback: nil, primaryName: "Groq").transcribe(speech, language: nil)
        }
    }
}
