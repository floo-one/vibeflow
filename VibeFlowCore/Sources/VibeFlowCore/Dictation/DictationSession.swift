import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "dictation")

// MARK: - Public surface

/// idle -> recording -> transcribing -> cleaning -> pasting -> idle (design: Dictation state machine).
public enum DictationState: Sendable, Equatable {
    case idle
    /// `handsFree` is false while the push-to-talk key is held, true when the toggle
    /// shortcut started it.
    case recording(handsFree: Bool)
    case transcribing
    case cleaning
    case pasting

    public var isBusy: Bool { self != .idle }
}

public enum DictationAction: Sendable, Hashable {
    /// Re-transcribe the kept recording with the current settings (D13).
    case retry
    /// Put the kept text on the clipboard (D13).
    case copyText
    /// Forget the kept recording (D13).
    case discard
    case openKeys
    case openDictationSettings
    case openMicrophoneSettings
}

/// The moments the app marks with a sound, like FreeFlow: the microphone opened, and it closed
/// on key up, toggle or the 2-minute cap. A cancel or a failed start plays nothing.
public enum DictationCue: Sendable, Equatable {
    case recordingStarted
    case recordingStopped
}

/// What a recorded follow-up question became: its transcript, or why there is none. Failures
/// carry a status line and a few words to say out loud (eng review D8, D14).
public enum QuestionTranscript: Sendable, Equatable {
    case text(String)
    case failed(message: String, spoken: String)
}

/// Shown in the menu until the next dictation starts or the user discards it.
public struct DictationError: Sendable, Equatable {
    public var message: String
    public var actions: [DictationAction]
    public init(message: String, actions: [DictationAction] = []) {
        self.message = message
        self.actions = actions
    }
}

/// The last dictation that failed after recording (D13): kept in memory only, replaced by the
/// next dictation, gone on quit. `text` exists when transcription worked but pasting did not.
public struct FailedDictation: Sendable, Equatable {
    public let audio: RecordedAudio
    public let text: String?
    /// The preset frozen at the original key down, so Retry keeps its local-only rule (D5).
    public let preset: AppPreset
}

/// What the current settings say to use. Read once at key down and again on Retry.
public struct DictationSetup: Sendable {
    /// The selected provider with the Apple fallback per the design's table.
    public var transcriber: FallbackTranscriber
    /// Apple on-device, used alone for apps set to "Dictate on this Mac only". nil on macOS 15.
    public var onDevice: (any Transcriber)?
    /// nil = cleanup off: the raw transcript is pasted.
    public var cleaner: (any DictationCleaner)?
    public var vocabulary: [String]
    /// Input device UID, nil = system default input (D7 resolves Automatic before this).
    public var microphoneUID: String?
    /// A status note that applies to every dictation with this setup, e.g. "Transcribed on
    /// device: no Groq key".
    public var notice: String?

    public init(transcriber: FallbackTranscriber, onDevice: (any Transcriber)? = nil, cleaner: (any DictationCleaner)? = nil,
                vocabulary: [String] = [], microphoneUID: String? = nil, notice: String? = nil) {
        self.transcriber = transcriber
        self.onDevice = onDevice
        self.cleaner = cleaner
        self.vocabulary = vocabulary
        self.microphoneUID = microphoneUID
        self.notice = notice
    }
}

// MARK: - DictationSession

/// One dictation from record key down to idle (milestone 1, D3, D5, D13).
///
/// - Push-to-talk: key down while idle stops any read (D3), freezes the frontmost app's preset,
///   then records; key up stops, transcribes and pastes at whatever has focus by then, so the
///   user can start talking in one app and click into another before the text lands.
/// - Toggle: one press starts the same recording hands-free, the next press of either shortcut
///   stops it. The 2-minute cap ends any recording.
/// - Key down while busy is ignored, never queued.
/// - `cancel()` (the read shortcuts) drops the recording or the in-flight requests; nothing is pasted.
/// - A failure after recording keeps the audio, and any text, for Retry, Copy and Discard.
///
/// Main-actor bound like ReadSession; async results are checked against the current session
/// and dropped on mismatch.
@MainActor
@Observable
public final class DictationSession {
    public static let minimumDuration: Duration = .milliseconds(300)
    public static let maximumDuration: Duration = .seconds(120)

