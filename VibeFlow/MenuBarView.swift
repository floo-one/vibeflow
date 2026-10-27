import AppKit
import KeyboardShortcuts
import VibeFlowCore
import SwiftUI

/// The menu (design: Menu bar status, D6 remedies): status line, Last error with up to two
/// actions, Stop, Read anyway, every action (reads, dictation, paste last dictation or AI
/// answer) with the shortcut it is currently set to, Grant Accessibility access, Settings, Quit.
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

        Button("Read selection") { container.hotkey(.read) }
            .globalKeyboardShortcut(.read)
        Button("Smart read selection") { container.hotkey(.smartRead) }
            .globalKeyboardShortcut(.smartRead)
        Button("Speak clipboard") { container.menuRead(.read) }
            .globalKeyboardShortcut(.readClipboard)
        Button("Smart read clipboard") { container.menuRead(.smartRead) }
            .globalKeyboardShortcut(.smartReadClipboard)

        Divider()

        Button(isDictatingHandsFree ? "Stop dictation" : "Start dictation") { container.toggleRecording() }
            .globalKeyboardShortcut(.recordToggle)
            .disabled(dictation.state.isBusy && !isDictatingHandsFree)
        // Push-to-talk needs the key held down, so the menu only shows where it lives.
        Button("Hold to dictate") {}
            .globalKeyboardShortcut(.record)
            .disabled(true)

        Divider()

        Button("Paste last dictation") { container.pasteLastDictation() }
            .globalKeyboardShortcut(.pasteLastDictation)
            .disabled(dictation.lastText == nil || dictation.state.isBusy)
        Button("Paste last AI answer") { container.pasteLastAnswer() }
            .globalKeyboardShortcut(.pasteLastAnswer)
            .disabled(session.lastAnswer == nil || dictation.state.isBusy)

        Divider()

        Button("Change shortcuts…") { SettingsWindow.present(openSettings, container: container, tab: .general) }
        Button("Settings…") { SettingsWindow.present(openSettings, container: container) }
            .keyboardShortcut(",")
        Button("Quit VibeFlow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var isDictatingHandsFree: Bool { dictation.state == .recording(handsFree: true) }

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
