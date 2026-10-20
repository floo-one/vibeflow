import Foundation

/// SmartReadClient over the Anthropic Messages API (design D5, D12). One non-streaming
/// request; the session awaits the full text before speaking it.
public final class AnthropicClient: SmartReadClient {
    public static let apiVersion = "2023-06-01"

    private let http: any HTTPClient
    private let secrets: any SecretsStore
    private let baseURL: URL

    public init(http: any HTTPClient, secrets: any SecretsStore, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.http = http
        self.secrets = secrets
        self.baseURL = baseURL
    }

    public func transform(_ request: SmartReadRequest) async throws -> SmartReadResponse {
        try await complete(
            system: SmartReadPrompts.system(mode: request.mode, language: request.language, instructions: request.instructions, inputCharacters: request.text.count),
            user: SmartReadPrompts.user(text: request.text),
            model: request.model,
            maxTokens: request.maxTokens
        )
    }

    /// One Messages API call with a system prompt and a single user message. Shared by smart
    /// read and dictation cleanup (D4: Anthropic as the optional cleanup provider).
    public func complete(system: String, user: String, model: String, maxTokens: Int) async throws -> SmartReadResponse {
        guard let key = secrets.read(.anthropic) else { throw SmartReadFailure.unauthorized }
        let urlRequest = Self.buildRequest(system: system, user: user, model: model, maxTokens: maxTokens, apiKey: key, baseURL: baseURL)

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

        switch response.status {
        case 200: break
        case 401, 403: throw SmartReadFailure.unauthorized
        case 429: throw SmartReadFailure.rateLimited
        case 529, 503: throw SmartReadFailure.overloaded
        default: throw SmartReadFailure.other("HTTP \(response.status)")
        }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: response.body) else {
            throw SmartReadFailure.other("malformed response")
        }
        let text = message.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        return SmartReadResponse(text: text, stopReason: Self.stopReason(message.stop_reason))
    }

    static func buildRequest(system: String, user: String, model: String, maxTokens: Int, apiKey: String, baseURL: URL) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 25
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    static func stopReason(_ raw: String?) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "max_tokens": return .maxTokens
        case let other?: return .other(other)
        case nil: return .other("missing")
        }
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
