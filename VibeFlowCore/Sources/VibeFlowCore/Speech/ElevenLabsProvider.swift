import Foundation

/// ElevenLabs Flash v2.5 over the stream/with-timestamps endpoint with pcm_24000 output
/// (design: Read flow, D11, D14; T1 spike proved the shape). One request per selection.
///
/// Response: newline-delimited JSON, each line `{audio_base64, alignment, normalized_alignment}`.
/// Audio goes straight to the AudioPlayer; `alignment` (original characters) gives the
/// timing used to report the last played character when the stream drops.
@MainActor
public final class ElevenLabsProvider: SpeechProvider {
    public static let defaultModel = ModelOptions.voice[0].id
    public static let outputFormat = "pcm_24000"
    /// voice_settings.speed range on Flash v2.5, verified by live probe (HTTP 400 outside it).
    public static let speedRange = 0.7...1.2

    private let client: any ByteStreamClient
    private let webSocket: any WebSocketClient
    private let player: any AudioPlayer
    private let secrets: any SecretsStore
    private let baseURL: URL
    /// The ElevenLabs model for the next read (Settings > Read).
    public var model = ElevenLabsProvider.defaultModel

    public init(client: any ByteStreamClient, webSocket: any WebSocketClient = URLSessionWebSocketClient(),
                player: any AudioPlayer, secrets: any SecretsStore,
                baseURL: URL = URL(string: "https://api.elevenlabs.io")!) {
        self.client = client
        self.webSocket = webSocket
        self.player = player
        self.secrets = secrets
        self.baseURL = baseURL
    }

