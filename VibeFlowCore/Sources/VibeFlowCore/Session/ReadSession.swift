import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "reading")

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
    /// A spoken follow-up question (hold the smart read shortcut).
    case question
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

// MARK: - Conversation

/// The last text read, with its frozen preset, the brief and the follow-up turns. Created at
/// capture time so "Read original instead" works after a failed smart read (eng review O3);
/// follow-up questions are about this text (docs/designs/smart-read-follow-up.md).
public struct Conversation: Sendable, Equatable {
    public static let maxTurns = 10
    /// With nothing selected, a question continues the conversation only within this window.
    public static let staleAfter: TimeInterval = 30 * 60

    public var document: String
    public var preset: AppPreset
    public var brief: String?
    public private(set) var turns: [ConversationTurn] = []
    public var createdAt: Date

    public init(document: String, preset: AppPreset, brief: String? = nil, createdAt: Date) {
        self.document = document
        self.preset = preset
        self.brief = brief
        self.createdAt = createdAt
    }

    /// Keeps the last `maxTurns`; the document and the brief always stay.
    public mutating func append(_ turn: ConversationTurn) {
        turns.append(turn)
        if turns.count > Self.maxTurns { turns.removeFirst(turns.count - Self.maxTurns) }
    }

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > Self.staleAfter
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
    /// The last complete smart read result, for "Paste last smart read". Kept in memory only.
    public private(set) var lastAnswer: String?
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
    /// replay it after a failed smart read without re-capturing (R2-10), and so follow-up
    /// questions have something to be about.
    public private(set) var conversation: Conversation?
    /// Time source for the conversation's age; replaced in tests.
    public var now: () -> Date = Date.init
    /// A spoken error line (Apple voice), silenced by the next action (eng review D14).
    private var errorPlayback: (any SpeechPlayback)?

    // Dependencies
    private let accessibility: any AccessibilityBridge
    private let clipboardSource: any ClipboardSourcing
    private let capture: any SelectionCapturing
    private let presets: any PresetResolving
    private let elevenLabs: any SpeechProvider
    private let apple: any SpeechProvider
    /// ElevenLabs fed while Claude writes, for follow-up answers; nil = speak the finished answer.
    private let answerVoice: (any StreamingSpeechProvider)?
    private let smartRead: any SmartReadClient
    private let secrets: any SecretsStore
    private let clock: any SessionClock
    public var configuration: SessionConfiguration

    public init(
        accessibility: any AccessibilityBridge,
        clipboardSource: any ClipboardSourcing,
        capture: any SelectionCapturing,
        presets: any PresetResolving,
        elevenLabs: any SpeechProvider,
        apple: any SpeechProvider,
        smartRead: any SmartReadClient,
        secrets: any SecretsStore,
        clock: any SessionClock,
        configuration: SessionConfiguration = SessionConfiguration(),
        answerVoice: (any StreamingSpeechProvider)? = nil
    ) {
        self.answerVoice = answerVoice
        self.accessibility = accessibility
        self.clipboardSource = clipboardSource
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
        var preset: AppPreset
        /// The hotkey fired in an AI assistant app, so smart read speaks as that assistant.
        var aiReply = false
        var text: String?
        var spokenText: String?
        var usingApple = false
        var task: Task<Void, Never>?
        var playback: (any SpeechPlayback)?
        var watchdog: Task<Void, Never>?
        var confirmExpiry: Task<Void, Never>?
        /// Follow-up question: the capture result and the transcript, whichever comes first.
        var questionCapture: CaptureResult?
        var question: String?
        /// A brief or an answer: spoken at the smart read speed.
        var smartSpeed = false
        /// False for replays from History, so reading an entry again adds no new one.
        var recordsHistory = true
        /// The streamed answer: Claude's request, the text so far, how much of it went to the
        /// voice (whole sentences only), and the live voice stream while it lasts.
        var answerTask: Task<Void, Never>?
        var answer = ""
        var forwarded = 0
        var answerDone = false
        var streaming: (any StreamingSpeech)?
        /// The voice stream failed while Claude was still writing: Apple starts here once done.
        var appleResume: Int?

        init(kind: ReadKind, origin: ReadOrigin, app: FrontmostApp?, preset: AppPreset) {
            self.kind = kind
            self.origin = origin
            self.app = app
            self.preset = preset
        }

        var token: Token { Token(id: id, attempt: attempt) }
    }

    private var current: Current?

