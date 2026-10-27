import Foundation
import Observation

// MARK: - Public surface

public enum ReadKind: Sendable, Equatable {
    case read
    case smartRead
}

public enum ReadOrigin: Sendable, Equatable {
    case hotkey
    case menu
    /// Shift + the read shortcut: reads the clipboard; pressing it again confirms a long text.
    case clipboardHotkey
}

/// The working states. Error and warning are display states over `idle` (see `iconState`).
public enum SessionState: Sendable, Equatable {
    case idle
    case awaitingConfirm(kind: ReadKind, origin: ReadOrigin, characters: Int)
    case capturing
    case transforming
    case buffering
    case speaking
}

public enum IconState: Sendable, Equatable {
    case idle
    case speaking
    case transforming
    case awaitingConfirm
    case warning
    case error
}

public enum ErrorAction: Sendable, Equatable {
    case openKeys
    case readOriginal
    case grantAccessibility
}

/// Persists in the menu until the next successful read (R2-10). Up to two actions (R3-6).
public struct LastError: Sendable, Equatable {
    public var message: String
    public var actions: [ErrorAction]
    public init(message: String, actions: [ErrorAction] = []) {
        self.message = message
        self.actions = actions
    }
}

// MARK: - ReadSession

/// One read from hotkey press to idle, with every rule from the design's Hotkey x state
/// table, provider selection, size guard, smart read flow and mid-stream resume.
/// Main-actor bound (D3); every provider callback is checked against the current
/// (sessionID, attempt) token and dropped on mismatch (D11).
@MainActor
@Observable
public final class ReadSession {
    // Observable outputs
    public private(set) var state: SessionState = .idle
    public private(set) var status: String = "Ready"
    public private(set) var lastError: LastError?
    public private(set) var accessibilityTrusted: Bool
    /// True while the status line carries a notice ("Using Apple voice", "Smart read disabled",
    /// "Continued with Apple voice") that progress updates must not overwrite.
    private var stickyStatus = false

    public var iconState: IconState {
        switch state {
        case .idle:
            if !accessibilityTrusted { return .warning }
            return lastError == nil ? .idle : .error
        case .awaitingConfirm: return .awaitingConfirm
        case .capturing, .buffering: return .idle
        case .transforming: return .transforming
        case .speaking: return .speaking
        }
    }

    /// The last captured text and its frozen preset, kept so "Read original instead" can
    /// replay it after a failed smart read without re-capturing (R2-10).
    public private(set) var storedOriginal: (text: String, preset: AppPreset)?

    // Dependencies
    private let accessibility: any AccessibilityBridge
    private let capture: any SelectionCapturing
    private let presets: any PresetResolving
    private let elevenLabs: any SpeechProvider
    private let apple: any SpeechProvider
    private let smartRead: any SmartReadClient
    private let secrets: any SecretsStore
    private let clock: any SessionClock
    public var configuration: SessionConfiguration

    public init(
        accessibility: any AccessibilityBridge,
        capture: any SelectionCapturing,
        presets: any PresetResolving,
        elevenLabs: any SpeechProvider,
        apple: any SpeechProvider,
        smartRead: any SmartReadClient,
        secrets: any SecretsStore,
        clock: any SessionClock,
        configuration: SessionConfiguration = SessionConfiguration()
    ) {
        self.accessibility = accessibility
        self.capture = capture
        self.presets = presets
        self.elevenLabs = elevenLabs
        self.apple = apple
        self.smartRead = smartRead
        self.secrets = secrets
        self.clock = clock
        self.configuration = configuration
        self.accessibilityTrusted = accessibility.isTrusted
    }

    // MARK: Current session bookkeeping

    private struct Token: Equatable {
        let id: SessionID
        let attempt: Int
    }

    private final class Current {
        let id = SessionID()
        var attempt = 0
        let kind: ReadKind
        let origin: ReadOrigin
        let app: FrontmostApp?
        let preset: AppPreset
        var text: String?
        var spokenText: String?
        var usingApple = false
        var task: Task<Void, Never>?
        var playback: (any SpeechPlayback)?
        var watchdog: Task<Void, Never>?
        var confirmExpiry: Task<Void, Never>?

        init(kind: ReadKind, origin: ReadOrigin, app: FrontmostApp?, preset: AppPreset) {
            self.kind = kind
            self.origin = origin
            self.app = app
            self.preset = preset
        }

