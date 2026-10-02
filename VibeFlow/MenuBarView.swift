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

    var body: some View {
        Text(session.status)

        if let error = session.lastError {
            Text(error.message).foregroundStyle(.red)
            ForEach(error.actions, id: \.self) { action in
                Button(label(for: action)) { perform(action) }
            }
        }

        if !session.accessibilityTrusted {
            Button("Grant Accessibility access") {
                NSWorkspace.shared.open(Accessibility.settingsURL)
            }
        }

        Divider()

        Button("Stop") { session.stop() }
            .disabled(session.state == .idle)
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
