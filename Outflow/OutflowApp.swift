import OutflowCore
import SwiftUI

@main
struct OutflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Outflow", systemImage: "waveform") {
            MenuBarView()
        }
        Settings {
            SettingsView()
        }
    }
}