    /// The last question and its answer, for Copy answer and the paste shortcut.
    public private(set) var lastExchange: ConversationTurn?
    /// Called for every read that starts and every answered question (the app keeps History).
    public var onRecord: (@MainActor (HistoryEntry) -> Void)?

    /// True from the release of a question hold until its answer ends.
    public var isAnsweringQuestion: Bool { current?.origin == .question }

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

    /// History: read an entry's text aloud again with the default preset. Not recorded again.
    public func readAgain(_ text: String) {
        guard state == .idle else { cancel(status: "Stopped"); return }
        startClipboardRead(.read, text: text, origin: .menu, recordsHistory: false)
    }

    private func startClipboardRead(_ kind: ReadKind, text: String, origin: ReadOrigin, recordsHistory: Bool = true) {
        silenceSpokenError()
        accessibilityTrusted = accessibility.isTrusted
        lastError = nil
        stickyStatus = false
        let preset = presets.preset(for: nil)
        let session = Current(kind: kind, origin: origin, app: nil, preset: preset)
        // A reply copied with the AI app's Copy button is still that assistant talking, but only
        // when it was copied there: an email copied in Mail is not ChatGPT's advice.
        if origin == .clipboardHotkey, let source = clipboardSource.clipboardSourceBundleID(),
           source == accessibility.frontmostApp()?.bundleID {
            session.aiReply = SmartReadPrompts.isAIAssistant(bundleID: source)
        }
        session.recordsHistory = recordsHistory
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
        silenceSpokenError()
        guard state != .idle else { return }
        cancel(status: "Stopped")
    }

    /// Menu action "Read original instead": plain read of the stored text with its frozen preset.
    public func readOriginal() {
        guard state == .idle, let stored = conversation else { return }
        silenceSpokenError()
        lastError = nil
        stickyStatus = false
        let session = Current(kind: .read, origin: .menu, app: nil, preset: stored.preset)
        current = session
        session.text = stored.document
        speak(stored.document, session: session)
    }

    // MARK: Start and capture

