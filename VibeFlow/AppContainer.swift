import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import VibeFlowCore
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "shortcuts")

/// Composition root: stores, live services, the session, global shortcuts.
@MainActor
@Observable
final class AppContainer {
    let preferences: Preferences
    let presets: AppPresetStore
    let secrets: KeychainSecretsStore
    let voices: SystemVoiceCatalog
    let session: ReadSession
    let dictation: DictationSession
    let onDeviceModel: OnDeviceModelStatus
    /// Reads and answered questions, on this Mac only (Application Support/VibeFlow/history.json).
    let history: HistoryStore
    /// The entry the History window shows; set by the menu's History submenu.
    var historySelection: HistoryEntry.ID?
    @ObservationIgnored private var appNames: [String: String] = [:]
    let accessibility = LiveAccessibility()
    private let clipboardSource = LiveClipboardSource()
    private let player = PCMStreamPlayer()
    private let recorder = LiveAudioRecorder()
    @ObservationIgnored private var notch: NotchIndicator?
    /// Tap the smart read shortcut to smart read, hold it to ask a follow-up question.
    @ObservationIgnored private var smartReadPress: PressClassifier?
    /// The question being answered, from the release of a hold until its transcript arrives.
    @ObservationIgnored private var pendingQuestion: SessionID?
    private let elevenLabs: ElevenLabsProvider
    let catalogs: RemoteCatalogs
    /// Which settings tab is showing; "Add key" buttons jump to Keys.
    var settingsTab: SettingsTab = .general
    /// True after the record shortcut, false after a read: which session the menu's status
    /// line and icon describe.
    private(set) var showsDictation = false
    /// The release's self-updater; nil in VibeFlow Dev, which never checks for updates.
    @ObservationIgnored private(set) var updater: Updater?
    /// Microphone access as last checked (refreshPermissions); the menu links to System
    /// Settings while it is denied.
    private(set) var microphonePermission: MicrophonePermission = .undetermined
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?

