import Foundation

/// SmartReadClient over the Anthropic Messages API (design D5, D12). The brief is one
/// non-streaming request; follow-up answers stream (server-sent events) so the voice can start
/// on the first sentence.
public final class AnthropicClient: SmartReadClient {
    public static let apiVersion = "2023-06-01"

    private let http: any HTTPClient
    private let stream: any ByteStreamClient
    private let secrets: any SecretsStore
    private let baseURL: URL

    public init(http: any HTTPClient, stream: any ByteStreamClient = URLSessionByteStreamClient(), secrets: any SecretsStore,
                baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.http = http
        self.stream = stream
        self.secrets = secrets
        self.baseURL = baseURL
    }

    public func transform(_ request: SmartReadRequest) async throws -> SmartReadResponse {
        try await complete(
            system: SmartReadPrompts.system(mode: request.mode, language: request.language, instructions: request.instructions, inputCharacters: request.text.count, aiReply: request.aiReply),
            user: SmartReadPrompts.user(text: request.text),
            model: request.model,
            maxTokens: request.maxTokens
        )
    }

    public func ask(_ request: AskRequest) -> AsyncThrowingStream<AnswerChunk, Error> {
        let client = stream
        let key = secrets.read(.anthropic)
        let urlRequest = key.map {
            Self.buildRequest(system: SmartReadPrompts.askSystem(language: request.language, instructions: request.instructions),
                              messages: SmartReadPrompts.askMessages(document: request.document, brief: request.brief, turns: request.turns, question: request.question),
                              model: request.model, maxTokens: request.maxTokens, apiKey: $0, baseURL: baseURL, stream: true)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let urlRequest else { throw SmartReadFailure.unauthorized }
                    try await Self.streamAnswer(urlRequest, client: client) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the event stream: text deltas as they come, then the stop reason. Thinking deltas
    /// (Haiku 5.5 and newer) and pings are skipped.
    static func streamAnswer(_ request: URLRequest, client: any ByteStreamClient, emit: (AnswerChunk) -> Void) async throws {
        let response = try await client.stream(request)
        if response.status != 200 {
            var body = ""
            for try await line in response.lines { body += line }
            throw failure(status: response.status, body: Data(body.utf8))
        }
        var stop: StopReason?
        for try await line in response.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            guard let event = try? JSONDecoder().decode(StreamEvent.self, from: json) else { continue }
            switch event.type {
            case "content_block_delta":
                if event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty { emit(.text(text)) }
            case "message_delta":
                if let reason = event.delta?.stop_reason { stop = stopReason(reason) }
            case "error":
                let message = event.error?.message ?? "stream error"
                throw event.error?.type == "overloaded_error" ? SmartReadFailure.overloaded : SmartReadFailure.other(message)
            default:
                break
            }
        }
        emit(.done(stop ?? .other("missing")))
    }

    private static func map(_ error: Error) -> Error {
        if error is SmartReadFailure || error is CancellationError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return SmartReadFailure.offline
            case .timedOut:
                return SmartReadFailure.timeout
            case .cancelled:
                return CancellationError()
            default:
                return SmartReadFailure.other(error.localizedDescription)
            }
        }
        return SmartReadFailure.other(String(describing: error))
    }

    static func failure(status: Int, body: Data) -> SmartReadFailure {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 529, 503: return .overloaded
        default:
            // Keep the API's own reason (R2-11), e.g. "Your credit balance is too low".
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: body))?.error.message
            return .other(detail.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
        }
    }

    /// One Messages API call with a system prompt and a single user message. Shared by smart
    /// read and dictation cleanup (D4: Anthropic as the optional cleanup provider).
    public func complete(system: String, user: String, model: String, maxTokens: Int) async throws -> SmartReadResponse {
        try await complete(system: system, messages: [ChatMessage(role: .user, content: user)], model: model, maxTokens: maxTokens)
    }

    /// One Messages API call with a system prompt and alternating user and assistant messages.
    public func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> SmartReadResponse {
        guard let key = secrets.read(.anthropic) else { throw SmartReadFailure.unauthorized }
        let urlRequest = Self.buildRequest(system: system, messages: messages, model: model, maxTokens: maxTokens, apiKey: key, baseURL: baseURL)

        let response: HTTPResponse
        do {
            response = try await http.send(urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw SmartReadFailure.offline
            case .timedOut:
                throw SmartReadFailure.timeout
            default:
                throw SmartReadFailure.other(error.localizedDescription)
            }
        }

        guard response.status == 200 else { throw Self.failure(status: response.status, body: response.body) }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: response.body) else {
            throw SmartReadFailure.other("malformed response")
        }
        let text = message.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        return SmartReadResponse(text: text, stopReason: Self.stopReason(message.stop_reason))
    }

    static func buildRequest(system: String, messages: [ChatMessage], model: String, maxTokens: Int, apiKey: String, baseURL: URL, stream: Bool = false) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 25
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if stream { body["stream"] = true }
        body.merge(thinkingFields(model: model, maxTokens: maxTokens)) { _, new in new }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Extra headroom for models whose thinking cannot be turned off.
    static let thinkingHeadroom = 4_000

    /// The 5.5 models think by default, and thinking counts against max_tokens: an 800-token
    /// brief on Haiku 5.5 stopped at max_tokens with no text at all. Each model turns thinking
    /// off its own way; Opus 5.5 cannot, so it gets low effort and headroom instead.
    static func thinkingFields(model: String, maxTokens: Int) -> [String: Any] {
        switch model {
        case "claude-haiku-5-5":
            return ["thinking": ["type": "disabled"]]
        case "claude-sonnet-5-5":
            return ["thinking": ["type": "between_tools"]]
        case "claude-opus-5-5":
            return ["output_config": ["effort": "low"], "max_tokens": maxTokens + thinkingHeadroom]
        default:
            return [:]
        }
    }

    static func stopReason(_ raw: String?) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "max_tokens": return .maxTokens
        case let other?: return .other(other)
        case nil: return .other("missing")
        }
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }
        struct Failure: Decodable {
            let type: String?
            let message: String?
        }
        let type: String
        let delta: Delta?
        let error: Failure?
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }
}
