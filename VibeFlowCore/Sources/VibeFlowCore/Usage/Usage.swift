import Foundation

/// A paid API VibeFlow calls. Custom (OpenAI-compatible) endpoints and Apple's on-device
/// engines are free and never metered.
public enum UsageProvider: String, Codable, Sendable, CaseIterable {
    case elevenLabs, groq, anthropic

    public var title: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .groq: "Groq"
        case .anthropic: "Anthropic"
        }
    }
}

/// What the provider bills for: characters spoken, seconds of audio heard, or tokens.
public enum UsageKind: String, Codable, Sendable {
    case textToSpeech, speechToText, languageModel
}

/// One billable request, as counts only. Never holds the text that was sent or returned
/// (CLAUDE.md: never log user text).
public struct UsageEvent: Sendable, Equatable {
    public var provider: UsageProvider
    public var kind: UsageKind
    public var model: String
    public var date: Date
    public var characters = 0
    public var audioSeconds = 0.0
    public var inputTokens = 0
    public var outputTokens = 0

    public init(provider: UsageProvider, kind: UsageKind, model: String, date: Date, characters: Int = 0,
                audioSeconds: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.provider = provider
        self.kind = kind
        self.model = model
        self.date = date
        self.characters = characters
        self.audioSeconds = audioSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// What the user knows this as, from what the provider bills (one provider and kind is
    /// one feature, except Whisper, which serves dictation and file transcription).
    public var feature: String { Self.feature(provider, kind) }

    public static func feature(_ provider: UsageProvider, _ kind: UsageKind) -> String {
        switch (provider, kind) {
        case (.elevenLabs, .textToSpeech): "Read aloud"
        case (.elevenLabs, .speechToText): "Call transcription"
        case (.groq, .speechToText): "Dictation and file transcription"
        case (.groq, .languageModel): "Dictation cleanup"
        case (.anthropic, .languageModel): "Smart Read, answers and summaries"
        default: "Other"
        }
    }
}

/// List prices per unit, to estimate what a request cost. The provider's bill is the real
/// number: ElevenLabs subscriptions bill in credits, and prices change. Unknown models
/// cost nil and show as "not priced".
public enum UsagePricing {
    /// When the table below was last checked against the providers' pricing pages.
    public static let checked = "2026-11-05"

    /// Dollars per million input and output tokens.
    struct TokenPrice { let input: Double; let output: Double }

    /// Groq bills every transcription request as at least 10 seconds.
    static let groqMinimumSeconds = 10.0

    public static func cost(_ event: UsageEvent) -> Double? {
        let model = event.model.lowercased()
        switch (event.provider, event.kind) {
        case (.elevenLabs, .textToSpeech):
            // Flash and Turbo: $0.05 per 1,000 characters; Multilingual v2 and v3: $0.10.
            let perThousand: Double
            if model.contains("flash") || model.contains("turbo") { perThousand = 0.05 }
            else if model.contains("multilingual") || model.contains("eleven_v3") { perThousand = 0.10 }
            else { return nil }
            return Double(event.characters) / 1_000 * perThousand
        case (.elevenLabs, .speechToText):
            guard model.hasPrefix("scribe") else { return nil }
            return event.audioSeconds / 3_600 * 0.22
        case (.groq, .speechToText):
            let perHour: Double
            if model.contains("whisper-large-v3-turbo") { perHour = 0.04 }
            else if model.contains("whisper-large-v3") { perHour = 0.111 }
            else { return nil }
            return max(event.audioSeconds, groqMinimumSeconds) / 3_600 * perHour
        case (.groq, .languageModel), (.anthropic, .languageModel):
            guard let price = tokenPrice(model: model, inputTokens: event.inputTokens) else { return nil }
            return (Double(event.inputTokens) * price.input + Double(event.outputTokens) * price.output) / 1_000_000
        default:
            return nil
        }
    }

    static func tokenPrice(model: String, inputTokens: Int) -> TokenPrice? {
        switch model {
        // Claude Haiku 5.5 doubles past a 100K-token prompt.
        case _ where model.hasPrefix("claude-haiku-5-5"):
            return inputTokens > 100_000 ? TokenPrice(input: 0.50, output: 2.50) : TokenPrice(input: 0.10, output: 0.50)
        case _ where model.hasPrefix("claude-haiku-4-5"): return TokenPrice(input: 1, output: 5)
        case _ where model.hasPrefix("claude-sonnet-5-5"): return TokenPrice(input: 2, output: 10)
        case _ where model.hasPrefix("claude-opus-5-5"): return TokenPrice(input: 4, output: 20)
        case _ where model.contains("gpt-oss-120b"): return TokenPrice(input: 0.15, output: 0.60)
        case _ where model.contains("gpt-oss-20b"): return TokenPrice(input: 0.075, output: 0.30)
        case _ where model.contains("qwen3.8-27b"): return TokenPrice(input: 0.80, output: 4.00)
        default: return nil
        }
    }
}

/// Reads usage off the requests and responses of the paid APIs. Pure, so the metered
/// clients stay thin and every provider's shape is tested.
public enum UsageMeter {
    static let anthropicHost = "api.anthropic.com"
    static let groqHost = "api.groq.com"
    static let elevenLabsHost = "api.elevenlabs.io"