    public private(set) var state: DictationState = .idle
    public private(set) var status: String = "Ready"
    public private(set) var lastError: DictationError?
    public private(set) var lastFailure: FailedDictation?
    /// The text of the last dictation that got as far as pasting, for "Paste last dictation".
    /// Kept in memory only.
    public private(set) var lastText: String?

    private let recorder: any AudioRecorder
    private let accessibility: any AccessibilityBridge
    private let presets: any PresetResolving
    private let insertion: TextInsertion
    private let pasteboard: any Pasteboard
    private let clock: any SessionClock
    private let setup: @MainActor () -> DictationSetup
    private let stopReading: @MainActor () -> Void
    /// True while a read is copying the selection through the clipboard; paste again waits for it.
    private let readIsCapturing: @MainActor () -> Bool
    private let cue: @MainActor (DictationCue) -> Void

    public init(
        recorder: any AudioRecorder,
        accessibility: any AccessibilityBridge,
        presets: any PresetResolving,
        pasteboard: any Pasteboard,
        clock: any SessionClock,
        setup: @escaping @MainActor () -> DictationSetup,
        stopReading: @escaping @MainActor () -> Void,
        readIsCapturing: @escaping @MainActor () -> Bool,
        cue: @escaping @MainActor (DictationCue) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.accessibility = accessibility
        self.presets = presets
        self.pasteboard = pasteboard
        self.clock = clock
        self.setup = setup
        self.stopReading = stopReading
        self.readIsCapturing = readIsCapturing
        self.cue = cue
        self.insertion = TextInsertion(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
    }

    // MARK: Current dictation

    private final class Current {
        let id = SessionID()
        let preset: AppPreset
        let setup: DictationSetup
        /// Set for a follow-up question: the transcript goes here, never to the cursor.
        let question: (@MainActor (QuestionTranscript) -> Void)?
        var timers: [Task<Void, Never>] = []
        var task: Task<Void, Never>?

        init(preset: AppPreset, setup: DictationSetup, question: (@MainActor (QuestionTranscript) -> Void)? = nil) {
            self.preset = preset
            self.setup = setup
            self.question = question
        }
    }

    private var current: Current?

    private func isCurrent(_ id: SessionID) -> Bool { current?.id == id }

    /// True while a follow-up question is being recorded or transcribed.
    public var isAskingQuestion: Bool { current?.question != nil }

    // MARK: Inputs

    /// The push-to-talk shortcut went down: record while it is held. Also stops a hands-free
    /// recording started with the toggle.
    public func recordKeyDown() {
        switch state {
        case .idle: start(handsFree: false)
        case .recording(handsFree: true): finishRecording()
        case .recording(handsFree: false), .transcribing, .cleaning, .pasting: return
        }
    }

    /// The push-to-talk shortcut came up: stop and transcribe.
    public func recordKeyUp() {
        guard case .recording(handsFree: false) = state, current?.question == nil else { return }
        finishRecording()
    }

    /// The smart read shortcut was held: record a follow-up question. Same microphone,
    /// transcriber, fallback and no-speech check as dictation; no cleanup, no paste, and a
    /// failure keeps nothing (eng review D8). The result goes to `onTranscript`.
    public func startQuestion(onTranscript: @escaping @MainActor (QuestionTranscript) -> Void) {
        guard state == .idle else { return }
        start(handsFree: false, question: onTranscript)
    }

    /// The smart read shortcut came up after a hold.
    public func finishQuestion() {
        guard case .recording(handsFree: false) = state, current?.question != nil else { return }
        finishRecording()
    }

    /// The toggle shortcut: start a hands-free recording, or stop the running one.
    public func toggleRecording() {
        switch state {
        case .idle: start(handsFree: true)
        case .recording(handsFree: true): finishRecording()
        case .recording(handsFree: false), .transcribing, .cleaning, .pasting: return
        }
    }

    /// A read or smart read shortcut while dictating: drop everything, paste nothing. Pasting is
    /// not interrupted (it takes under a second and owns the clipboard). Returns whether a
    /// dictation was cancelled.
    @discardableResult
    public func cancel() -> Bool {
        switch state {
        case .idle, .pasting: return false
        case .recording: recorder.cancel()
        case .transcribing, .cleaning: break
        }
        tearDown()
        state = .idle
        status = "Dictation cancelled"
        return true
    }

    /// Re-transcribe the kept recording with the current settings and paste into whatever has
    /// focus now (D13).
    public func retry() {
        guard state == .idle, let failure = lastFailure else { return }
        lastError = nil
        let session = Current(preset: failure.preset, setup: setup())
        current = session
        process(failure.audio, session: session)
    }

    /// Put the kept text on the clipboard (D13). Waits while a paste owns the clipboard.
    public func copyText() async {
        guard state == .idle, let text = lastFailure?.text else { return }
        let pb = pasteboard
        let wrote = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
            pb.setString(text, transient: false)
            return true
        }
        status = wrote == true ? "Copied to clipboard" : "The clipboard did not respond"
    }

