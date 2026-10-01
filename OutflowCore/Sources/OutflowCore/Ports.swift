// The seven seams between OutflowCore and the outside world (design D3, D4, D10).
// The app target's LiveServices supplies the real implementations; OutflowCoreTests
// supplies in-memory fakes. Nothing in OutflowCore imports AppKit outside these seams.

import Foundation

// MARK: - Identity

/// Identifies one read from hotkey press to idle. Every provider callback carries the
/// session it belongs to and is dropped if it does not match the current one.
public struct SessionID: Hashable, Sendable {
    public let raw: UUID
    public init() { raw = UUID() }
}

/// The app that was frontmost when the hotkey fired (design D8). Frozen for the whole
/// session so an app switch during a wait cannot change the preset or the capture target.
public struct FrontmostApp: Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

// MARK: - 1. Pasteboard (D9, D10)

/// Plain-text view of the system pasteboard. Deliberately not main-actor bound: the
/// capture code calls it from a detached task with a 200 ms timeout because reading a
/// lazily provided pasteboard can block until the owning app answers.
public protocol Pasteboard: Sendable {
    /// Ownership-change counter. Incremented on every write by any app.
    var changeCount: Int { get }
    /// True when the pasteboard holds no items at all (nothing to restore).
    var isEmpty: Bool { get }
    /// The plain-text item, or nil when the pasteboard holds no text.
    func string() -> String?
    /// Writes plain text. `transient` marks the write so clipboard managers ignore it.
    func setString(_ text: String, transient: Bool)
}

// MARK: - 2. AccessibilityBridge (Capture step 1 to 3)

public enum AccessibilityError: Error, Equatable, Sendable {
    case notTrusted
    case noFocusedElement
    case copyMenuItemNotFound
    case pressFailed
}

@MainActor
public protocol AccessibilityBridge: AnyObject {
    /// AXIsProcessTrusted. Checked on every hotkey press, since a rebuild with a different
    /// signature silently drops the grant.
    var isTrusted: Bool { get }
    /// The frontmost application right now.
    func frontmostApp() -> FrontmostApp?
    /// kAXSelectedTextAttribute of the focused element, nil when absent or empty.
    func focusedSelectedText() throws -> String?
    /// Presses the app's Edit > Copy menu item through the Accessibility API.
    func pressCopyMenuItem(in app: FrontmostApp) throws
}

// MARK: - 3. SpeechProvider (Read flow, D11)

/// What to speak and how. Values come from the frozen AppPreset (T9).
public struct SpeechRequest: Sendable, Equatable {
    public var text: String
    public var voiceID: String
    /// Playback multiplier 0.7 ... 2.0. Each provider maps it to its own range.
    public var speed: Double
    /// BCP-47 language override, nil = let the provider detect.
    public var language: String?
    /// Apple voice per BCP-47 language from the frozen preset (ignored by ElevenLabs).
    public var appleVoiceByLanguage: [String: String]
    /// Resume support: speak starting at this character offset of `text`.
    public var startOffset: Int

    public init(text: String, voiceID: String, speed: Double = 1.0, language: String? = nil, appleVoiceByLanguage: [String: String] = [:], startOffset: Int = 0) {
        self.text = text
        self.voiceID = voiceID
        self.speed = speed
        self.language = language
        self.appleVoiceByLanguage = appleVoiceByLanguage
        self.startOffset = startOffset
    }
}

/// Progress events from a playback. Offsets are character offsets into the spoken text.
public enum SpeechEvent: Sendable, Equatable {
    /// First audio is audible.
    case started
    /// The last character that has been played so far.
    case progress(characterOffset: Int)
    /// A status-line note from the provider, e.g. "No German voice installed".
    case notice(String)
    /// Playback reached the end of the text.
    case finished
}

/// Why a playback failed. `lastPlayedOffset` lets the session resume with another provider.
public enum SpeechFailure: Error, Equatable, Sendable {
    /// 401: invalid key or quota exhausted. Stops the read with the Keys action.
    case unauthorized
    /// No first audio chunk within the timeout. Falls to Apple.
    case noFirstChunk
    /// A 200 that carried no audio. Falls to Apple.
    case emptyResponse
    /// The device has no route to the network. Falls to Apple, reason "offline".
    case offline
    /// The stream dropped after audio had started. Falls to Apple from the sentence containing the offset.
    case connectionLost(lastPlayedOffset: Int)
    /// Any other request or decode failure, with a short reason for the status line.
    case other(String)
}

