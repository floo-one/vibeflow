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
    let accessibility = LiveAccessibility()
    let catalogs: RemoteCatalogs
    /// Which settings tab is showing; "Add key" buttons jump to Keys.
    var settingsTab: SettingsTab = .general

    init() {
        LegacyMigration.runIfNeeded()
        SystemVoiceCatalog.preload()
        preferences = Preferences()
        presets = AppPresetStore()
        secrets = KeychainSecretsStore()
        voices = SystemVoiceCatalog()
        catalogs = RemoteCatalogs(secrets: secrets)
        catalogs.refresh()

        let clock = ContinuousSessionClock()
        let pasteboard = LivePasteboard()
        session = ReadSession(
            accessibility: accessibility,
            capture: SelectionCapture(accessibility: accessibility, pasteboard: pasteboard, clock: clock),
            presets: presets,
            elevenLabs: ElevenLabsProvider(client: URLSessionByteStreamClient(), player: PCMStreamPlayer(), secrets: secrets),
            apple: AppleSpeechProvider(catalog: voices),
            smartRead: AnthropicClient(http: URLSessionHTTPClient(), secrets: secrets),
            secrets: secrets,
            clock: clock,
            configuration: preferences.sessionConfiguration
        )

        KeyboardShortcuts.onKeyUp(for: .read) { [weak self] in self?.hotkey(.read) }
        KeyboardShortcuts.onKeyUp(for: .smartRead) { [weak self] in self?.hotkey(.smartRead) }

        warmElevenLabsConnection()
    }

    private func hotkey(_ kind: ReadKind) {
        session.configuration = preferences.sessionConfiguration
        session.hotkey(kind)
    }

    /// Menu reads use the clipboard text and the default preset.
    func menuRead(_ kind: ReadKind) {
        session.configuration = preferences.sessionConfiguration
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        session.menuRead(kind, text: text)
    }

    /// Perf note P2: a first TLS handshake at launch so the first real read is warm.
    private func warmElevenLabsConnection() {
        Task.detached(priority: .utility) {
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/")!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10
            _ = try? await URLSession.shared.data(for: request)
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