    public func speak(_ request: SpeechRequest) -> any SpeechPlayback {
        let playback = ElevenLabsPlayback(player: player)
        guard let key = secrets.read(.elevenLabs) else {
            playback.fail(.unauthorized)
            return playback
        }
        let urlRequest = Self.buildRequest(request, apiKey: key, baseURL: baseURL, model: model)
        let clampedSpeed = min(max(request.speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        let remainder = request.speed > Self.speedRange.upperBound ? request.speed / Self.speedRange.upperBound : 1.0
        playback.start(urlRequest: urlRequest, client: client, startOffset: request.startOffset, playerRate: remainder, apiSpeed: clampedSpeed)
        return playback
    }

    // MARK: Request building (pure, tested)

    static func buildRequest(_ request: SpeechRequest, apiKey: String, baseURL: URL, model: String = defaultModel) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/text-to-speech/\(request.voiceID)/stream/with-timestamps"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 30

        let speed = min(max(request.speed, speedRange.lowerBound), speedRange.upperBound)
        var body: [String: Any] = [
            "text": Sentences.suffix(of: request.text, from: request.startOffset),
            "model_id": model,
            "voice_settings": ["speed": speed, "stability": 0.5, "similarity_boost": 0.75],
        ]
        if let code = ElevenLabsLanguage.code(for: request.language) {
            body["language_code"] = code
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }
}

/// languageOverride is BCP-47 (de-DE); ElevenLabs wants ISO 639-1 (de) and only for
/// languages Flash v2.5 supports. Anything else is omitted so the model detects (D14).
public enum ElevenLabsLanguage {
    public static let flashV25Supported: Set<String> = [
        "en", "ja", "zh", "de", "hi", "fr", "ko", "pt", "it", "es", "id", "nl", "tr", "fil", "pl", "sv",
        "bg", "ro", "ar", "cs", "el", "fi", "hr", "ms", "sk", "da", "ta", "uk", "ru", "hu", "no", "vi",
    ]

    public static func code(for bcp47: String?) -> String? {
        guard let bcp47, let primary = bcp47.split(separator: "-").first else { return nil }
        let code = primary.lowercased()
        return flashV25Supported.contains(code) ? code : nil
    }
}

// MARK: - Streaming text input (follow-up answers)

extension ElevenLabsProvider: StreamingSpeechProvider {
    /// Characters ElevenLabs waits for before generating each chunk: small first, so the
    /// voice starts on the first sentence, larger later for steadier prosody.
    public static let chunkSchedule = [50, 90, 120, 150]

    public func beginStream(_ request: SpeechRequest) -> any StreamingSpeech {
        let playback = ElevenLabsTextStream(player: player)
        guard let key = secrets.read(.elevenLabs) else {
            playback.fail(.unauthorized)
            return playback
        }
        let remainder = request.speed > Self.speedRange.upperBound ? request.speed / Self.speedRange.upperBound : 1.0
        playback.start(connection: webSocket.connect(Self.buildStreamRequest(request, apiKey: key, baseURL: baseURL, model: model)),
                       initMessage: Self.streamInitMessage(request), playerRate: remainder)
        return playback
    }

    static func buildStreamRequest(_ request: SpeechRequest, apiKey: String, baseURL: URL, model: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/text-to-speech/\(request.voiceID)/stream-input"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.queryItems = [URLQueryItem(name: "model_id", value: model), URLQueryItem(name: "output_format", value: outputFormat)]
        var req = URLRequest(url: components.url!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return req
    }

    static func streamInitMessage(_ request: SpeechRequest) -> String {
        let speed = min(max(request.speed, speedRange.lowerBound), speedRange.upperBound)
        return json([
            "text": " ",
            "voice_settings": ["speed": speed, "stability": 0.5, "similarity_boost": 0.75],
            "generation_config": ["chunk_length_schedule": chunkSchedule],
        ])
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class ElevenLabsTextStream: StreamingSpeech {
    let events: AsyncThrowingStream<SpeechEvent, Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private let player: any AudioPlayer
    /// Outgoing messages in order; the sender drains it.
    private let outgoing: AsyncStream<String>
    private let outgoingContinuation: AsyncStream<String>.Continuation
    private var connection: (any WebSocketConnection)?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var cancelled = false
    private var receivedAudio = false
    /// Characters whose audio has arrived, from `alignment`, for resuming with Apple.
    private var alignedCharacters = 0

    init(player: any AudioPlayer) {
        self.player = player
        var c: AsyncThrowingStream<SpeechEvent, Error>.Continuation!
        events = AsyncThrowingStream { c = $0 }
        continuation = c
        var o: AsyncStream<String>.Continuation!
        outgoing = AsyncStream { o = $0 }
        outgoingContinuation = o
    }

    func fail(_ failure: SpeechFailure) {
        outgoingContinuation.finish()
        continuation.finish(throwing: failure)
    }

    func start(connection: any WebSocketConnection, initMessage: String, playerRate: Double) {
        self.connection = connection
        do {
            try player.prepare()
            player.setRate(playerRate)
        } catch {
            fail(.other("audio output: \(error.localizedDescription)"))
            return
        }
        outgoingContinuation.yield(initMessage)
        let outgoing = outgoing
        sender = Task { [weak self] in
            for await message in outgoing {
                do { try await connection.send(message) } catch {
                    self?.failed(error)
                    return
                }
            }
        }
        receiver = Task { [weak self] in
            do {
                while let message = try await connection.receive() {
                    guard let self, !self.cancelled else { return }
                    if try self.handle(message) { break }
                }
                guard let self, !self.cancelled else { return }
                guard self.receivedAudio else { throw SpeechFailure.emptyResponse }
                await self.player.waitUntilDone()
                guard !self.cancelled else { return }
                self.continuation.yield(.finished)
                self.continuation.finish()
                connection.close()
            } catch {
                self?.failed(error)
            }
        }
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        outgoingContinuation.yield(ElevenLabsProvider.json(["text": text]))
    }

    func finishText() {
        // An empty text closes the input; ElevenLabs speaks what is buffered and ends with isFinal.
        outgoingContinuation.yield(ElevenLabsProvider.json(["text": ""]))
        outgoingContinuation.finish()
    }

    /// Returns true on the final message.
    private func handle(_ message: String) throws -> Bool {
        let parsed = try JSONDecoder().decode(Message.self, from: Data(message.utf8))
        if let b64 = parsed.audio, let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
            player.schedule(pcm16: pcm)
            if !receivedAudio {
                receivedAudio = true
                continuation.yield(.started)
            }
        }
        if let chars = parsed.alignment?.chars {
            alignedCharacters += chars.count
            continuation.yield(.progress(characterOffset: alignedCharacters))
        }
        if parsed.isFinal == true { return true }
        if !receivedAudio, let error = parsed.error ?? parsed.message {
            let lowered = error.lowercased()
            throw lowered.contains("api key") || lowered.contains("api_key") || lowered.contains("unauthorized")
                ? SpeechFailure.unauthorized : SpeechFailure.other(error)
        }
        return false
    }

    private func failed(_ error: Error) {
        guard !cancelled else { return }
        cancelled = true
        sender?.cancel()
        receiver?.cancel()
        connection?.close()
        outgoingContinuation.finish()
        let failure: SpeechFailure
        if let speech = error as? SpeechFailure {
            failure = speech
        } else if receivedAudio {
            failure = .connectionLost(lastPlayedOffset: alignedCharacters)
        } else if let url = error as? URLError,
                  [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(url.code) {
            failure = .offline
        } else {
            failure = .other(error.localizedDescription)
        }
        player.stop()
        continuation.finish(throwing: failure)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        sender?.cancel()
        receiver?.cancel()
        connection?.close()
        outgoingContinuation.finish()
        player.stop()
        continuation.finish()
    }

    private struct Message: Decodable {
        struct Alignment: Decodable { let chars: [String]? }
        let audio: String?
        let isFinal: Bool?
        let alignment: Alignment?
        let error: String?
        let message: String?
    }
}

// MARK: - Playback

@MainActor
final class ElevenLabsPlayback: SpeechPlayback {
    let events: AsyncThrowingStream<SpeechEvent, Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private let player: any AudioPlayer
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// Start times (seconds into the audio) per character of the spoken suffix, from `alignment`.
    private var characterStarts: [Double] = []
    private var receivedAudio = false

    init(player: any AudioPlayer) {
        self.player = player
        var c: AsyncThrowingStream<SpeechEvent, Error>.Continuation!
        events = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func fail(_ failure: SpeechFailure) {
        continuation.finish(throwing: failure)
    }

    func start(urlRequest: URLRequest, client: any ByteStreamClient, startOffset: Int, playerRate: Double, apiSpeed: Double) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.player.prepare()
                self.player.setRate(playerRate)
                let response = try await client.stream(urlRequest)
                guard !self.cancelled else { return }
                switch response.status {
                case 200: break
                case 401: throw SpeechFailure.unauthorized
                default: throw SpeechFailure.other("HTTP \(response.status)")
                }
                let decoder = JSONDecoder()
                for try await line in response.lines {
                    guard !self.cancelled else { return }
                    guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                    let parsed = try decoder.decode(StreamLine.self, from: data)
                    if let b64 = parsed.audio_base64, let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                        self.player.schedule(pcm16: pcm)
                        if !self.receivedAudio {
                            self.receivedAudio = true
                            self.continuation.yield(.started)
                        }
                    }
                    if let alignment = parsed.alignment {
                        self.characterStarts.append(contentsOf: alignment.character_start_times_seconds)
                        self.continuation.yield(.progress(characterOffset: startOffset + self.characterStarts.count))
                    }
                }
                guard !self.cancelled else { return }
                guard self.receivedAudio else { throw SpeechFailure.emptyResponse }
                await self.player.waitUntilDone()
                guard !self.cancelled else { return }
                self.continuation.yield(.finished)
                self.continuation.finish()
            } catch {
                guard !self.cancelled else { return }
                self.continuation.finish(throwing: self.mapError(error, startOffset: startOffset))
            }
        }
    }

    private func mapError(_ error: Error, startOffset: Int) -> SpeechFailure {
        if let failure = error as? SpeechFailure { return failure }
        if receivedAudio {
            return .connectionLost(lastPlayedOffset: startOffset + lastPlayedCharacter())
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default:
                return .other(urlError.localizedDescription)
            }
        }
        if error is DecodingError { return .other("malformed response") }
        return .other(String(describing: error))
    }

    /// Index of the last character whose audio has started playing, from alignment timings.
    private func lastPlayedCharacter() -> Int {
        let played = player.playedSeconds
        var index = 0
        for (i, start) in characterStarts.enumerated() where start <= played { index = i }
        return index
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        task?.cancel()
        player.stop()
        continuation.finish()
    }

    private struct Alignment: Decodable {
        let characters: [String]
        let character_start_times_seconds: [Double]
        let character_end_times_seconds: [Double]
    }

    private struct StreamLine: Decodable {
        let audio_base64: String?
        let alignment: Alignment?
    }
}