    init() {
        LegacyMigration.runIfNeeded()
        SystemVoiceCatalog.preload()
        let preferences = Preferences()
        let presets = AppPresetStore()
        let secrets = KeychainSecretsStore()
        self.preferences = preferences
        self.presets = presets
        self.secrets = secrets
        voices = SystemVoiceCatalog()
        catalogs = RemoteCatalogs(secrets: secrets)
        catalogs.refresh()

        let clock = ContinuousSessionClock()
        let pasteboard = LivePasteboard()
        let http = URLSessionHTTPClient()
        let elevenLabs = ElevenLabsProvider(client: URLSessionByteStreamClient(), player: player, secrets: secrets)
        self.elevenLabs = elevenLabs
        let session = ReadSession(
            accessibility: accessibility,
            clipboardSource: clipboardSource,
            capture: SelectionCapture(accessibility: accessibility, pasteboard: pasteboard, clock: clock),
            presets: presets,
            elevenLabs: elevenLabs,
            apple: AppleSpeechProvider(catalog: voices),
            smartRead: AnthropicClient(http: http, secrets: secrets),
            secrets: secrets,
            clock: clock,
            configuration: preferences.sessionConfiguration,
            answerVoice: elevenLabs
        )
        let history = HistoryStore(fileURL: HistoryStore.defaultFileURL, retention: preferences.historyRetention)
        session.onRecord = { history.add($0) }
        self.history = history
        self.session = session

        let onDevice: (any Transcriber)? = AppleTranscriber.isAvailable ? AppleTranscriber() : nil
        let sounds = DictationSounds()
        dictation = DictationSession(
            recorder: recorder,
            accessibility: accessibility,
            presets: presets,
            pasteboard: pasteboard,
            clock: clock,
            setup: {
                // D7, resolved per dictation so plugging in AirPods takes effect at once.
                let microphone = MicrophoneSelection.deviceUID(
                    choice: preferences.microphoneUID,
                    inputs: AudioDevices.inputs(),
                    outputIsBluetooth: AudioDevices.defaultOutputIsBluetooth(),
                    defaultInputUID: AudioDevices.defaultInputUID()
                )
                return DictationSetupFactory.make(vocabulary: preferences.vocabularyTerms,
                                                  transcriptionModel: preferences.transcriptionModel,
                                                  cleanupModel: preferences.cleanupModel,
                                                  secrets: secrets, http: http, onDevice: onDevice, microphoneUID: microphone)
            },
            stopReading: { session.stop() }, // D3
            readIsCapturing: { session.state == .capturing },
            cue: { if preferences.dictationSounds { sounds.play($0) } }
        )
        notch = NotchIndicator(dictation: dictation, reading: session, preferences: preferences, level: { [recorder] in recorder.level })
        onDeviceModel = OnDeviceModelStatus(store: LiveOnDeviceModelStore())
        onDeviceModel.prepare(language: presets.defaultPreset.languageOverride) // D9

        KeyboardShortcuts.onKeyUp(for: .read) { [weak self] in self?.hotkey(.read) }
        smartReadPress = PressClassifier(
            clock: clock,
            onTap: { [weak self] in
                log.notice("Smart read shortcut: tap")
                self?.hotkey(.smartRead)
            },
            onHoldStart: { [weak self] in
                log.notice("Smart read shortcut: hold")
                self?.questionHoldStarted()
            },
            onHoldEnd: { [weak self] in self?.questionHoldEnded() }
        )
        KeyboardShortcuts.onKeyDown(for: .smartRead) { [weak self] in self?.smartReadPress?.keyDown() }
        KeyboardShortcuts.onKeyUp(for: .smartRead) { [weak self] in self?.smartReadPress?.keyUp() }
        KeyboardShortcuts.onKeyUp(for: .readClipboard) { [weak self] in self?.clipboardHotkey(.read) }
        KeyboardShortcuts.onKeyUp(for: .smartReadClipboard) { [weak self] in self?.clipboardHotkey(.smartRead) }
        KeyboardShortcuts.onKeyDown(for: .record) { [weak self] in self?.recordKeyDown() }
        KeyboardShortcuts.onKeyUp(for: .record) { [weak self] in self?.dictation.recordKeyUp() }
        KeyboardShortcuts.onKeyDown(for: .recordToggle) { [weak self] in self?.toggleRecording() }
        KeyboardShortcuts.onKeyUp(for: .pasteLastDictation) { [weak self] in self?.pasteLastDictation() }
        KeyboardShortcuts.onKeyUp(for: .pasteLastAnswer) { [weak self] in self?.pasteLastAnswer() }

        refreshPermissions()
        // Every menu that opens re-checks, so a grant taken away later shows up as well.
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        #if !DEBUG
        updater = Updater(
            isBusy: { [weak self] in self?.isRunning ?? false },
            followsMain: { [weak self] in self?.preferences.updateToNewestMain ?? false }
        )
        #endif

        warmConnections()
    }

    private func recordKeyDown() {
        showsDictation = true
        dictation.recordKeyDown()
    }

    /// Shortcut and menu "Start dictation".
    func toggleRecording() {
        showsDictation = true
        dictation.toggleRecording()
    }

    /// Shortcut and menu "Paste last dictation".
    func pasteLastDictation() { pasteAgain(dictation.lastText) }

    /// Shortcut and menu "Paste last smart read": the last smart read result.
    func pasteLastAnswer() { pasteAgain(session.lastAnswer) }

    private func pasteAgain(_ text: String?) {
        guard let text else { return }
        showsDictation = true
        Task { await dictation.pasteAgain(text) }
    }

    // MARK: Follow-up questions (docs/designs/smart-read-follow-up.md)

    /// Held past the threshold: stop any read (the dictation side does it, D3) and record.
    private func questionHoldStarted() {
        if dictationCancelledByRead() { return }
        applyReadSettings()
        showsDictation = true // microphone problems show as dictation errors
        dictation.startQuestion { [weak self] result in self?.questionTranscribed(result) }
    }

    /// Released: the read session captures the selection while the question is transcribed.
    private func questionHoldEnded() {
        guard dictation.isAskingQuestion else { return }
        showsDictation = false
        pendingQuestion = session.beginQuestion()
        dictation.finishQuestion()
    }

