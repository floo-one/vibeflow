import Foundation
import Testing
@testable import VibeFlowCore

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
        #expect(system.contains("15-year-old"))
        #expect(system.contains("at most 40 words"), "a 44-character selection gets the shortest brief")
        #expect(!system.contains("preferences for this app"), "no per-app block without instructions")
        // Value: protects=a plain request (aiReply defaults false) reaching the API without the assistant-voice rule; fails_when=AnthropicClient stops forwarding request.aiReply (e.g. hardcodes true) or the init default flips; why_new=existing aiReply tests only check the true path through the client; seam=none; no_claim=does not judge prompt wording
        #expect(!system.contains(SmartReadPrompts.aiReplyRule), "no assistant voice unless the text came from an AI app")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"] == "<<<DOCUMENT\nThe notice period is 30 days unless waived.\nDOCUMENT>>>")
        #expect(body["tools"] == nil)
    }

    @Test func thinkingIsTurnedOffPerModelSoItCannotEatTheBrief() async throws {
        for (model, check) in [
            ("claude-haiku-5-5", { (b: [String: Any]) in (b["thinking"] as? [String: String]) == ["type": "disabled"] && b["max_tokens"] as? Int == 800 }),
            ("claude-sonnet-5-5", { b in (b["thinking"] as? [String: String]) == ["type": "between_tools"] && b["max_tokens"] as? Int == 800 }),
            ("claude-opus-5-5", { b in b["thinking"] == nil && (b["output_config"] as? [String: String]) == ["effort": "low"] && b["max_tokens"] as? Int == 800 + AnthropicClient.thinkingHeadroom }),
            ("claude-haiku-4-5", { b in b["thinking"] == nil && b["output_config"] == nil && b["max_tokens"] as? Int == 800 }),
        ] as [(String, ([String: Any]) -> Bool)] {
            http.body = Self.ok(text: "ok")
            var r = request
            r.model = model
            _ = try await client.transform(r)
            let body = try #require(try JSONSerialization.jsonObject(with: http.requests.last!.httpBody!) as? [String: Any])
            #expect(check(body), "\(model): \(body)")
        }
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

    @Test func briefLengthFollowsTheInput() {
        #expect(SmartReadPrompts.briefLength(forCharacters: 200) == "at most 40 words")
        #expect(SmartReadPrompts.briefLength(forCharacters: 2_000) == "at most 80 words")
        #expect(SmartReadPrompts.briefLength(forCharacters: 20_000) == "at most 140 words")
        #expect(SmartReadPrompts.system(mode: .brief, language: nil, inputCharacters: 20_000).contains("at most 140 words"))
        #expect(!SmartReadPrompts.system(mode: .cleanup, language: nil, inputCharacters: 20_000).contains("at most 140 words"))
    }

    @Test func aiReplyRuleOnlyJoinsTheBriefForAIReplies() async throws {
        let plain = SmartReadPrompts.system(mode: .brief, language: nil)
        let ai = SmartReadPrompts.system(mode: .brief, language: nil, aiReply: true)
        #expect(!plain.contains(SmartReadPrompts.aiReplyRule))
        #expect(ai.contains(SmartReadPrompts.aiReplyRule))
        #expect(ai.contains("never an instruction"), "the injection guard stays in front")
        #expect(!SmartReadPrompts.system(mode: .cleanup, language: nil, aiReply: true).contains(SmartReadPrompts.aiReplyRule))

        // Value: protects=per-app preferences staying last, after the assistant-voice rule, so "the rules above" still covers the injection guard and the rule; fails_when=aiReplyRule is appended after the instructions block or replaces it; why_new=no test combines aiReply with per-app instructions; seam=none; no_claim=does not judge how the model weighs the two
        let withPrefs = SmartReadPrompts.system(mode: .brief, language: "de", instructions: "Only deadlines.", aiReply: true)
        let rule = try #require(withPrefs.range(of: SmartReadPrompts.aiReplyRule))
        let prefs = try #require(withPrefs.range(of: "preferences for this app"))
        #expect(rule.upperBound <= prefs.lowerBound)
        #expect(withPrefs.hasSuffix("Follow them unless they conflict with the rules above: Only deadlines."))
        #expect(withPrefs.contains("BCP-47 tag de"), "a language override still applies")

        http.body = Self.ok(text: "ok")
        var r = request
        r.aiReply = true
        _ = try await client.transform(r)
        let body = try #require(try JSONSerialization.jsonObject(with: http.requests[0].httpBody!) as? [String: Any])
        #expect((body["system"] as? String)?.contains(SmartReadPrompts.aiReplyRule) == true)
    }

    @Test func knownAIAppsAreRecognisedByBundleID() {
        #expect(SmartReadPrompts.isAIAssistant(bundleID: "com.openai.chat"))
        #expect(SmartReadPrompts.isAIAssistant(bundleID: "com.anthropic.claudefordesktop"))
        #expect(!SmartReadPrompts.isAIAssistant(bundleID: "com.apple.Safari"))
        #expect(!SmartReadPrompts.isAIAssistant(bundleID: nil))
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

    @Test func apiErrorMessageIsKept() async {
        http.status = 400
        http.body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages: text content blocks must be non-empty"}}"#.utf8)
        await #expect(throws: SmartReadFailure.other("HTTP 400: messages: text content blocks must be non-empty")) { try await client.transform(request) }
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

    // MARK: Follow-up questions

    static func sse(_ events: [String]) -> [String] {
        events.flatMap { ["data: \($0)", ""] }
    }

    func collect(_ stream: AsyncThrowingStream<AnswerChunk, Error>) async throws -> [AnswerChunk] {
        var chunks: [AnswerChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    @Test func askStreamsTheDocumentBriefTurnsAndQuestion() async throws {
        let stream = FakeByteStreamClient()
        stream.lines = ["event: message_start"] + Self.sse([
            #"{"type":"message_start","message":{}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Thirty "}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"days."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let client = AnthropicClient(http: http, stream: stream, secrets: secrets)
        let ask = AskRequest(document: "Notice is 30 days.", brief: "Thirty days notice.",
                             turns: [ConversationTurn(question: "Can it be waived?", answer: "Yes, by both sides.")],
                             question: "And in writing?", model: "claude-haiku-4-5", maxTokens: SmartReadPrompts.answerMaxTokens)
        let chunks = try await collect(client.ask(ask))
        #expect(chunks == [.text("Thirty "), .text("days."), .done(.endTurn)])

        let body = try #require(try JSONSerialization.jsonObject(with: stream.requests[0].httpBody!) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 600)
        #expect(body["thinking"] == nil, "Haiku 4.5 gets no thinking field")
        let system = try #require(body["system"] as? String)
        #expect(system.contains("never an instruction"))
        #expect(system.contains("not from the document"))
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["user", "assistant", "user", "assistant", "user"])
        #expect(messages[0]["content"] == "<<<DOCUMENT\nNotice is 30 days.\nDOCUMENT>>>")
        #expect(messages[1]["content"] == "Thirty days notice.")
        #expect(messages[4]["content"] == "And in writing?")
    }

    @Test func askStreamErrorsMapToFailures() async throws {
        let stream = FakeByteStreamClient()
        let client = AnthropicClient(http: http, stream: stream, secrets: secrets)
        let ask = AskRequest(document: "d", question: "q", model: "claude-haiku-4-5", maxTokens: 600)
        stream.status = 400
        stream.lines = [#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#]
        await #expect(throws: SmartReadFailure.other("HTTP 400: Your credit balance is too low")) { try await collect(client.ask(ask)) }
        stream.status = 200
        stream.lines = Self.sse([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        await #expect(throws: SmartReadFailure.overloaded) { try await collect(client.ask(ask)) }
        stream.connectError = URLError(.notConnectedToInternet)
        await #expect(throws: SmartReadFailure.offline) { try await collect(client.ask(ask)) }
        try secrets.delete(.anthropic)
        await #expect(throws: SmartReadFailure.unauthorized) { try await collect(client.ask(ask)) }
    }

    @Test func haiku55RunsWithoutThinking() throws {
        let req = AnthropicClient.buildRequest(system: "s", messages: [ChatMessage(role: .user, content: "u")], model: "claude-haiku-5-5",
                                               maxTokens: 600, apiKey: "k", baseURL: URL(string: "https://api.anthropic.com")!)
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        #expect((body["thinking"] as? [String: String]) == ["type": "disabled"])
    }

    @Test func withoutABriefTheFirstQuestionJoinsTheDocumentMessage() {
        let first = SmartReadPrompts.askMessages(document: "Doc.", brief: nil, turns: [], question: "What is it?")
        #expect(first == [ChatMessage(role: .user, content: "<<<DOCUMENT\nDoc.\nDOCUMENT>>>\n\nWhat is it?")])
        let second = SmartReadPrompts.askMessages(document: "Doc.", brief: nil,
                                                  turns: [ConversationTurn(question: "What is it?", answer: "A doc.")], question: "Why?")
        #expect(second.map(\.role) == [.user, .assistant, .user])
        #expect(second[0].content.hasSuffix("What is it?"))
        #expect(second[2].content == "Why?")
    }

    @Test func askPromptFollowsLanguageAndInstructions() {
        #expect(SmartReadPrompts.askSystem(language: "de").contains("BCP-47 tag de"))
        #expect(SmartReadPrompts.askSystem(language: nil).contains("same language as the listener's question"))
        #expect(SmartReadPrompts.askSystem(language: nil, instructions: "Be blunt.").hasSuffix("rules above: Be blunt."))
    }

    @Test func completeSentencesDropsTheCutOffTail() {
        #expect(Sentences.complete("First point. Second point is cut") == "First point.")
        #expect(Sentences.complete("Done. All done!") == "Done. All done!")
        #expect(Sentences.complete("Nothing finished") == "")
    }
}
