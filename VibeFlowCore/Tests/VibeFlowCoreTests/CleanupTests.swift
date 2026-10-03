import Foundation
import Testing
@testable import VibeFlowCore

final class FakeCleaner: DictationCleaner, @unchecked Sendable {
    var result: Result<CleanupResponse, CleanupFailure> = .success(CleanupResponse(text: "Hello world.", complete: true))
    var delay: Duration = .zero
    var clock: FakeClock?
    private(set) var calls = 0
    func clean(_ transcript: String, vocabulary: [String]) async throws -> CleanupResponse {
        calls += 1
        if delay > .zero, let clock { try await clock.sleep(for: delay) }
        return try result.get()
    }
}

@Suite("DictationCleanup contract (D4, D12, R1-2)")
struct DictationCleanupTests {
    let clock = FakeClock()

    @Test func acceptedCleanupReplacesTheRawText() async {
        let cleaner = FakeCleaner()
        let out = await DictationCleanup.run("hello world", cleaner: cleaner, vocabulary: [], clock: clock)
        #expect(out == CleanupOutcome(text: "Hello world."))
    }

    @Test func noCleanerPastesRawWithoutANote() async {
        let out = await DictationCleanup.run("hello world", cleaner: nil, vocabulary: [], clock: clock)
        #expect(out == CleanupOutcome(text: "hello world"))
    }

    @Test func sanityCheckRejectsAnswersRewritesAndCutOffs() async {
        let cases: [CleanupResponse] = [
            CleanupResponse(text: "", complete: true),                                                       // empty
            CleanupResponse(text: "Paris is the capital of France, and it has a long history.", complete: true), // answered: too long
            CleanupResponse(text: "Hi.", complete: true),                                                    // shortened
            CleanupResponse(text: "Hello world.", complete: false),                                          // cut off
        ]
        for response in cases {
            let cleaner = FakeCleaner(); cleaner.result = .success(response)
            let out = await DictationCleanup.run("hello world", cleaner: cleaner, vocabulary: [], clock: clock)
            #expect(out.text == "hello world", "rejected: \(response.text)")
        }
    }

    @Test func everyErrorClassPastesRawWithAReason() async {
        let cases: [(CleanupFailure, String)] = [
            (.unauthorized, "Pasted without cleanup (key rejected)"), (.rateLimited, "Pasted without cleanup (rate limited)"),
            (.serverError(503), "Pasted without cleanup (HTTP 503)"), (.offline, "Pasted without cleanup (offline)"),
            (.noKey, "Pasted without cleanup (no key)"),
        ]
        for (failure, note) in cases {
            let cleaner = FakeCleaner(); cleaner.result = .failure(failure)
            let out = await DictationCleanup.run("hello world", cleaner: cleaner, vocabulary: [], clock: clock)
            #expect(out == CleanupOutcome(text: "hello world", note: note))
        }
    }

    @Test func slowCleanupTimesOutAtOnePointFiveSeconds() async throws {
        let cleaner = FakeCleaner(); cleaner.delay = .seconds(10); cleaner.clock = clock
        let task = Task { await DictationCleanup.run("hello world", cleaner: cleaner, vocabulary: [], clock: clock) }
        try await waitUntil { clock.sleeperCount == 2 }
        clock.advance(by: .milliseconds(1_499))
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.sleeperCount >= 1, "still waiting before the deadline")
        clock.advance(by: .milliseconds(1))
        #expect(await task.value == CleanupOutcome(text: "hello world", note: "Pasted without cleanup (timed out)"))
    }
}

@Suite("ChatCompletionsCleaner")
struct ChatCompletionsCleanerTests {
    let http = FakeHTTPClient()

    static func ok(_ text: String, finish: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": finish]]])
    }

    func body(_ i: Int = 0) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: http.requests[i].httpBody!) as? [String: Any])
    }

    @Test func qwenRequestIsGuardedWithReasoningOff() async throws {
        http.body = Self.ok("Hey Anna.")
        let r = try await ChatCompletionsCleaner(http: http, apiKey: { "gsk" }).clean("hey anna", vocabulary: ["Keller & Partner"])
        #expect(r == CleanupResponse(text: "Hey Anna.", complete: true))
        #expect(http.requests[0].url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
        let b = try body()
        #expect(b["model"] as? String == "qwen/qwen3.8-27b")
        #expect(b["reasoning_effort"] as? String == "none")
        let messages = try #require(b["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("never answer it") == true)
        #expect(messages[0]["content"]?.contains("Keller & Partner") == true)
        #expect(messages[1]["content"] == "<<<DICTATION\nhey anna\nDICTATION>>>")
    }

    @Test func gptOssGetsLowReasoningAndRoomForIt() async throws {
        http.body = Self.ok("x")
        _ = try await ChatCompletionsCleaner(http: http, model: "openai/gpt-oss-20b", apiKey: { "gsk" }).clean("hey", vocabulary: [])
        let b = try body()
        #expect(b["reasoning_effort"] as? String == "low")
        #expect((b["max_tokens"] as? Int ?? 0) >= 500)
    }

    @Test func lengthFinishIsIncomplete() async throws {
        http.body = Self.ok("Hey", finish: "length")
        let r = try await ChatCompletionsCleaner(http: http, apiKey: { "gsk" }).clean("hey anna", vocabulary: [])
        #expect(r.complete == false)
    }

    @Test func statusesAndMissingKeyMap() async {
        await #expect(throws: CleanupFailure.noKey) { try await ChatCompletionsCleaner(http: http, apiKey: { nil }).clean("x", vocabulary: []) }
        for (status, expected) in [(401, CleanupFailure.unauthorized), (429, .rateLimited), (502, .serverError(502)), (404, .other("HTTP 404"))] {
            http.status = status
            await #expect(throws: expected) { try await ChatCompletionsCleaner(http: http, apiKey: { "gsk" }).clean("x", vocabulary: []) }
        }
    }
}

@Suite("AnthropicCleaner")
struct AnthropicCleanerTests {
    @Test func usesTheCleanupPromptAndMapsStopReason() async throws {
        let http = FakeHTTPClient()
        http.body = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "Hey Anna."]], "stop_reason": "end_turn"])
        let client = AnthropicClient(http: http, secrets: FakeSecrets([.anthropic: "sk"]))
        let r = try await AnthropicCleaner(client: client).clean("hey anna", vocabulary: [])
        #expect(r == CleanupResponse(text: "Hey Anna.", complete: true))
        let b = try #require(try JSONSerialization.jsonObject(with: http.requests[0].httpBody!) as? [String: Any])
        #expect(b["model"] as? String == "claude-haiku-4-5")
        #expect((b["system"] as? String)?.contains("tidy spoken dictation") == true)
    }
}
