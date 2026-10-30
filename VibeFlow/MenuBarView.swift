import AppKit
import KeyboardShortcuts
import VibeFlowCore
import SwiftUI

/// The menu (design: Menu bar status, D6 remedies): status line, Last error with up to two
/// actions, Stop, Read anyway, every action (reads, dictation, paste last dictation or AI
/// answer) with the shortcut it is currently set to, Grant Accessibility access, Settings, Quit.
/// VibeFlow Dev starts with the branch and commit it was built from (BuildStamp); the release
/// ends with its version and Check for Updates.
struct MenuBarView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private var session: ReadSession { container.session }
    private var dictation: DictationSession { container.dictation }

    var body: some View {
        #if DEBUG
        Text(devBuildTitle)
        Divider()
        #endif

        if container.showsDictation {
            Text(dictation.status)
            if let error = dictation.lastError {
                Text(error.message).foregroundStyle(.red)
                ForEach(error.actions, id: \.self) { action in
                    Button(label(for: action)) { perform(action) }
                        .disabled(dictation.state.isBusy) // a paste again owns the clipboard
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

        if let exchange = session.lastExchange {
            Divider()
            Text("You asked: \(exchange.question)").lineLimit(1)
            Text(exchange.answer).lineLimit(3)
            Button("Copy answer") { container.copyLastAnswer() }
        }

        // Missing permissions, kept current by AppContainer.refreshPermissions.
        if !session.accessibilityTrusted {
            Button("Grant Accessibility access") {
                NSWorkspace.shared.open(Accessibility.settingsURL)
            }
        }
        if container.microphonePermission == .denied {
            Button("Grant Microphone access") {
                NSWorkspace.shared.open(Microphone.settingsURL)
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

        Menu("History") {
            let recent = container.history.entries.prefix(10)
            if recent.isEmpty {
                Text("Nothing yet")
            }
            ForEach(recent) { entry in
                Button(HistoryFormat.menuTitle(entry)) {
                    // A read plays again; a question opens so the full answer can be seen.
                    if entry.kind == .read {
                        container.readAgain(entry)
                    } else {
                        HistoryWindow.present(openWindow, container: container, select: entry.id)
                    }
                }
            }
            Divider()
            Button("Show All History…") { HistoryWindow.present(openWindow, container: container) }
        }

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
            .disabled(dictation.lastText == nil || clipboardBusy)
        Button("Paste last smart read") { container.pasteLastAnswer() }
            .globalKeyboardShortcut(.pasteLastAnswer)
            .disabled(session.lastAnswer == nil || clipboardBusy)

        Divider()

        Button("Settings…") { SettingsWindow.present(openSettings, container: container) }
            .keyboardShortcut(",")

        #if !DEBUG
        Divider()
        // The release updates itself (Updater); this shows which version is running.
        Text("VibeFlow \(Updater.installedVersion)")
        Button("Check for Updates…") { container.updater?.checkForUpdates() }
        #endif

        Button("Quit \(appName)") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "VibeFlow" or "VibeFlow Dev", so Quit says which of the two it closes.
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "VibeFlow"
    }

    #if DEBUG
    private var devBuildTitle: String {
        guard let stamp = BuildStamp(info: Bundle.main.infoDictionary ?? [:]) else {
            return "VibeFlow Dev · not built by scripts/dev.sh"
        }
        return "VibeFlow Dev · \(stamp.menuTitle())"
    }
    #endif

    /// A dictation or a read's Copy owns the clipboard, so pasting again would collide with it.
    private var clipboardBusy: Bool { dictation.state.isBusy || session.state == .capturing }

    private var isDictatingHandsFree: Bool { dictation.state == .recording(handsFree: true) }

    private func label(for action: ErrorAction) -> String {
        switch action {
        case .openKeys: return "Open Settings > Accounts"
        case .readOriginal: return "Read original instead"
        case .grantAccessibility: return "Grant Accessibility access"
        }
    }

    private func perform(_ action: ErrorAction) {
        switch action {
        case .openKeys: SettingsWindow.present(openSettings, container: container, tab: .accounts)
        case .readOriginal: session.readOriginal()
        case .grantAccessibility: NSWorkspace.shared.open(Accessibility.settingsURL)
        }
    }

    private func label(for action: DictationAction) -> String {
        switch action {
        case .retry: return "Retry dictation"
        case .copyText: return "Copy dictated text"
        case .discard: return "Discard recording"
        case .openKeys: return "Open Settings > Accounts"
        case .openDictationSettings: return "Open Settings > Dictation"
        case .openMicrophoneSettings: return "Open Microphone settings"
        }
    }

    private func perform(_ action: DictationAction) {
        switch action {
        case .retry: dictation.retry()
        case .copyText: Task { await dictation.copyText() }
        case .discard: dictation.discard()
        case .openKeys: SettingsWindow.present(openSettings, container: container, tab: .accounts)
        case .openDictationSettings: SettingsWindow.present(openSettings, container: container, tab: .dictation)
        case .openMicrophoneSettings: NSWorkspace.shared.open(Microphone.settingsURL)
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
