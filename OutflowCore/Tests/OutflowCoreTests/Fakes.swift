// In-memory implementations of the seven ports. Every OutflowCore test runs against these;
// none of them touch AppKit, the network, the Keychain or a real clock.

import Foundation
@testable import OutflowCore

// MARK: - 1. Pasteboard

final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    /// True when the pasteboard holds a non-text item (image, file) instead of text.
    private var nonText: Bool
    private(set) var changeCountValue = 0
    private(set) var writes: [(text: String, transient: Bool)] = []
    /// Simulates a lazy provider: every read blocks this long.
    var readDelay: Duration = .zero

    init(text: String? = nil, nonText: Bool = false) {
        self.text = text
        self.nonText = nonText
    }

    var changeCount: Int { lock.withLock { changeCountValue } }
    var isEmpty: Bool { lock.withLock { text == nil && !nonText } }

    func string() -> String? {
        if readDelay > .zero { Thread.sleep(forTimeInterval: Double(readDelay.components.seconds) + Double(readDelay.components.attoseconds) / 1e18) }
        return lock.withLock { text }
    }

    func setString(_ text: String, transient: Bool) {
        lock.withLock {
            self.text = text
            changeCountValue += 1
            writes.append((text, transient))
        }
    }

    /// Another app writes the pasteboard.
    func externalWrite(_ text: String) {
        lock.withLock {
            self.text = text
            changeCountValue += 1
        }
    }
}

// MARK: - 2. AccessibilityBridge

@MainActor
final class FakeAccessibility: AccessibilityBridge {
    var isTrusted = true
    var frontmost: FrontmostApp? = FrontmostApp(pid: 100, bundleID: "com.apple.Safari")
    var selectedText: String?
    var selectedTextError: AccessibilityError?
    var copyError: AccessibilityError?
    /// What the Copy press puts on the pasteboard, nil = the app does nothing.
    var copyProduces: String?
    /// When set with `clock`, the app writes the pasteboard only after this delay.
    var copyDelay: Duration = .zero
    var clock: FakeClock?
    var pasteboard: FakePasteboard?
    private(set) var copyPresses: [FrontmostApp] = []

    func frontmostApp() -> FrontmostApp? { frontmost }

    func focusedSelectedText() throws -> String? {
        if let e = selectedTextError { throw e }
        return selectedText
    }

    func pressCopyMenuItem(in app: FrontmostApp) throws {
        if let e = copyError { throw e }
        copyPresses.append(app)
        guard let produced = copyProduces else { return }
        if copyDelay > .zero, let clock, let pasteboard {
            Task {
                try? await clock.sleep(for: copyDelay)
                pasteboard.externalWrite(produced)
            }
        } else {
            pasteboard?.externalWrite(produced)
        }
    }
}

// MARK: - 3. SpeechProvider

@MainActor
final class FakePlayback: SpeechPlayback {
    let events: AsyncThrowingStream<SpeechEvent, Error>
    private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    private(set) var cancelCount = 0

    init() {
        var c: AsyncThrowingStream<SpeechEvent, Error>.Continuation!
        events = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func emit(_ event: SpeechEvent) { continuation.yield(event) }
    func fail(_ failure: SpeechFailure) { continuation.finish(throwing: failure) }
    func finish() { continuation.yield(.finished); continuation.finish() }
    func cancel() { cancelCount += 1; continuation.finish() }
}

@MainActor
final class FakeSpeechProvider: SpeechProvider {
    private(set) var requests: [SpeechRequest] = []
    private(set) var playbacks: [FakePlayback] = []

    func speak(_ request: SpeechRequest) -> any SpeechPlayback {
        requests.append(request)
        let p = FakePlayback()
        playbacks.append(p)
        return p
    }

    var last: FakePlayback? { playbacks.last }
}

// MARK: - 4. AudioPlayer

@MainActor
final class FakeAudioPlayer: AudioPlayer {
    private(set) var prepared = false
    private(set) var scheduled: [Data] = []
    private(set) var rates: [Double] = []
    private(set) var stopCount = 0
    var playedSeconds: Double = 0
    private(set) var isPlaying = false

    func prepare() throws { prepared = true }
    func schedule(pcm16: Data) { scheduled.append(pcm16); isPlaying = true }
    func setRate(_ rate: Double) { rates.append(rate) }
    func waitUntilDone() async { isPlaying = false }
    func stop() { stopCount += 1; isPlaying = false; scheduled.removeAll() }
}

// MARK: - ByteStreamClient

/// Scripted HTTP line stream. `error` is thrown after `linesBeforeError` lines (nil = never).
final class FakeByteStreamClient: ByteStreamClient, @unchecked Sendable {
    private let lock = NSLock()
    var status = 200
    var lines: [String] = []
    var error: Error?
    var linesBeforeError = Int.max
    /// Thrown from `stream` itself, before any response (e.g. URLError offline).
    var connectError: Error?
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }

    func stream(_ request: URLRequest) async throws -> ByteStreamResponse {
        lock.withLock { _requests.append(request) }
        if let connectError { throw connectError }
        let lines = self.lines, error = self.error, cutoff = self.linesBeforeError
        return ByteStreamResponse(status: status, lines: AsyncThrowingStream { continuation in
            for (i, line) in lines.enumerated() {
                if i >= cutoff, let error { continuation.finish(throwing: error); return }
                continuation.yield(line)
            }
            if let error, lines.count <= cutoff { continuation.finish(throwing: error) } else { continuation.finish() }
        })
    }
}

// MARK: - 5. SessionClock

/// Time only moves when a test calls `advance`. Sleepers whose deadline has passed resume.
final class FakeClock: SessionClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: Duration = .zero
    private var sleepers: [Sleeper] = []

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                let deadline = now + duration
                if deadline <= now {
                    lock.unlock()
                    c.resume()
                } else if Task.isCancelled {
                    // Cancelled between the check above and registration: never park a
                    // continuation nothing will wake.
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    lock.unlock()
                }
            }
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: i)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            now += duration
            let ready = sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= now }
            return ready
        }
        for s in due { s.continuation.resume() }
    }
}

// MARK: - HTTPClient

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var status = 200
    var body = Data()
    var connectError: Error?
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        if let connectError { throw connectError }
        return HTTPResponse(status: status, body: body)
    }
}

// MARK: - 6. SmartReadClient

final class FakeSmartReadClient: SmartReadClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SmartReadRequest] = []
    var requests: [SmartReadRequest] { lock.withLock { _requests } }
    /// Scripted outcome for the next call.
    var result: Result<SmartReadResponse, SmartReadFailure> = .success(SmartReadResponse(text: "brief", stopReason: .endTurn))
    /// If set, the call suspends until this clock passes the delay (for timeout tests).
    var delay: Duration = .zero
    var clock: FakeClock?

    func transform(_ request: SmartReadRequest) async throws -> SmartReadResponse {
        lock.withLock { _requests.append(request) }
        if delay > .zero, let clock { try await clock.sleep(for: delay) }
        return try result.get()
    }
}

// MARK: - 7. SecretsStore

final class FakeSecrets: SecretsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String]
    var failWrites = false

    init(_ values: [SecretKey: String] = [:]) { self.values = values }

    func read(_ key: SecretKey) -> String? { lock.withLock { values[key] } }
    func write(_ value: String, for key: SecretKey) throws {
        if failWrites { throw NSError(domain: "FakeSecrets", code: 1) }
        lock.withLock { values[key] = value }
    }
    func delete(_ key: SecretKey) throws { lock.withLock { values[key] = nil } }
}
