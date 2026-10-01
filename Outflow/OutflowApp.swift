import OutflowCore
import SwiftUI

@main
struct OutflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(container)
        } label: {
            Image(systemName: container.session.iconState.symbolName)
        }
        Settings {
            SettingsView()
                .environment(container)
        }
    }
}