        var token: Token { Token(id: id, attempt: attempt) }
    }

    private var current: Current?

    private func isCurrent(_ token: Token) -> Bool {
        current?.token == token
    }

    // MARK: Inputs

    /// The global shortcut for `kind` was pressed. Implements the Hotkey x state table.
    public func hotkey(_ kind: ReadKind) {
        accessibilityTrusted = accessibility.isTrusted

        switch state {
        case .idle:
            start(kind: kind, origin: .hotkey)
        case .awaitingConfirm(let pendingKind, let origin, _):
            if origin == .hotkey && pendingKind == kind {
                confirm()
            } else {
                cancel(status: "Cancelled")
            }
        case .capturing, .transforming, .buffering, .speaking:
            cancel(status: "Stopped")
        }
    }

    /// Menu items "Speak clipboard" and "Smart read clipboard". Uses the global default preset.
    /// Shift + read or smart read shortcut: speak the clipboard with the default preset.
    /// Idle: start. Waiting to confirm this same clipboard read: confirm. Otherwise: stop.
    public func clipboardHotkey(_ kind: ReadKind, text: String) {
        if case .awaitingConfirm(let pendingKind, .clipboardHotkey, _) = state, pendingKind == kind {
            confirm()
            return
        }
        guard state == .idle else { cancel(status: "Stopped"); return }
        startClipboardRead(kind, text: text, origin: .clipboardHotkey)
    }

    public func menuRead(_ kind: ReadKind, text: String) {
        guard state == .idle else { cancel(status: "Stopped"); return }
        startClipboardRead(kind, text: text, origin: .menu)
    }

    private func startClipboardRead(_ kind: ReadKind, text: String, origin: ReadOrigin) {
        accessibilityTrusted = accessibility.isTrusted
        lastError = nil
        stickyStatus = false
        let preset = presets.preset(for: nil)
        let session = Current(kind: kind, origin: origin, app: nil, preset: preset)
        current = session
        proceedAfterCapture(session, text: text, note: nil)
    }

    /// Menu item "Read anyway", shown while a menu read awaits confirmation.
    public func readAnyway() {
        guard case .awaitingConfirm(_, .menu, _) = state else { return }
        confirm()
    }

    /// Menu item "Stop".
    public func stop() {
        guard state != .idle else { return }
        cancel(status: "Stopped")
    }

    /// Menu action "Read original instead": plain read of the stored text with its frozen preset.
    public func readOriginal() {
        guard state == .idle, let stored = storedOriginal else { return }
        lastError = nil
        stickyStatus = false
        let session = Current(kind: .read, origin: .menu, app: nil, preset: stored.preset)
        current = session
        session.text = stored.text
        speak(stored.text, session: session)
    }

    // MARK: Start and capture

    private func start(kind: ReadKind, origin: ReadOrigin) {
        lastError = nil
        stickyStatus = false
        guard accessibilityTrusted else {
            status = "Grant Accessibility access to read selections"
            return
        }
        // D8: freeze the source app and its preset before any wait.
        let app = accessibility.frontmostApp()
        let preset = presets.preset(for: app?.bundleID)
        let session = Current(kind: kind, origin: origin, app: app, preset: preset)
        current = session
        state = .capturing
        status = "Capturing selection"
        let token = session.token
        session.task = Task { [weak self, capture] in
            let result = await capture.capture(from: app)
            guard let self, self.isCurrent(token) else { return }
            self.proceedAfterCapture(session, text: result.text, note: result.note)
        }
    }

    private func proceedAfterCapture(_ session: Current, text rawText: String?, note: String?) {
        let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            finishIdle(status: "Nothing selected")
            return
        }
        session.text = text
        storedOriginal = (text, session.preset)
        if let note { status = note }