    /// A finished single-shot request (HTTPClient): Anthropic and Groq chat report tokens,
    /// Whisper reports the audio duration, Scribe word times. nil when the request is not
    /// to a paid API or did not succeed.
    public static func event(request: URLRequest, status: Int, body: Data, date: Date) -> UsageEvent? {
        guard status == 200, let url = request.url, let host = url.host() else { return nil }
        let path = url.path()
        switch host {
        case anthropicHost where path.hasSuffix("/v1/messages"):
            guard let response = try? JSONDecoder().decode(AnthropicMessage.self, from: body) else { return nil }
            return UsageEvent(provider: .anthropic, kind: .languageModel, model: response.model ?? requestModel(request) ?? "unknown",
                              date: date, inputTokens: response.usage?.allInput ?? 0, outputTokens: response.usage?.output_tokens ?? 0)
        case groqHost where path.hasSuffix("/chat/completions"):
            guard let response = try? JSONDecoder().decode(ChatCompletion.self, from: body) else { return nil }
            return UsageEvent(provider: .groq, kind: .languageModel, model: response.model ?? requestModel(request) ?? "unknown",
                              date: date, inputTokens: response.usage?.prompt_tokens ?? 0,
                              outputTokens: response.usage?.completion_tokens ?? 0)
        case groqHost where path.hasSuffix("/audio/transcriptions"):
            let duration = (try? JSONDecoder().decode(WhisperResponse.self, from: body))?.duration ?? 0
            return UsageEvent(provider: .groq, kind: .speechToText,
                              model: multipartField("model", in: request.httpBody) ?? OpenAITranscriber.defaultModel,
                              date: date, audioSeconds: duration)
        case elevenLabsHost where path.hasSuffix("/speech-to-text"):
            let seconds = (try? JSONDecoder().decode(ScribeResponse.self, from: body))?.lastWordEnd ?? 0
            return UsageEvent(provider: .elevenLabs, kind: .speechToText,
                              model: multipartField("model_id", in: request.httpBody) ?? ScribeTranscriber.defaultModel,
                              date: date, audioSeconds: seconds)
        default:
            return nil
        }
    }

    /// A streamed text-to-speech request bills the text it sends, known before any audio.
    public static func speechEvent(request: URLRequest, date: Date) -> UsageEvent? {
        guard let url = request.url, url.host() == elevenLabsHost, url.path().contains("/text-to-speech/"),
              let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String else { return nil }
        return UsageEvent(provider: .elevenLabs, kind: .textToSpeech, model: json["model_id"] as? String ?? "unknown",
                          date: date, characters: text.count)
    }

    public static func isAnthropicMessages(_ request: URLRequest) -> Bool {
        request.url?.host() == anthropicHost && request.url?.path().hasSuffix("/v1/messages") == true
    }

    /// The streaming text-to-speech WebSocket (follow-up answers): the model is in the URL.
    public static func speechSocketModel(_ request: URLRequest) -> String? {
        guard let url = request.url, url.host() == elevenLabsHost, url.path().hasSuffix("/stream-input") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "model_id" }?.value ?? "unknown"
    }

    /// The characters one WebSocket message asks to speak. The opening message's single
    /// space and the closing empty text are not speech.
    public static func speechSocketCharacters(_ message: String) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let text = json["text"] as? String, text != " " else { return 0 }
        return text.count
    }

    /// The `model` of a JSON request body.
    static func requestModel(_ request: URLRequest) -> String? {
        guard let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["model"] as? String
    }

    /// A text field of a multipart body. Only the head is searched: the fields come before
    /// the audio, which can be megabytes.
    static func multipartField(_ name: String, in body: Data?) -> String? {
        guard let body else { return nil }
        let head = String(decoding: body.prefix(4_096), as: UTF8.self)
        guard let range = head.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        let rest = head[range.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    // MARK: Response shapes

    struct AnthropicUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        var allInput: Int { (input_tokens ?? 0) + (cache_creation_input_tokens ?? 0) + (cache_read_input_tokens ?? 0) }
    }

    struct AnthropicMessage: Decodable {
        let model: String?
        let usage: AnthropicUsage?
    }

    struct ChatCompletion: Decodable {
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let model: String?
        let usage: Usage?
    }

    struct WhisperResponse: Decodable { let duration: Double? }

    /// Scribe has no duration field; the last word's end is the audio heard, near enough.
    struct ScribeResponse: Decodable {
        struct Word: Decodable { let end: Double? }
        struct Transcript: Decodable { let words: [Word]? }
        let words: [Word]?
        let transcripts: [Transcript]?
        var lastWordEnd: Double {
            let all = (words ?? []) + (transcripts ?? []).flatMap { $0.words ?? [] }
            return all.compactMap(\.end).max() ?? 0
        }
    }
}

/// Adds up a streamed Anthropic answer: `message_start` carries the model and input tokens,
/// `message_delta` the running output tokens. A stream cut short still bills what came.
public struct AnthropicStreamTally: Sendable {
    public private(set) var model: String?
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0

    public init() {}

    public mutating func read(_ line: String) {
        guard line.hasPrefix("data:"), line.contains("usage") else { return }
        let json = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        guard let event = try? JSONDecoder().decode(Event.self, from: json) else { return }
        if let message = event.message {
            model = message.model ?? model
            if let usage = message.usage {
                inputTokens = usage.allInput
                outputTokens = max(outputTokens, usage.output_tokens ?? 0)
            }
        }
        if let usage = event.usage { outputTokens = max(outputTokens, usage.output_tokens ?? 0) }
    }

    public func event(date: Date) -> UsageEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return UsageEvent(provider: .anthropic, kind: .languageModel, model: model ?? "unknown", date: date,
                          inputTokens: inputTokens, outputTokens: outputTokens)
    }

    private struct Event: Decodable {
        let message: UsageMeter.AnthropicMessage?
        let usage: UsageMeter.AnthropicUsage?
    }
}
