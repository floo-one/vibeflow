import AppKit
import OutflowCore
import SwiftUI

/// T2 placeholder: shows the Accessibility trust state so the rebuild-persistence check
/// has a visible readout. The full menu (status line, Last error, Stop, Speak clipboard,
/// Smart read clipboard, Read anyway, Grant Accessibility access) arrives in T11.
struct MenuBarView: View {
    @State private var trusted = Accessibility.isTrusted

    var body: some View {
        Group {
            Text(trusted ? "Accessibility: granted" : "Accessibility: not granted")
            if !trusted {
                Button("Grant Accessibility access") {
                    NSWorkspace.shared.open(Accessibility.settingsURL)
                }
            }
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Outflow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { trusted = Accessibility.isTrusted }
    }
}