    /// Paste text into whatever has focus now, the same way a dictation pastes: the menu's
    /// "Paste last dictation" and "Paste last smart read". It runs in the pasting state, so no
    /// dictation, Retry or second paste starts while it owns the clipboard. When it cannot paste,
    /// the clipboard is left alone: the text is still kept for another try. While a read copies the
    /// selection, the read owns the clipboard and paste again is refused.
    public func pasteAgain(_ text: String) async {
        guard state == .idle else { return }
        guard !readIsCapturing() else {
            status = "Not pasted: a read is copying the selection"
            return
        }
        guard let target = focusedTarget() else {
            status = "Not pasted: no app had focus"
            return
        }
        if let reason = insertion.invalidTargetReason(target) {
            status = "Not pasted: \(reason)"
            return
        }
        state = .pasting
        status = "Pasting"
        let result = await insertion.insert(text, into: target)
        state = .idle
        switch result {
        case .pasted(let note):
            status = note ?? "Pasted"
            // Re-pasting a failed dictation's text resolves it; anything else leaves its actions.
            if text == lastFailure?.text {
                lastFailure = nil
                lastError = nil
            }
        case .copiedInstead(let reason):
            status = "Not pasted: \(reason)"
        }
    }

    /// Forget the kept recording (D13).
    public func discard() {
        if let text = lastFailure?.text, text == lastText { lastText = nil }
        lastFailure = nil
        lastError = nil
        status = "Ready"
    }

    // MARK: Recording

    private func start(handsFree: Bool, question: (@MainActor (QuestionTranscript) -> Void)? = nil) {
        stopReading()
        lastError = nil
        if question == nil { lastFailure = nil }

        switch recorder.permission {
        case .granted:
            break
        case .denied:
            fail(Self.microphoneOff, actions: [.openMicrophoneSettings])
            return
        case .undetermined:
            // The system prompt takes the focus; record on the next press.
            status = "Waiting for microphone access"
            Task { [weak self, recorder] in
                let granted = await recorder.requestPermission()
                guard let self, self.state == .idle else { return }
                if granted {
                    self.status = "Microphone ready. Press the record shortcut to dictate"
                } else {
                    self.fail(Self.microphoneOff, actions: [.openMicrophoneSettings])
                }
            }
            return
        }

        let preset = presets.preset(for: accessibility.frontmostApp()?.bundleID)
        let setup = setup()
        let session = Current(preset: preset, setup: setup, question: question)
        current = session
        state = .recording(handsFree: handsFree)
        let id = session.id
        do {
            try recorder.start(deviceUID: setup.microphoneUID) { [weak self] in self?.microphoneLive(id) }
        } catch let error as RecordingError {
            switch error {
            case .permissionDenied: fail(Self.microphoneOff, actions: [.openMicrophoneSettings])
            case .noInputDevice: fail("No microphone found", actions: [.openDictationSettings])
            case .engineFailed(let reason): fail("Microphone failed: \(reason)", actions: [.openDictationSettings])
            }
            return
        } catch {
            fail("Microphone failed: \(error.localizedDescription)", actions: [.openDictationSettings])
            return
        }

        status = handsFree ? "Listening. Press the toggle shortcut again to stop" : "Listening"
        session.timers = [
            Task { [weak self, clock] in
                do { try await clock.sleep(for: Self.maximumDuration) } catch { return }
                guard let self, self.isCurrent(id), case .recording = self.state else { return }
                self.finishRecording(note: "Stopped at the 2-minute limit")
            },
        ]
    }