/// One running playback. Created by a provider, owned by the session.
@MainActor
public protocol SpeechPlayback: AnyObject {
    /// Progress and completion. Finishes with `.finished` or throws a `SpeechFailure`.
    var events: AsyncThrowingStream<SpeechEvent, Error> { get }
    /// Stops audio and cancels any network work. Idempotent.
    func cancel()
}

@MainActor
public protocol SpeechProvider: AnyObject {
    /// Starts speaking immediately. Returns once the playback object exists, not when audio starts.
    func speak(_ request: SpeechRequest) -> any SpeechPlayback
}

// MARK: - 4. AudioPlayer (PCMStreamPlayer, used by the ElevenLabs provider)

@MainActor
public protocol AudioPlayer: AnyObject {
    /// Starts the engine so the first buffer plays without start-up cost.
    func prepare() throws
    /// Schedules 16-bit little-endian mono PCM at 24 kHz. Starts playing on the first call.
    func schedule(pcm16: Data)
    /// Playback rate above 1.0 applied with pitch preserved (the part of speed ElevenLabs cannot do).
    func setRate(_ rate: Double)
    /// Seconds of audio actually rendered since the last `stop()`.
    var playedSeconds: Double { get }
    var isPlaying: Bool { get }
    /// Resolves once every scheduled buffer has been rendered (or after `stop()`).
    func waitUntilDone() async
    /// Stops immediately and drops every scheduled buffer.
    func stop()
}

// MARK: - Network seam used by the cloud providers

public struct ByteStreamResponse: Sendable {
    public let status: Int
    /// Newline-delimited response body, one element per line.
    public let lines: AsyncThrowingStream<String, Error>
    public init(status: Int, lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.lines = lines
    }
}

/// URLSession.bytes behind a protocol so providers are tested without a network.
public protocol ByteStreamClient: Sendable {
    func stream(_ request: URLRequest) async throws -> ByteStreamResponse
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// URLSession.data behind a protocol, for single-shot JSON APIs (Anthropic Messages).
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

// MARK: - 5. SessionClock (timeouts and confirm windows)

/// The only time dependency OutflowCore has, so tests can advance time by hand.
public protocol SessionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousSessionClock: SessionClock {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

// MARK: - 6. SmartReadClient (D5, D12)

public enum SmartReadMode: String, Sendable, Codable, CaseIterable {
    case brief
    case cleanup
}

public struct SmartReadRequest: Sendable, Equatable {
    public var text: String
    public var mode: SmartReadMode
    /// BCP-47 language the answer must be in, nil = same as the source text.
    public var language: String?
    public var model: String
    public var maxTokens: Int
    /// Per-app guidance from the preset (trusted, user-authored), nil = none.
    public var instructions: String?

    public init(text: String, mode: SmartReadMode, language: String? = nil, model: String, maxTokens: Int, instructions: String? = nil) {
        self.text = text
        self.mode = mode
        self.language = language
        self.instructions = instructions
        self.model = model
        self.maxTokens = maxTokens
    }
}

public enum StopReason: Sendable, Equatable {
    case endTurn
    case maxTokens
    case other(String)
}

public struct SmartReadResponse: Sendable, Equatable {
    public var text: String
    public var stopReason: StopReason
    public init(text: String, stopReason: StopReason) {
        self.text = text
        self.stopReason = stopReason
    }
}

public enum SmartReadFailure: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited
    case overloaded
    case offline
    case timeout
    case other(String)
}

public protocol SmartReadClient: Sendable {
    func transform(_ request: SmartReadRequest) async throws -> SmartReadResponse
}

// MARK: - 7. SecretsStore (D5 keys in Keychain, cached in memory by the app)

public enum SecretKey: String, Sendable, CaseIterable {
    case elevenLabs = "elevenlabs-api-key"
    case anthropic = "anthropic-api-key"
}

public protocol SecretsStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}
