import AppKit
import VibeFlowCore
import SwiftUI

/// The menu (design: Menu bar status, D6 remedies): status line, Last error with up to two
/// actions, Stop, Speak clipboard, Smart read clipboard, Read anyway, Grant Accessibility
/// access, Settings, Quit.
struct MenuBarView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openSettings) private var openSettings

    private var session: ReadSession { container.session }
    private var dictation: DictationSession { container.dictation }

    var body: some View {
        if container.showsDictation {
            Text(dictation.status)
            if let error = dictation.lastError {
                Text(error.message).foregroundStyle(.red)
                ForEach(error.actions, id: \.self) { action in
                    Button(label(for: action)) { perform(action) }
                }
            }
        } else {
            Text(session.status)
            if let error = session.lastError {
                Text(error.message).foregroundStyle(.red)
                ForEach(error.actions, id: \.self) { action in
                    Button(label(for: action)) { perform(action) }
                }
            }
        }

        if !session.accessibilityTrusted {
            Button("Grant Accessibility access") {
                NSWorkspace.shared.open(Accessibility.settingsURL)
            }
        }

        Divider()

        Button("Stop") { container.stopAll() }
            .disabled(!container.isRunning)
            .keyboardShortcut(".", modifiers: .command)

        if case .awaitingConfirm(_, .menu, _) = session.state {
            Button("Read anyway") { session.readAnyway() }
        }

        Button("Speak clipboard") { container.menuRead(.read) }
        Button("Smart read clipboard") { container.menuRead(.smartRead) }

        Divider()

        Button("Settings…") { SettingsWindow.present(openSettings, container: container) }
            .keyboardShortcut(",")
        Button("Quit VibeFlow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for action: ErrorAction) -> String {
        switch action {
        case .openKeys: return "Open Settings > Keys"
        case .readOriginal: return "Read original instead"
        case .grantAccessibility: return "Grant Accessibility access"
        }
    }

    private func perform(_ action: ErrorAction) {
        switch action {
        case .openKeys: SettingsWindow.present(openSettings, container: container, tab: .keys)
        case .readOriginal: session.readOriginal()
        case .grantAccessibility: NSWorkspace.shared.open(Accessibility.settingsURL)
        }
    }

    private func label(for action: DictationAction) -> String {
        switch action {
        case .retry: return "Retry dictation"
        case .copyText: return "Copy dictated text"
        case .discard: return "Discard recording"
        case .openKeys: return "Open Settings > Keys"
        case .openDictationSettings: return "Open Settings > Dictation"
        case .openMicrophoneSettings: return "Open Microphone settings"
        }
    }

    private func perform(_ action: DictationAction) {
        switch action {
        case .retry: dictation.retry()
        case .copyText: Task { await dictation.copyText() }
        case .discard: dictation.discard()
        case .openKeys: SettingsWindow.present(openSettings, container: container, tab: .keys)
        case .openDictationSettings: SettingsWindow.present(openSettings, container: container, tab: .dictation)
        case .openMicrophoneSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}

extension IconState {
    var symbolName: String {
        switch self {
        case .idle: return "waveform"
        case .speaking: return "waveform.circle.fill"
        case .transforming: return "sparkles"
        case .awaitingConfirm: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }
}