    private func questionTranscribed(_ result: QuestionTranscript) {
        guard let id = pendingQuestion else { return }
        pendingQuestion = nil
        switch result {
        case .text(let question): session.ask(question, for: id)
        case .failed(let message, let spoken): session.questionFailed(message, spoken: spoken, for: id)
        }
    }

    /// History: read an entry aloud again (the answer, for a question).
    func readAgain(_ entry: HistoryEntry) {
        if dictationCancelledByRead() { return }
        applyReadSettings()
        session.readAgain(entry.text)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Safari" for com.apple.Safari, "Clipboard" for clipboard reads. Looked up once per app.
    func appName(for bundleID: String?) -> String {
        guard let bundleID else { return "Clipboard" }
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        appNames[bundleID] = name
        return name
    }

    func copyLastAnswer() {
        guard let answer = session.lastExchange?.answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// A read shortcut while dictating cancels the dictation and does nothing else. While a
    /// paste owns the clipboard it is ignored, so a read's Copy cannot snapshot the pasted text.
    private func dictationCancelledByRead() -> Bool {
        if dictation.state == .pasting { return true }
        if dictation.cancel() { return true }
        showsDictation = false
        return false
    }

    /// Menu "Stop": whichever session is running.
    func stopAll() {
        if !dictation.cancel() { session.stop() }
    }

    var isRunning: Bool { session.state != .idle || dictation.state.isBusy }

    var iconSymbol: String {
        switch dictation.state {
        case .recording: return "mic.fill"
        case .transcribing, .cleaning, .pasting: return "ellipsis.circle"
        case .idle: break
        }
        if showsDictation, session.state == .idle, dictation.lastError != nil { return IconState.error.symbolName }
        return session.iconState.symbolName
    }

    /// The models and speaker chosen in Settings, applied right before each read.
    private func applyReadSettings() {
        session.configuration = preferences.sessionConfiguration
        elevenLabs.model = preferences.voiceModel
        player.outputDeviceUID = preferences.speakerUID
    }

    /// Shortcut and menu "Read selection": the menu does not take focus, so the selection
    /// is still the frontmost app's.
    func hotkey(_ kind: ReadKind) {
        if dictationCancelledByRead() { return }
        applyReadSettings()
        session.hotkey(kind)
    }

    private func clipboardHotkey(_ kind: ReadKind) {
        if dictationCancelledByRead() { return }
        applyReadSettings()
        session.clipboardHotkey(kind, text: NSPasteboard.general.string(forType: .string) ?? "")
    }

    /// Menu reads use the clipboard text and the default preset.
    func menuRead(_ kind: ReadKind) {
        if dictationCancelledByRead() { return }
        applyReadSettings()
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        session.menuRead(kind, text: text)
    }

    /// Perf note P2: a first TLS handshake at launch so the first real read and the first
    /// dictation are warm. Groq only when a Groq key is set.
    private func warmConnections() {
        var hosts = ["https://api.elevenlabs.io/"]
        if secrets.read(.groq) != nil { hosts.append("https://api.groq.com/") }
        for host in hosts {
            Task.detached(priority: .utility) {
                var request = URLRequest(url: URL(string: host)!)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 10
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    // MARK: Permissions (docs/designs/dev-prod-channels.md, P4)

    /// Re-reads Accessibility and Microphone access, at launch and whenever a menu opens.
    /// While one is missing in a way only System Settings can fix, it also checks every 2 s, so
    /// the menu and the icon catch up right after it is granted there. An undetermined
    /// microphone is not missing: the first dictation asks for it.
    func refreshPermissions() {
        session.refreshAccessibility()
        microphonePermission = recorder.permission
        guard permissionWatch == nil, needsSystemSettings else { return }
        permissionWatch = Task { [weak self] in
            while let self, self.needsSystemSettings {
                try? await Task.sleep(for: .seconds(2))
                self.session.refreshAccessibility()
                self.microphonePermission = self.recorder.permission
            }
            self?.permissionWatch = nil
        }
    }

    private var needsSystemSettings: Bool {
        !session.accessibilityTrusted || microphonePermission == .denied
    }

    func applyLaunchAtLogin() {
        do {
            if preferences.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