        let count = text.count
        if count > SessionConfiguration.hardMax {
            finishIdle(status: "Selection too long (\(formatted(count)) characters, limit \(formatted(SessionConfiguration.hardMax)))")
            return
        }
        if count > configuration.sizeCap {
            awaitConfirmation(session, characters: count)
            return
        }
        proceed(session)
    }

    // MARK: Size guard

    private func awaitConfirmation(_ session: Current, characters: Int) {
        state = .awaitingConfirm(kind: session.kind, origin: session.origin, characters: characters)
        let window = session.origin != .menu ? configuration.hotkeyConfirmWindow : configuration.menuConfirmWindow
        let seconds = Int(window.components.seconds)
        status = session.origin != .menu
            ? "Selection too long (\(formatted(characters)) characters). Press the shortcut again within \(seconds) s to read anyway"
            : "Selection too long (\(formatted(characters)) characters). Click Read anyway within \(seconds) s"
        let token = session.token
        session.confirmExpiry = Task { [weak self, clock] in
            do { try await clock.sleep(for: window) } catch { return }
            guard let self, self.isCurrent(token), case .awaitingConfirm = self.state else { return }
            self.finishIdle(status: "Cancelled")
        }
    }

    private func confirm() {
        guard let session = current, case .awaitingConfirm = state else { return }
        session.confirmExpiry?.cancel()
        session.confirmExpiry = nil
        proceed(session)
    }

    private func proceed(_ session: Current) {
        guard let text = session.text else { return }
        switch session.kind {
        case .read:
            speak(text, session: session)
        case .smartRead:
            transform(text, session: session)
        }
    }

    // MARK: Smart read

    private func transform(_ text: String, session: Current) {
        let preset = session.preset
        guard preset.smartReadEnabled else {
            status = "Smart read disabled for \(session.app?.bundleID ?? "this app")"
            stickyStatus = true
            speak(text, session: session)
            return
        }
        guard secrets.read(.anthropic) != nil else {
            fail("No Anthropic key. Add one in Settings > Keys", actions: [.openKeys, .readOriginal])
            return
        }

        state = .transforming
        status = preset.smartReadMode == .brief ? "Summarizing" : "Cleaning up"
        let request = SmartReadRequest(
            text: text,
            mode: preset.smartReadMode,
            language: preset.languageOverride ?? LanguageDetector.detect(text),
            model: configuration.smartReadModel,
            maxTokens: configuration.maxTokens(for: preset.smartReadMode, inputCharacters: text.count),
            instructions: preset.smartReadInstructions,
            aiReply: SmartReadPrompts.isAIAssistant(bundleID: session.app?.bundleID)
        )
        let token = session.token
        let client = smartRead
        let clock = clock
        let timeout = configuration.transformTimeout
        session.task = Task { [weak self] in
            do {
                let response = try await withTimeout(timeout, clock: clock) { try await client.transform(request) }
                guard let self, self.isCurrent(token) else { return }
                self.handleTransformed(response, session: session)
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.handleTransformFailure(error)
            }
        }
    }

    private func handleTransformed(_ response: SmartReadResponse, session: Current) {
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.stopReason == .endTurn, !text.isEmpty, text.count <= SessionConfiguration.hardMax else {
            fail("Smart read incomplete", actions: [.readOriginal])
            return
        }
        speak(text, session: session)
    }

    private func handleTransformFailure(_ error: Error) {
        if error is CancellationError { return }
        if error is TimeoutError {
            fail("Smart read failed: timed out", actions: [.readOriginal])
            return
        }
        switch error as? SmartReadFailure {
        case .unauthorized: fail("Anthropic key rejected", actions: [.openKeys, .readOriginal])
        case .rateLimited: fail("Smart read failed: rate limited", actions: [.readOriginal])
        case .overloaded: fail("Smart read failed: service overloaded", actions: [.readOriginal])
        case .offline: fail("Smart read needs a connection", actions: [.readOriginal])
        case .timeout: fail("Smart read failed: timed out", actions: [.readOriginal])
        case .other(let reason): fail("Smart read failed: \(reason)", actions: [.readOriginal])
        case nil: fail("Smart read failed: \(error)", actions: [.readOriginal])
        }
    }

    // MARK: Speaking

    private func speak(_ original: String, session: Current, from offset: Int = 0) {
        // Tables, links and Markdown marks are rewritten for listening; resume offsets refer
        // to this spoken form.
        let speakable = SpeakableText.make(original)
        let text = speakable.isEmpty ? original : speakable
        session.spokenText = text
        let preset = session.preset
        var useApple = preset.provider == .apple
        if !useApple && secrets.read(.elevenLabs) == nil {
            useApple = true
            status = "Using Apple voice: no ElevenLabs key"
            stickyStatus = true
        }
        session.usingApple = useApple
        let request = SpeechRequest(
            text: text,
            voiceID: preset.elevenLabsVoiceID,
            speed: preset.speed,
            language: preset.languageOverride ?? LanguageDetector.detect(text),
            appleVoiceByLanguage: preset.appleVoiceByLanguage,
            startOffset: offset
        )
        startPlayback(request, session: session)
    }

    private func startPlayback(_ request: SpeechRequest, session: Current) {
        let provider: any SpeechProvider = session.usingApple ? apple : elevenLabs
        let playback = provider.speak(request)
        session.playback = playback
        state = .buffering
        if !stickyStatus { status = "Loading voice" }
        let token = session.token

        session.watchdog = Task { [weak self, clock] in
            do { try await clock.sleep(for: self?.configuration.firstChunkTimeout ?? .seconds(5)) } catch { return }
            guard let self, self.isCurrent(token), self.state == .buffering else { return }
            self.handleSpeechFailure(.noFirstChunk, request: request, session: session)
        }

        session.task = Task { [weak self] in
            do {
                for try await event in playback.events {
                    guard let self, self.isCurrent(token) else { return }
                    self.handle(event, session: session)
                }
                guard let self, self.isCurrent(token) else { return }
                if self.state != .idle { self.finishIdle(status: "Done") }
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.handleSpeechFailure(error as? SpeechFailure ?? .other("\(error)"), request: request, session: session)
            }
        }
    }

    private func handle(_ event: SpeechEvent, session: Current) {
        switch event {
        case .started:
            session.watchdog?.cancel()
            session.watchdog = nil
            state = .speaking
            if !stickyStatus { status = "Speaking" }
        case .progress:
            break
        case .notice(let text):
            status = text
            stickyStatus = true
        case .finished:
            finishIdle(status: "Done")
        }
    }

    private func handleSpeechFailure(_ failure: SpeechFailure, request: SpeechRequest, session: Current) {
        session.watchdog?.cancel()
        session.playback?.cancel()

        if session.usingApple {
            fail("Speech failed: \(failure.reason)")
            return
        }
        switch failure {
        case .unauthorized:
            fail("ElevenLabs key rejected", actions: [.openKeys])
        case .connectionLost(let lastPlayed):
            let spoken = session.spokenText ?? request.text
            let resumeAt = Sentences.startOffset(containing: request.startOffset + lastPlayed, in: spoken)
            status = "Continued with Apple voice: connection lost"
            stickyStatus = true
            fallbackToApple(session: session, text: spoken, from: resumeAt)
        case .noFirstChunk, .emptyResponse, .offline, .other:
            status = "Using Apple voice: ElevenLabs unavailable (\(failure.reason))"
            stickyStatus = true
            fallbackToApple(session: session, text: session.spokenText ?? request.text, from: request.startOffset)
        }
    }

    /// D11: cancel the old provider, bump the attempt so its late callbacks are dropped, then start Apple.
    private func fallbackToApple(session: Current, text: String, from offset: Int) {
        session.task?.cancel()
        session.attempt += 1
        session.usingApple = true
        let request = SpeechRequest(
            text: text,
            voiceID: session.preset.elevenLabsVoiceID,
            speed: session.preset.speed,
            language: session.preset.languageOverride ?? LanguageDetector.detect(text),
            appleVoiceByLanguage: session.preset.appleVoiceByLanguage,
            startOffset: offset
        )
        startPlayback(request, session: session)
    }

    // MARK: Ending

    private func cancel(status: String) {
        tearDown()
        state = .idle
        self.status = status
    }

    private func finishIdle(status: String) {
        tearDown()
        state = .idle
        self.status = status
    }

    private func fail(_ message: String, actions: [ErrorAction] = []) {
        tearDown()
        state = .idle
        lastError = LastError(message: message, actions: actions)
        status = message
    }

    private func tearDown() {
        guard let session = current else { return }
        session.confirmExpiry?.cancel()
        session.watchdog?.cancel()
        session.task?.cancel()
        session.playback?.cancel()
        current = nil
    }

    private func formatted(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

extension SpeechFailure {
    /// Short reason for status lines.
    public var reason: String {
        switch self {
        case .unauthorized: return "key rejected"
        case .noFirstChunk: return "no audio within the timeout"
        case .emptyResponse: return "empty response"
        case .offline: return "offline"
        case .connectionLost: return "connection lost"
        case .other(let s): return s
        }
    }
}
