import Foundation
import Testing
@testable import VibeFlowCore

@MainActor
struct ElevenLabsHarness {
    let client = FakeByteStreamClient()
    let player = FakeAudioPlayer()
    let secrets = FakeSecrets([.elevenLabs: "test-key"])
    let provider: ElevenLabsProvider

    init() {
        provider = ElevenLabsProvider(client: client, player: player, secrets: secrets)
    }

    /// One NDJSON line with `samples` PCM frames and alignment for `characters`.
    static func line(samples: Int, characters: [String], startTimes: [Double]) -> String {
        let pcm = Data(repeating: 0x01, count: samples * 2)
        var obj: [String: Any] = ["audio_base64": pcm.base64EncodedString()]
        if !characters.isEmpty {
            obj["alignment"] = [
                "characters": characters,
                "character_start_times_seconds": startTimes,
                "character_end_times_seconds": startTimes.map { $0 + 0.1 },
            ]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func collect(_ playback: any SpeechPlayback) async -> (events: [SpeechEvent], failure: SpeechFailure?) {
        var events: [SpeechEvent] = []
        do {
            for try await e in playback.events { events.append(e) }
            return (events, nil)
        } catch {
            return (events, error as? SpeechFailure)
        }
    }

    func body(of request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

@Suite("ElevenLabsProvider: request") @MainActor
struct ElevenLabsRequestTests {
    @Test func postsToStreamWithTimestampsWithPCMAndKey() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 240, characters: ["H", "i"], startTimes: [0, 0.1])]
        _ = await h.collect(h.provider.speak(SpeechRequest(text: "Hi", voiceID: "voice-1")))

        let req = h.client.requests[0]
        #expect(req.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-1/stream/with-timestamps?output_format=pcm_24000")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        let body = h.body(of: req)
        #expect(body["text"] as? String == "Hi")
        #expect(body["model_id"] as? String == "eleven_flash_v2_5")
        #expect(body["language_code"] == nil)
    }

    @Test func speedIsClampedTo1Point2AndTheRemainderGoesToThePlayer() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 10, characters: [], startTimes: [])]
        _ = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v", speed: 1.5)))
        let settings = h.body(of: h.client.requests[0])["voice_settings"] as? [String: Any]
        #expect(settings?["speed"] as? Double == 1.2)
        #expect(h.player.rates == [1.25])
    }

    @Test func speedWithinRangeIsSentAsIsWithPlayerRate1() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 10, characters: [], startTimes: [])]
        _ = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v", speed: 0.9)))
        let settings = h.body(of: h.client.requests[0])["voice_settings"] as? [String: Any]
        #expect(settings?["speed"] as? Double == 0.9)
        #expect(h.player.rates == [1.0])
    }

    @Test func languageOverrideIsNormalizedToISO639OrOmitted() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 10, characters: [], startTimes: [])]
        _ = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v", language: "de-DE")))
        #expect(h.body(of: h.client.requests[0])["language_code"] as? String == "de")

        _ = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v", language: "xx-XX")))
        #expect(h.body(of: h.client.requests[1])["language_code"] == nil)
        #expect(ElevenLabsLanguage.code(for: "FIL") == "fil")
        #expect(ElevenLabsLanguage.code(for: nil) == nil)
    }

    @Test func resumeRequestSendsOnlyTheSuffix() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 10, characters: [], startTimes: [])]
        _ = await h.collect(h.provider.speak(SpeechRequest(text: "First. Second.", voiceID: "v", startOffset: 7)))
        #expect(h.body(of: h.client.requests[0])["text"] as? String == "Second.")
    }

    @Test func missingKeyFailsAsUnauthorizedWithoutARequest() async {
        let h = ElevenLabsHarness()
        try? h.secrets.delete(.elevenLabs)
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .unauthorized)
        #expect(h.client.requests.isEmpty)
    }
}

@Suite("ElevenLabsProvider: stream") @MainActor
struct ElevenLabsStreamTests {
    @Test func audioLinesAreScheduledAndEventsFollowTheStream() async {
        let h = ElevenLabsHarness()
        h.client.lines = [
            ElevenLabsHarness.line(samples: 240, characters: ["H", "e"], startTimes: [0.0, 0.1]),
            ElevenLabsHarness.line(samples: 240, characters: ["l", "l", "o"], startTimes: [0.2, 0.3, 0.4]),
        ]
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "Hello", voiceID: "v")))
        #expect(result.failure == nil)
        #expect(result.events == [.started, .progress(characterOffset: 2), .progress(characterOffset: 5), .finished])
        #expect(h.player.prepared)
        #expect(h.player.scheduled.count == 2)
        #expect(h.player.scheduled[0].count == 480, "240 frames of Int16")
    }

    @Test func progressOffsetsIncludeTheStartOffsetOfAResume() async {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 10, characters: ["S", "e"], startTimes: [0, 0.1])]
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "First. Second.", voiceID: "v", startOffset: 7)))
        #expect(result.events.contains(.progress(characterOffset: 9)))
    }

    @Test func http401IsUnauthorized() async {
        let h = ElevenLabsHarness()
        h.client.status = 401
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .unauthorized)
        #expect(result.events.isEmpty)
    }

    @Test func http400IsOtherWithTheStatus() async {
        let h = ElevenLabsHarness()
        h.client.status = 400
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .other("HTTP 400"))
    }

    @Test func okWithNoAudioLinesIsEmptyResponse() async {
        let h = ElevenLabsHarness()
        h.client.lines = ["{\"alignment\":null}"]
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .emptyResponse)
        #expect(h.player.scheduled.isEmpty)
    }

    @Test func offlineErrorBeforeAnyAudioIsOffline() async {
        let h = ElevenLabsHarness()
        h.client.connectError = URLError(.notConnectedToInternet)
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .offline)
    }

    @Test func dropAfterAudioReportsTheLastPlayedCharacter() async {
        let h = ElevenLabsHarness()
        h.client.lines = [
            ElevenLabsHarness.line(samples: 240, characters: ["A", "b", "c", "d"], startTimes: [0.0, 0.5, 1.0, 1.5]),
            ElevenLabsHarness.line(samples: 240, characters: ["e", "f"], startTimes: [2.0, 2.5]),
            "never delivered",
        ]
        h.client.error = URLError(.networkConnectionLost)
        h.client.linesBeforeError = 2
        h.player.playedSeconds = 1.2 // "c" has started, "d" has not
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "Abcdef", voiceID: "v", startOffset: 10)))
        #expect(result.failure == .connectionLost(lastPlayedOffset: 12))
        #expect(result.events.first == .started)
    }

    @Test func malformedLineIsReportedNotCrashed() async {
        let h = ElevenLabsHarness()
        h.client.lines = ["{not json"]
        let result = await h.collect(h.provider.speak(SpeechRequest(text: "x", voiceID: "v")))
        #expect(result.failure == .other("malformed response"))
    }

    @Test func cancelStopsThePlayerAndEndsTheStreamWithoutEvents() async throws {
        let h = ElevenLabsHarness()
        h.client.lines = [ElevenLabsHarness.line(samples: 240, characters: [], startTimes: [])]
        let playback = h.provider.speak(SpeechRequest(text: "x", voiceID: "v"))
        playback.cancel()
        playback.cancel() // idempotent
        #expect(h.player.stopCount == 1)
        let result = await h.collect(playback)
        #expect(result.failure == nil)
        #expect(!result.events.contains(.finished))
    }
}