    /// The first audio arrived: now the start cue tells the speaker to talk (eng review D13).
    private func microphoneLive(_ id: SessionID) {
        guard isCurrent(id), case .recording = state else { return }
        cue(.recordingStarted)
    }

    /// The app and field that have focus right now, resolved when the text is ready.
    private func focusedTarget() -> PasteTarget? {
        accessibility.frontmostApp().map { PasteTarget(app: $0, field: accessibility.focusedElement()) }
    }

    private func finishRecording(note: String? = nil) {
        guard let session = current, case .recording = state else { return }
        session.timers.forEach { $0.cancel() }
        session.timers = []
        let audio = recorder.stop()
        cue(.recordingStopped)
        guard audio.duration >= Self.minimumDuration else {
            if let question = session.question {
                finishQuestion(question, .failed(message: "Didn't catch that", spoken: "Didn't catch that."))
                return
            }
            finishIdle(status: "Too short, nothing recorded")
            return
        }
        // Real microphones always have a noise floor; all-zero samples mean the input device
        // delivered nothing (muted, virtual or unavailable), not a quiet room.
        guard audio.rms > 0 else {
            if let question = session.question {
                finishQuestion(question, .failed(message: "The microphone recorded no sound. Choose a microphone in Settings > Dictation",
                                                 spoken: "The microphone recorded no sound."))
                return
            }
            fail("The microphone recorded no sound. Choose a microphone in Settings > Dictation", actions: [.openDictationSettings])
            return
        }
        process(audio, session: session, notes: note.map { [$0] } ?? [])
    }

    // MARK: Transcribe, clean, paste

    private func process(_ audio: RecordedAudio, session: Current, notes initialNotes: [String] = []) {
        var notes = initialNotes
        let transcriber: FallbackTranscriber
        let cleaner: (any DictationCleaner)?
        if session.preset.dictationLocalOnly {
            guard let onDevice = session.setup.onDevice else {
                lastFailure = FailedDictation(audio: audio, text: nil, preset: session.preset)
                fail("This app dictates on this Mac only, which needs macOS 26", actions: [.discard])
                return
            }
            transcriber = FallbackTranscriber(primary: onDevice, fallback: nil, primaryName: "On-device dictation")
            cleaner = nil
        } else {
            transcriber = session.setup.transcriber
            cleaner = session.question == nil ? session.setup.cleaner : nil
            if let notice = session.setup.notice { notes.append(notice) }
        }

        state = .transcribing
        status = "Transcribing"
        let id = session.id
        let language = session.preset.languageOverride
        let vocabulary = session.setup.vocabulary
        let clock = clock
        let earlyNotes = notes
        session.task = Task { [weak self] in
            var notes = earlyNotes
            let outcome: TranscriptionOutcome
            do {
                outcome = try await transcriber.transcribe(audio, language: language)
            } catch {
                guard let self, self.isCurrent(id) else { return }
                if let question = session.question {
                    if error is CancellationError { return }
                    self.finishQuestion(question, .failed(message: "Couldn't transcribe the question: \(Self.reason(error))",
                                                          spoken: "Couldn't understand the question."))
                    return
                }
                self.transcriptionFailed(error, name: transcriber.primaryName, audio: audio, session: session)
                return
            }
            guard let self, self.isCurrent(id) else { return }
            if NoSpeech.isSilence(outcome.transcription, audio: audio) {
                if let question = session.question {
                    self.finishQuestion(question, .failed(message: "Didn't catch that", spoken: "Didn't catch that."))
                    return
                }
                self.finishIdle(status: "Didn't catch that")
                return
            }
            if let question = session.question {
                let text = outcome.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finishQuestion(question, text.isEmpty ? .failed(message: "Didn't catch that", spoken: "Didn't catch that.") : .text(text))
                return
            }
            if let reason = outcome.fellBackBecause { notes.append("Transcribed on device: \(reason)") }

            self.state = .cleaning
            self.status = "Cleaning up"
            let cleaned = await DictationCleanup.run(outcome.transcription.text, cleaner: cleaner, vocabulary: vocabulary, clock: clock)
            guard self.isCurrent(id) else { return }
            if let note = cleaned.note { notes.append(note) }

            await self.paste(cleaned.text, audio: audio, session: session, notes: notes)
        }
    }

