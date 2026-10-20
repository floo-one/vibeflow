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
/// - Push-to-talk: key down while idle stops any read (D3), freezes the app, its focused field
///   and its preset, then records; key up stops, transcribes and pastes.
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

    private let recorder: any AudioRecorder
    private let accessibility: any AccessibilityBridge
    private let presets: any PresetResolving
    private let insertion: TextInsertion
    private let pasteboard: any Pasteboard
    private let clock: any SessionClock
    private let setup: @MainActor () -> DictationSetup
    private let stopReading: @MainActor () -> Void
    private let cue: @MainActor (DictationCue) -> Void

    public init(
        recorder: any AudioRecorder,
        accessibility: any AccessibilityBridge,
        presets: any PresetResolving,
        pasteboard: any Pasteboard,
        clock: any SessionClock,
        setup: @escaping @MainActor () -> DictationSetup,
        stopReading: @escaping @MainActor () -> Void,
        cue: @escaping @MainActor (DictationCue) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.accessibility = accessibility
        self.presets = presets
        self.pasteboard = pasteboard
        self.clock = clock
        self.setup = setup
        self.stopReading = stopReading
        self.cue = cue
        self.insertion = TextInsertion(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
    }

    // MARK: Current dictation

    private final class Current {
        let id = SessionID()
        let target: PasteTarget?
        let preset: AppPreset
        let setup: DictationSetup
        var timers: [Task<Void, Never>] = []
        var task: Task<Void, Never>?

        init(target: PasteTarget?, preset: AppPreset, setup: DictationSetup) {
            self.target = target
            self.preset = preset
            self.setup = setup
        }
    }

    private var current: Current?

    private func isCurrent(_ id: SessionID) -> Bool { current?.id == id }

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
        guard case .recording(handsFree: false) = state else { return }
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
        let session = Current(target: frozenTarget(), preset: failure.preset, setup: setup())
        current = session
        process(failure.audio, session: session)
    }

    /// Put the kept text on the clipboard (D13).
    public func copyText() async {
        guard let text = lastFailure?.text else { return }
        let pb = pasteboard
        let wrote = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
            pb.setString(text, transient: false)
            return true
        }
        status = wrote == true ? "Copied to clipboard" : "The clipboard did not respond"
    }

    /// Forget the kept recording (D13).
    public func discard() {
        lastFailure = nil
        lastError = nil
        status = "Ready"
    }

    // MARK: Recording

    private func start(handsFree: Bool) {
        stopReading()
        lastError = nil
        lastFailure = nil

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

        let target = frozenTarget()
        let preset = presets.preset(for: target?.app.bundleID)
        let setup = setup()
        do {
            try recorder.start(deviceUID: setup.microphoneUID)
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

        let session = Current(target: target, preset: preset, setup: setup)
        current = session
        state = .recording(handsFree: handsFree)
        cue(.recordingStarted)
        status = handsFree ? "Listening. Press the toggle shortcut again to stop" : "Listening"
        let id = session.id
        session.timers = [
            Task { [weak self, clock] in
                do { try await clock.sleep(for: Self.maximumDuration) } catch { return }
                guard let self, self.isCurrent(id), case .recording = self.state else { return }
                self.finishRecording(note: "Stopped at the 2-minute limit")
            },
        ]
    }

    private func frozenTarget() -> PasteTarget? {
        accessibility.frontmostApp().map { PasteTarget(app: $0, field: accessibility.focusedElement()) }
    }

    private func finishRecording(note: String? = nil) {
        guard let session = current, case .recording = state else { return }
        session.timers.forEach { $0.cancel() }
        session.timers = []
        let audio = recorder.stop()
        cue(.recordingStopped)
        guard audio.duration >= Self.minimumDuration else {
            finishIdle(status: "Too short, nothing recorded")
            return
        }
        // Real microphones always have a noise floor; all-zero samples mean the input device
        // delivered nothing (muted, virtual or unavailable), not a quiet room.
        guard audio.rms > 0 else {
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
            cleaner = session.setup.cleaner
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
                self.transcriptionFailed(error, name: transcriber.primaryName, audio: audio, session: session)
                return
            }
            guard let self, self.isCurrent(id) else { return }
            if NoSpeech.isSilence(outcome.transcription, audio: audio) {
                self.finishIdle(status: "Didn't catch that")
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
        if let target = session.target {
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
