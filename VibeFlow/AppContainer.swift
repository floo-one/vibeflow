import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import VibeFlowCore
import ServiceManagement

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
    let accessibility = LiveAccessibility()
    private let clipboardSource = LiveClipboardSource()
    private let player = PCMStreamPlayer()
    private let recorder = LiveAudioRecorder()
    @ObservationIgnored private var notch: NotchIndicator?
    private let elevenLabs: ElevenLabsProvider
    let catalogs: RemoteCatalogs
    /// Which settings tab is showing; "Add key" buttons jump to Keys.
    var settingsTab: SettingsTab = .general
    /// True after the record shortcut, false after a read: which session the menu's status
    /// line and icon describe.
    private(set) var showsDictation = false

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
            configuration: preferences.sessionConfiguration
        )
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
            cue: { if preferences.dictationSounds { sounds.play($0) } }
        )
        notch = NotchIndicator(dictation: dictation, reading: session, preferences: preferences, level: { [recorder] in recorder.level })
        onDeviceModel = OnDeviceModelStatus(store: LiveOnDeviceModelStore())
        onDeviceModel.prepare(language: presets.defaultPreset.languageOverride) // D9

        KeyboardShortcuts.onKeyUp(for: .read) { [weak self] in self?.hotkey(.read) }
        KeyboardShortcuts.onKeyUp(for: .smartRead) { [weak self] in self?.hotkey(.smartRead) }
        KeyboardShortcuts.onKeyUp(for: .readClipboard) { [weak self] in self?.clipboardHotkey(.read) }
        KeyboardShortcuts.onKeyUp(for: .smartReadClipboard) { [weak self] in self?.clipboardHotkey(.smartRead) }
        KeyboardShortcuts.onKeyDown(for: .record) { [weak self] in self?.recordKeyDown() }
        KeyboardShortcuts.onKeyUp(for: .record) { [weak self] in self?.dictation.recordKeyUp() }
        KeyboardShortcuts.onKeyDown(for: .recordToggle) { [weak self] in self?.toggleRecording() }

        warmConnections()
    }

    private func recordKeyDown() {
        showsDictation = true
        dictation.recordKeyDown()
    }

    private func toggleRecording() {
        showsDictation = true
        dictation.toggleRecording()
    }

    /// A read shortcut while dictating cancels the dictation and does nothing else.
    private func dictationCancelledByRead() -> Bool {
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

    private func hotkey(_ kind: ReadKind) {
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
