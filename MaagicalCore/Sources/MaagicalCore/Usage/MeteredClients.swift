import Foundation
import os

/// The live network clients with a meter in front: every successful request to a paid API
/// becomes a UsageEvent (UsageMeter). One wrapper per client kind, applied once in the app
/// container, so no feature has to remember to count.
public struct MeteredHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let record: @Sendable (UsageEvent) -> Void

    public init(_ base: any HTTPClient, record: @escaping @Sendable (UsageEvent) -> Void) {
        self.base = base
        self.record = record
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await base.send(request)
        if let event = UsageMeter.event(request: request, status: response.status, body: response.body, date: Date()) { record(event) }
        return response
    }

    /// Scribe uploads its multipart body from a file; only the head is read, for the model.
    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> HTTPResponse {
        let response = try await base.upload(request, fromFile: file)
        var metered = request
        if response.status == 200, let handle = try? FileHandle(forReadingFrom: file) {
            metered.httpBody = try? handle.read(upToCount: 4_096)
            try? handle.close()
        }
        if let event = UsageMeter.event(request: metered, status: response.status, body: response.body, date: Date()) { record(event) }
        return response
    }
}

/// Streams: text to speech is billed from the request; a streamed Claude answer is added up
/// line by line and recorded when the stream ends, also when it is cancelled.
public struct MeteredByteStreamClient: ByteStreamClient {
    private let base: any ByteStreamClient
    private let record: @Sendable (UsageEvent) -> Void

    public init(_ base: any ByteStreamClient, record: @escaping @Sendable (UsageEvent) -> Void) {
        self.base = base
        self.record = record
    }

    public func stream(_ request: URLRequest) async throws -> ByteStreamResponse {
        let response = try await base.stream(request)
        guard response.status == 200 else { return response }
        if let event = UsageMeter.speechEvent(request: request, date: Date()) {
            record(event)
            return response
        }
        guard UsageMeter.isAnthropicMessages(request) else { return response }
        let record = self.record
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var tally = AnthropicStreamTally()
                defer { if let event = tally.event(date: Date()) { record(event) } }
                do {
                    for try await line in response.lines {
                        tally.read(line)
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ByteStreamResponse(status: response.status, lines: lines)
    }
}

/// The text-to-speech WebSocket (follow-up answers): counts the characters sent and records
/// them once, when the connection ends.
public struct MeteredWebSocketClient: WebSocketClient {
    private let base: any WebSocketClient
    private let record: @Sendable (UsageEvent) -> Void

    public init(_ base: any WebSocketClient, record: @escaping @Sendable (UsageEvent) -> Void) {
        self.base = base
        self.record = record
    }

    public func connect(_ request: URLRequest) -> any WebSocketConnection {
        let connection = base.connect(request)
        guard let model = UsageMeter.speechSocketModel(request) else { return connection }
        return Connection(base: connection, model: model, record: record)
    }

    private final class Connection: WebSocketConnection {
        let base: any WebSocketConnection
        let model: String
        let record: @Sendable (UsageEvent) -> Void
        /// Characters sent; nil once recorded.
        let characters = OSAllocatedUnfairLock<Int?>(initialState: 0)

        init(base: any WebSocketConnection, model: String, record: @escaping @Sendable (UsageEvent) -> Void) {
            self.base = base
            self.model = model
            self.record = record
        }

        func send(_ text: String) async throws {
            try await base.send(text)
            let count = UsageMeter.speechSocketCharacters(text)
            characters.withLock { if let sent = $0 { $0 = sent + count } }
        }

        func receive() async throws -> String? {
            do {
                let message = try await base.receive()
                if message == nil { flush() }
                return message
            } catch {
                flush()
                throw error
            }
        }

        func close() {
            base.close()
            flush()
        }

        private func flush() {
            let sent = characters.withLock { value -> Int? in
                defer { value = nil }
                return value
            }
            guard let sent, sent > 0 else { return }
            record(UsageEvent(provider: .elevenLabs, kind: .textToSpeech, model: model, date: Date(), characters: sent))
        }
    }
}