    private func paste(_ text: String, audio: RecordedAudio, session: Current, notes: [String]) async {
        state = .pasting
        status = "Pasting"
        let result: InsertionResult
        if let target = focusedTarget() {
            result = await insertion.insert(text, into: target)
        } else {
            let pb = pasteboard
            _ = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
                pb.setString(text, transient: false)
                return true
            }
            result = .copiedInstead(reason: "no app had focus")
        }
        guard isCurrent(session.id) else { return }
        lastText = text

        switch result {
        case .pasted(let note):
            let all = notes + [note].compactMap { $0 }
            lastFailure = nil
            finishIdle(status: all.isEmpty ? "Pasted" : all.joined(separator: ". "))
        case .copiedInstead(let reason):
            lastFailure = FailedDictation(audio: audio, text: text, preset: session.preset)
            fail("Copied instead of pasted: \(reason)", actions: [.copyText, .discard])
        }
    }

    private func transcriptionFailed(_ error: Error, name: String, audio: RecordedAudio, session: Current) {
        if error is CancellationError { return }
        lastFailure = FailedDictation(audio: audio, text: nil, preset: session.preset)
        switch error as? TranscriptionFailure {
        case .unauthorized:
            fail("\(name) key rejected or missing", actions: [.openKeys, .retry, .discard])
        case .rejected(let status, let message):
            fail("\(name) error \(status): \(message)", actions: [.openDictationSettings, .retry, .discard])
        case .rateLimited:
            fail("\(name) unavailable (rate limited)", actions: [.retry, .discard])
        case .serverError(let code):
            fail("\(name) unavailable (HTTP \(code))", actions: [.retry, .discard])
        case .offline:
            fail("\(name) unavailable (offline)", actions: [.retry, .discard])
        case .timeout:
            fail("\(name) unavailable (timed out)", actions: [.retry, .discard])
        case .malformed:
            fail("\(name) returned an unreadable response", actions: [.openDictationSettings, .retry, .discard])
        case .assetsMissing(let language):
            fail("Download the on-device model for \(language) in Settings > Dictation", actions: [.openDictationSettings, .retry, .discard])
        case .unavailable(let reason):
            fail(reason, actions: [.retry, .discard])
        case nil:
            fail("Transcription failed: \(error.localizedDescription)", actions: [.retry, .discard])
        }
    }

    // MARK: Ending

    /// A question is handed over and the dictation side goes quiet; its errors are shown and
    /// spoken by the read session, not kept here.
    private func finishQuestion(_ handler: @MainActor (QuestionTranscript) -> Void, _ result: QuestionTranscript) {
        tearDown()
        state = .idle
        status = "Ready"
        handler(result)
    }

    private static func reason(_ error: Error) -> String {
        switch error as? TranscriptionFailure {
        case .unauthorized: return "key rejected or missing"
        case .rejected(let status, _): return "error \(status)"
        case .rateLimited: return "rate limited"
        case .serverError(let code): return "HTTP \(code)"
        case .offline: return "offline"
        case .timeout: return "timed out"
        case .malformed: return "unreadable response"
        case .assetsMissing(let language): return "the on-device model for \(language) is missing"
        case .unavailable(let reason): return reason
        case nil: return error.localizedDescription
        }
    }

    private static let microphoneOff = "Microphone access is off. Allow VibeFlow in System Settings > Privacy & Security > Microphone"

    private func finishIdle(status: String) {
        log.notice("Dictation finished: \(status, privacy: .public)")
        tearDown()
        state = .idle
        self.status = status
    }

    private func fail(_ message: String, actions: [DictationAction] = []) {
        log.notice("Dictation failed: \(message, privacy: .public)")
        tearDown()
        state = .idle
        lastError = DictationError(message: message, actions: actions)
        status = message
    }

    private func tearDown() {
        guard let session = current else { return }
        session.timers.forEach { $0.cancel() }
        session.task?.cancel()
        current = nil
    }
}
