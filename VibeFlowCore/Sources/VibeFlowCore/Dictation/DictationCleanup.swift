import Foundation

public enum CleanupProvider: String, Codable, Sendable, CaseIterable {
    case groq
    case anthropic
}

/// What a cleanup model returned. `complete` is false when generation stopped early.
public struct CleanupResponse: Sendable, Equatable {
    public var text: String
    public var complete: Bool
    public init(text: String, complete: Bool) {
        self.text = text
        self.complete = complete
    }
}

public enum CleanupFailure: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case rateLimited
    case serverError(Int)
    case offline
    case timeout
    case other(String)

    var reason: String {
        switch self {
        case .noKey: return "no key"
        case .unauthorized: return "key rejected"
        case .rateLimited: return "rate limited"
        case .serverError(let c): return "HTTP \(c)"
        case .offline: return "offline"
        case .timeout: return "timed out"
        case .other(let s): return s
        }
    }
}

public protocol DictationCleaner: Sendable {
    func clean(_ transcript: String, vocabulary: [String]) async throws -> CleanupResponse
}

/// Result of the cleanup stage: the text to paste and an optional status note.
public struct CleanupOutcome: Sendable, Equatable {
    public var text: String
    public var note: String?
    public init(text: String, note: String? = nil) {
        self.text = text
        self.note = note
    }
}

/// Runs cleanup under the D12 contract: a 1.5 s deadline, any error or timeout pastes the raw
/// transcript with a note, and the R1-2 sanity check rejects output that is empty, cut off,
/// or outside 0.7x to 1.3x the raw length (a model that answered or rewrote instead of tidying).
public enum DictationCleanup {
    public static let deadline: Duration = .milliseconds(1_500)
    public static let minRatio = 0.7
    public static let maxRatio = 1.3

    public static func run(_ raw: String, cleaner: (any DictationCleaner)?, vocabulary: [String], clock: any SessionClock) async -> CleanupOutcome {
        guard let cleaner else { return CleanupOutcome(text: raw) }
        do {
            let response = try await withTimeout(deadline, clock: clock) {
                try await cleaner.clean(raw, vocabulary: vocabulary)
            }
            return CleanupOutcome(text: accept(response, raw: raw) ?? raw)
        } catch is TimeoutError {
            return CleanupOutcome(text: raw, note: "Pasted without cleanup (timed out)")
        } catch let failure as CleanupFailure {
            return CleanupOutcome(text: raw, note: "Pasted without cleanup (\(failure.reason))")
        } catch {
            return CleanupOutcome(text: raw, note: "Pasted without cleanup")
        }
    }

    /// nil = reject the cleaned text and paste the raw transcript.
    static func accept(_ response: CleanupResponse, raw: String) -> String? {
        let cleaned = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.complete, !cleaned.isEmpty else { return nil }
        let rawCount = Double(max(raw.trimmingCharacters(in: .whitespacesAndNewlines).count, 1))
        let ratio = Double(cleaned.count) / rawCount
        guard ratio >= minRatio, ratio <= maxRatio else { return nil }
        return cleaned
    }
}

/// Groq (or any OpenAI-compatible) chat completions as the default cleaner (D4).
/// T1: qwen/qwen3.8-27b with reasoning off answered in about 230 ms; gpt-oss models need
/// reasoning_effort "low" and room for their reasoning trace.
public final class ChatCompletionsCleaner: DictationCleaner {
    public static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    public static let defaultModel = "qwen/qwen3.8-27b"

    private let http: any HTTPClient
    private let baseURL: URL
    private let model: String
    private let apiKey: @Sendable () -> String?

    public init(http: any HTTPClient, baseURL: URL = ChatCompletionsCleaner.groqBaseURL, model: String = ChatCompletionsCleaner.defaultModel,
                apiKey: @escaping @Sendable () -> String?) {
        self.http = http
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public func clean(_ transcript: String, vocabulary: [String]) async throws -> CleanupResponse {
        guard let key = apiKey() else { throw CleanupFailure.noKey }
        let response: HTTPResponse
        do {
            response = try await http.send(Self.buildRequest(transcript, vocabulary: vocabulary, model: model, baseURL: baseURL, apiKey: key))
        } catch let error as URLError {
            throw error.code == .timedOut ? CleanupFailure.timeout : CleanupFailure.offline
        }
        switch response.status {
        case 200: break
        case 401, 403: throw CleanupFailure.unauthorized
        case 429: throw CleanupFailure.rateLimited
        case 500...599: throw CleanupFailure.serverError(response.status)
        default: throw CleanupFailure.other("HTTP \(response.status)")
        }
        struct Body: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let choice = (try? JSONDecoder().decode(Body.self, from: response.body))?.choices.first else {
            throw CleanupFailure.other("malformed response")
        }
        return CleanupResponse(text: choice.message.content ?? "", complete: choice.finish_reason == "stop")
    }

    static func buildRequest(_ transcript: String, vocabulary: [String], model: String, baseURL: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": SmartReadPrompts.dictationCleanupSystem(vocabulary: vocabulary)],
                ["role": "user", "content": SmartReadPrompts.dictationUser(transcript)],
            ],
        ]
        let budget = transcript.count / 3 + 100
        if model.hasPrefix("openai/gpt-oss") {
            body["reasoning_effort"] = "low"
            body["max_tokens"] = budget + 500
        } else if model.hasPrefix("qwen/") {
            body["reasoning_effort"] = "none"
            body["max_tokens"] = budget
        } else {
            body["max_tokens"] = budget
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// Claude as the optional cleaner (D4), through the existing Anthropic client.
public final class AnthropicCleaner: DictationCleaner {
    public static let defaultModel = "claude-haiku-4-5"
    private let client: AnthropicClient
    private let model: String

    public init(client: AnthropicClient, model: String = AnthropicCleaner.defaultModel) {
        self.client = client
        self.model = model
    }

    public func clean(_ transcript: String, vocabulary: [String]) async throws -> CleanupResponse {
        do {
            let response = try await client.complete(
                system: SmartReadPrompts.dictationCleanupSystem(vocabulary: vocabulary),
                user: SmartReadPrompts.dictationUser(transcript),
                model: model,
                maxTokens: transcript.count / 3 + 100
            )
            return CleanupResponse(text: response.text, complete: response.stopReason == .endTurn)
        } catch let failure as SmartReadFailure {
            switch failure {
            case .unauthorized: throw CleanupFailure.unauthorized
            case .rateLimited: throw CleanupFailure.rateLimited
            case .overloaded: throw CleanupFailure.serverError(529)
            case .offline: throw CleanupFailure.offline
            case .timeout: throw CleanupFailure.timeout
            case .other(let s): throw CleanupFailure.other(s)
            }
        }
    }
}
