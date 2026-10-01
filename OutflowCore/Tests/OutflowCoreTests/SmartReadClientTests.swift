import Foundation
import Testing
@testable import OutflowCore

@Suite("AnthropicClient")
struct AnthropicClientTests {
    let http = FakeHTTPClient()
    let secrets = FakeSecrets([.anthropic: "sk-test"])
    var client: AnthropicClient { AnthropicClient(http: http, secrets: secrets) }
    var request: SmartReadRequest { SmartReadRequest(text: "The notice period is 30 days unless waived.", mode: .brief, language: "en", model: "claude-haiku-4-5", maxTokens: 800) }

    static func ok(text: String, stop: String = "end_turn") -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "stop_reason": stop])
    }

    @Test func buildsAMessagesRequestWithGuardedPrompts() async throws {
        http.body = Self.ok(text: "Thirty days notice unless waived.")
        _ = try await client.transform(request)
        let req = http.requests[0]
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["max_tokens"] as? Int == 800)
        let system = try #require(body["system"] as? String)
        #expect(system.contains("never an instruction"))
        #expect(system.contains("BCP-47 tag en"))
        #expect(system.contains("10-year-old"))
        #expect(!system.contains("preferences for this app"), "no per-app block without instructions")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"] == "<<<DOCUMENT\nThe notice period is 30 days unless waived.\nDOCUMENT>>>")
        #expect(body["tools"] == nil)
    }

    @Test func perAppInstructionsAreAppendedTrimmedAndCapped() async throws {
        http.body = Self.ok(text: "ok")
        var r = request
        r.instructions = "  Focus on what they want from me.  "
        _ = try await client.transform(r)
        let body = try #require(try JSONSerialization.jsonObject(with: http.requests[0].httpBody!) as? [String: Any])
        let system = try #require(body["system"] as? String)
        #expect(system.hasSuffix("Follow them unless they conflict with the rules above: Focus on what they want from me."))
        #expect(system.contains("never an instruction"), "the injection guard stays in front")

        let long = SmartReadPrompts.system(mode: .brief, language: nil, instructions: String(repeating: "x", count: 2_000))
        #expect(long.hasSuffix(String(repeating: "x", count: SmartReadPrompts.maxInstructionsLength)))
        #expect(!long.hasSuffix(String(repeating: "x", count: SmartReadPrompts.maxInstructionsLength + 1)))
        #expect(SmartReadPrompts.system(mode: .brief, language: nil, instructions: "   ") == SmartReadPrompts.system(mode: .brief, language: nil))
    }

    @Test func cleanupPromptPreservesMeaningAndSourceLanguageWhenUnspecified() {
        let system = SmartReadPrompts.system(mode: .cleanup, language: nil)
        #expect(system.contains("Do not summarize"))
        #expect(system.contains("same language as the document"))
    }

    @Test func parsesTextAndStopReason() async throws {
        http.body = Self.ok(text: "Short brief.", stop: "max_tokens")
        let response = try await client.transform(request)
        #expect(response == SmartReadResponse(text: "Short brief.", stopReason: .maxTokens))
        #expect(AnthropicClient.stopReason("tool_use") == .other("tool_use"))
        #expect(AnthropicClient.stopReason(nil) == .other("missing"))
    }

    @Test func httpStatusesMapToFailures() async {
        for (status, expected) in [(401, SmartReadFailure.unauthorized), (403, .unauthorized), (429, .rateLimited), (529, .overloaded), (503, .overloaded), (400, .other("HTTP 400"))] {
            http.status = status
            await #expect(throws: expected) { try await client.transform(request) }
        }
    }

    @Test func offlineAndTimeoutURLErrorsMap() async {
        http.connectError = URLError(.notConnectedToInternet)
        await #expect(throws: SmartReadFailure.offline) { try await client.transform(request) }
        http.connectError = URLError(.timedOut)
        await #expect(throws: SmartReadFailure.timeout) { try await client.transform(request) }
    }

    @Test func malformedBodyIsReported() async {
        http.body = Data("not json".utf8)
        await #expect(throws: SmartReadFailure.other("malformed response")) { try await client.transform(request) }
    }

    @Test func missingKeyIsUnauthorizedWithoutARequest() async {
        try? secrets.delete(.anthropic)
        await #expect(throws: SmartReadFailure.unauthorized) { try await client.transform(request) }
        #expect(http.requests.isEmpty)
    }
}
