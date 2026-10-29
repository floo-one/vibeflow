import Foundation

/// Live ByteStreamClient on URLSession.bytes. Lines are split on newlines as they arrive.
public struct URLSessionByteStreamClient: ByteStreamClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func stream(_ request: URLRequest) async throws -> ByteStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ByteStreamResponse(status: status, lines: lines)
    }
}

/// Live WebSocketClient on URLSessionWebSocketTask.
public struct URLSessionWebSocketClient: WebSocketClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func connect(_ request: URLRequest) -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return Connection(task: task)
    }

    private final class Connection: WebSocketConnection, @unchecked Sendable {
        let task: URLSessionWebSocketTask
        init(task: URLSessionWebSocketTask) { self.task = task }

        func send(_ text: String) async throws { try await task.send(.string(text)) }

        func receive() async throws -> String? {
            do {
                switch try await task.receive() {
                case .string(let text): return text
                case .data(let data): return String(decoding: data, as: UTF8.self)
                @unknown default: return nil
                }
            } catch {
                // A normal close from the server ends the stream; anything else is a failure.
                if task.closeCode == .normalClosure { return nil }
                throw error
            }
        }

        func close() { task.cancel(with: .normalClosure, reason: nil) }
    }
}

/// Live HTTPClient on URLSession.data.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }
}
