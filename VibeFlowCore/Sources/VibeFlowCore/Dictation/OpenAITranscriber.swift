import Foundation

/// OpenAI-compatible speech-to-text (POST {base}/audio/transcriptions, multipart). Groq is the
/// default endpoint; a custom base URL serves local servers and other providers.
/// T1 spike: whisper-large-v3 is the default model (more accurate than turbo on Florian's
/// voice for about 100 ms more); Groq rejects a `service_tier` field, so none is sent.
public final class OpenAITranscriber: Transcriber {
    public static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    public static let defaultModel = "whisper-large-v3"
    /// Dictation: a clip of up to 2 minutes.
    public static let timeout: TimeInterval = 10
    /// File transcription: a 10-minute, 19.2 MB piece (design D5).
    public static let fileTimeout: TimeInterval = 60

    private let http: any HTTPClient
    private let baseURL: URL
    private let model: String
    private let apiKey: @Sendable () -> String?
    /// Custom endpoints may run without a key (local servers); Groq always needs one.
    private let keyRequired: Bool
    private let requestTimeout: TimeInterval

    public init(http: any HTTPClient, baseURL: URL = OpenAITranscriber.groqBaseURL, model: String = OpenAITranscriber.defaultModel,
                keyRequired: Bool = true, timeout: TimeInterval = OpenAITranscriber.timeout,
                apiKey: @escaping @Sendable () -> String?) {
        self.http = http
        self.baseURL = baseURL
        self.model = model
        self.keyRequired = keyRequired
        self.requestTimeout = timeout
        self.apiKey = apiKey
    }

    public func transcribe(_ audio: RecordedAudio, language: String?) async throws -> Transcription {
        let body = try await verboseJSON(audio, language: language)
        guard let decoded = try? JSONDecoder().decode(VerboseJSON.self, from: body) else {
            throw TranscriptionFailure.malformed
        }
        return Transcription(text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
                             noSpeechProbabilities: decoded.segments?.compactMap(\.no_speech_prob) ?? [])
    }

    /// File transcription (design D5): every segment with its times (relative to `audio`), text
    /// and no-speech probability, so the job can offset times by the piece's start and drop
    /// silent segments. Same request, same failure mapping as `transcribe`.
    public func transcribeSegments(_ audio: RecordedAudio, language: String?) async throws -> [WhisperSegment] {
        let body = try await verboseJSON(audio, language: language)
        guard let decoded = try? JSONDecoder().decode(VerboseJSON.self, from: body) else {
            throw TranscriptionFailure.malformed
        }
        return (decoded.segments ?? []).map {
            WhisperSegment(start: $0.start ?? 0, end: $0.end ?? 0,
                           text: ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           noSpeechProbability: $0.no_speech_prob ?? 0)
        }
    }

    /// Sends the request and returns the 200 body; every other outcome becomes a TranscriptionFailure.
    private func verboseJSON(_ audio: RecordedAudio, language: String?) async throws -> Data {
        let key = apiKey()
        if keyRequired && key == nil { throw TranscriptionFailure.unauthorized }
        let request = Self.buildRequest(audio: audio, language: language, model: model, baseURL: baseURL, apiKey: key,
                                        timeout: requestTimeout)

        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TranscriptionFailure.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw TranscriptionFailure.offline
            default: throw TranscriptionFailure.offline
            }
        }

        switch response.status {
        case 200:
            return response.body
        case 401, 403:
            throw TranscriptionFailure.unauthorized
        case 429:
            throw TranscriptionFailure.rateLimited
        case 500...599:
            throw TranscriptionFailure.serverError(response.status)
        default:
            let json = Self.jsonMessage(from: response.body)
            throw TranscriptionFailure.rejected(status: response.status, message: json ?? Self.message(from: response.body),
                                                rawBodyBytes: json == nil ? response.body.count : nil)
        }
    }

    static func buildRequest(audio: RecordedAudio, language: String?, model: String, baseURL: URL, apiKey: String?,
                             timeout: TimeInterval = OpenAITranscriber.timeout) -> URLRequest {
        let boundary = "vibeflow-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if let code = language.flatMap(isoLanguage) { field("language", code) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio.wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    /// Whisper takes ISO 639-1 codes ("de" from "de-DE").
    static func isoLanguage(_ bcp47: String) -> String? {
        guard let primary = bcp47.split(separator: "-").first, primary.count == 2 || primary.count == 3 else { return nil }
        return primary.lowercased()
    }

    static func message(from body: Data) -> String {
        jsonMessage(from: body) ?? String(decoding: body.prefix(200), as: UTF8.self)
    }

    /// The provider's own `error.message`, nil when the body is not that JSON.
    static func jsonMessage(from body: Data) -> String? {
        struct E: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        return (try? JSONDecoder().decode(E.self, from: body))?.error?.message
    }

    private struct VerboseJSON: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
            let no_speech_prob: Double?
        }
        let text: String
        let segments: [Segment]?
    }
}