    private func start(kind: ReadKind, origin: ReadOrigin) {
        silenceSpokenError()
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
        session.aiReply = SmartReadPrompts.isAIAssistant(bundleID: app?.bundleID)
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
        conversation = Conversation(document: text, preset: session.preset, createdAt: now())
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
        if session.recordsHistory {
            onRecord?(.read(text, smart: session.kind == .smartRead, from: session.app?.bundleID, at: now()))
        }
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
            aiReply: session.aiReply
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
        lastAnswer = text
        if conversation?.document == session.text { conversation?.brief = text }
        session.smartSpeed = true
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

    // MARK: Follow-up questions (docs/designs/smart-read-follow-up.md)

    /// The smart read shortcut was released after a hold: capture the selection while the
    /// question is transcribed. Returns the question's id; `ask` and `questionFailed` only act
    /// while it is still current, so Stop, a new read or a new hold cancels it (eng review D12).
    @discardableResult
    public func beginQuestion() -> SessionID? {
        silenceSpokenError()
        tearDown()
        lastError = nil
        stickyStatus = false
        accessibilityTrusted = accessibility.isTrusted
        guard accessibilityTrusted else {
            state = .idle
            status = "Grant Accessibility access to read selections"
            return nil
        }
        let app = accessibility.frontmostApp()
        let session = Current(kind: .smartRead, origin: .question, app: app, preset: presets.preset(for: app?.bundleID))
        current = session
        state = .capturing
        status = "Transcribing"
        let token = session.token
        session.task = Task { [weak self, capture] in
            let result = await capture.capture(from: app)
            guard let self, self.isCurrent(token) else { return }
            session.questionCapture = result
            self.continueQuestion(session)
        }
        return session.id
    }

    /// The transcript of the question that `beginQuestion` returned `id` for.
    public func ask(_ transcript: String, for id: SessionID) {
        guard let session = current, session.id == id, session.origin == .question else { return }
        session.question = transcript
        continueQuestion(session)
    }

    /// The question could not be transcribed. Holding again is the retry (eng review D8).
    public func questionFailed(_ message: String, spoken: String, for id: SessionID) {
        guard let session = current, session.id == id, session.origin == .question else { return }
        failQuestion(message, spoken: spoken)
    }

    /// Runs once both the capture and the transcript are in.
    private func continueQuestion(_ session: Current) {
        guard let capture = session.questionCapture, let question = session.question else { return }
        let selected = capture.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if capture.failed {
            failQuestion("Couldn't read the selection. Select the text again", spoken: "Couldn't read the selection.")
            return
        }
        if !selected.isEmpty && selected != conversation?.document {
            if selected.count > SessionConfiguration.hardMax {
                failQuestion("Selection too long (\(formatted(selected.count)) characters, limit \(formatted(SessionConfiguration.hardMax)))", spoken: "That selection is too long.")
                return
            }
            conversation = Conversation(document: selected, preset: session.preset, createdAt: now())
        } else if selected.isEmpty, conversation?.isStale(now: now()) ?? true {
            failQuestion("Select text to ask about", spoken: "Select some text first.")
            return
        }
        guard let context = conversation else { return }
        session.preset = context.preset
        session.text = context.document

        guard secrets.read(.anthropic) != nil else {
            failQuestion("No Anthropic key. Add one in Settings > Keys", spoken: "Questions need an Anthropic key.", actions: [.openKeys])
            return
        }
        state = .transforming
        status = "Thinking"
        let request = AskRequest(
            document: context.document,
            brief: context.brief,
            turns: context.turns,
            question: question,
            language: context.preset.languageOverride,
            model: configuration.smartReadModel,
            maxTokens: SmartReadPrompts.answerMaxTokens,
            instructions: context.preset.smartReadInstructions
        )
        session.smartSpeed = true
        if !useApple(session), let answerVoice {
            // Latency follow-up: open the voice now, feed it each sentence as Claude writes it.
            let speechRequest = speechRequest(text: "", session: session)
            let stream = answerVoice.beginStream(speechRequest)
            session.streaming = stream
            session.playback = stream
            observe(stream, request: speechRequest, session: session)
        }
        let stream = smartRead.ask(request)
        session.answerTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.current === session else { return }
                    switch chunk {
                    case .text(let text): self.answerReceived(text, session: session)
                    case .done(let reason): self.answerFinished(reason, question: question, session: session)
                    }
                }
            } catch {
                guard let self, self.current === session else { return }
                self.handleAnswerFailure(error)
            }
        }
    }

    /// Passes on every sentence that is now complete; the unfinished tail waits for more text.
    private func answerReceived(_ text: String, session: Current) {
        session.answer += text
        guard let stream = session.streaming else { return }
        let complete = Sentences.completeLength(session.answer)
        guard complete > session.forwarded else { return }
        let piece = String(session.answer.dropFirst(session.forwarded).prefix(complete - session.forwarded))
        let first = session.forwarded == 0
        session.forwarded = complete
        stream.append(piece)
        if first { startStreamWatchdog(stream, session: session) }
    }

    private func answerFinished(_ reason: StopReason, question: String, session: Current) {
        switch reason {
        case .endTurn:
            break
        case .maxTokens:
            // Eng review D7: speak what fits, up to the last full sentence.
            session.answer = Sentences.complete(session.answer)
            status = "Answer cut short"
            stickyStatus = true
        case .other(let reason):
            failQuestion("Answer failed: \(reason)", spoken: "Something went wrong with the answer.")
            return
        }
        let answer = session.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            failQuestion("Answer failed: empty response", spoken: "Something went wrong with the answer.")
            return
        }
        session.answerDone = true
        let turn = ConversationTurn(question: question, answer: answer)
        conversation?.append(turn)
        lastExchange = turn
        lastAnswer = turn.answer
        onRecord?(.question(question, answer: answer, about: session.text ?? "", from: session.app?.bundleID, at: now()))

        if let stream = session.streaming {
            if session.answer.count > session.forwarded {
                let rest = String(session.answer.dropFirst(session.forwarded))
                session.forwarded = session.answer.count
                stream.append(rest)
                if session.forwarded == rest.count { startStreamWatchdog(stream, session: session) }
            }
            stream.finishText()
        } else if let resume = session.appleResume {
            fallbackToApple(session: session, text: session.answer, from: resume)
        } else {
            speak(answer, session: session)
        }
    }

    /// No audio within the first-chunk timeout after the first sentence went out: Apple takes over.
    private func startStreamWatchdog(_ stream: any StreamingSpeech, session: Current) {
        session.watchdog?.cancel()
        session.watchdog = Task { [weak self, clock] in
            do { try await clock.sleep(for: self?.configuration.firstChunkTimeout ?? .seconds(5)) } catch { return }
            guard let self, self.current === session, session.streaming === stream, self.state != .speaking else { return }
            self.streamFailed(.noFirstChunk, session: session)
        }
    }

    /// The live voice failed during an answer. Apple speaks it, from the sentence that was
    /// playing, once Claude has finished writing.
    private func streamFailed(_ failure: SpeechFailure, session: Current) {
        session.watchdog?.cancel()
        session.streaming?.cancel()
        session.streaming = nil
        if failure == .unauthorized {
            fail("ElevenLabs key rejected", actions: [.openKeys])
            return
        }
        var resume = 0
        if case .connectionLost(let lastPlayed) = failure {
            resume = Sentences.startOffset(containing: lastPlayed, in: session.answer)
            status = "Continued with Apple voice: connection lost"
        } else {
            status = "Using Apple voice: ElevenLabs unavailable (\(failure.reason))"
        }
        stickyStatus = true
        session.usingApple = true
        if session.answerDone {
            fallbackToApple(session: session, text: session.answer, from: resume)
        } else {
            session.appleResume = resume
            state = .transforming
        }
    }

    private func handleAnswerFailure(_ error: Error) {
        if error is CancellationError { return }
        if error is TimeoutError {
            failQuestion("Answer failed: timed out", spoken: "The answer took too long.")
            return
        }
        switch error as? SmartReadFailure {
        case .unauthorized: failQuestion("Anthropic key rejected", spoken: "The Anthropic key was rejected.", actions: [.openKeys])
        case .rateLimited: failQuestion("Answer failed: rate limited", spoken: "Too many requests. Try again in a moment.")
        case .overloaded: failQuestion("Answer failed: service overloaded", spoken: "Claude is overloaded. Try again in a moment.")
        case .offline: failQuestion("Questions need a connection", spoken: "No connection.")
        case .timeout: failQuestion("Answer failed: timed out", spoken: "The answer took too long.")
        case .other(let reason): failQuestion("Answer failed: \(reason)", spoken: "Something went wrong with the answer.")
        case nil: failQuestion("Answer failed: \(error)", spoken: "Something went wrong with the answer.")
        }
    }

    /// A failed question shows in the menu and is said in a few words (eng review D14), since
    /// the listener is listening, not looking.
    private func failQuestion(_ message: String, spoken: String, actions: [ErrorAction] = []) {
        let preset = current?.preset ?? presets.preset(for: nil)
        fail(message, actions: actions)
        errorPlayback = apple.speak(SpeechRequest(text: spoken, voiceID: "", speed: preset.speed,
                                                  appleVoiceByLanguage: preset.appleVoiceByLanguage))
    }

    private func silenceSpokenError() {
        errorPlayback?.cancel()
        errorPlayback = nil
    }

    // MARK: Speaking

    private func speak(_ original: String, session: Current, from offset: Int = 0) {
        // Tables, links and Markdown marks are rewritten for listening; resume offsets refer
        // to this spoken form.
        let speakable = SpeakableText.make(original)
        let text = speakable.isEmpty ? original : speakable
        session.spokenText = text
        session.usingApple = useApple(session)
        startPlayback(speechRequest(text: text, session: session, from: offset), session: session)
    }

    /// Apple for apps set to it, or when there is no ElevenLabs key (with a note).
    private func useApple(_ session: Current) -> Bool {
        if session.preset.provider == .apple { return true }
        guard secrets.read(.elevenLabs) == nil else { return false }
        status = "Using Apple voice: no ElevenLabs key"
        stickyStatus = true
        return true
    }

    private func speechRequest(text: String, session: Current, from offset: Int = 0) -> SpeechRequest {
        let preset = session.preset
        return SpeechRequest(
            text: text,
            voiceID: preset.elevenLabsVoiceID,
            speed: session.smartSpeed ? (configuration.smartReadSpeed ?? preset.speed) : preset.speed,
            language: preset.languageOverride ?? (text.isEmpty ? nil : LanguageDetector.detect(text)),
            appleVoiceByLanguage: preset.appleVoiceByLanguage,
            startOffset: offset
        )
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
        observe(playback, request: request, session: session)
    }

    private func observe(_ playback: any SpeechPlayback, request: SpeechRequest, session: Current) {
        let token = session.token
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
                if session.streaming === playback {
                    self.streamFailed(error as? SpeechFailure ?? .other("\(error)"), session: session)
                } else {
                    self.handleSpeechFailure(error as? SpeechFailure ?? .other("\(error)"), request: request, session: session)
                }
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
        startPlayback(speechRequest(text: text, session: session, from: offset), session: session)
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
        log.notice("Read failed: \(message, privacy: .public)")
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
        session.answerTask?.cancel()
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
