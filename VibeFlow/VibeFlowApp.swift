import VibeFlowCore
import SwiftUI

@main
struct VibeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container = AppContainer()
    @State private var clock = MenuBarClock()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(container)
        } label: {
            #if DEBUG
            HStack(spacing: 2) {
                Image(systemName: container.iconSymbol)
                Text("DEV")
            }
            #else
            Image(systemName: container.iconSymbol)
            #endif
        }
        MenuBarExtra(isInserted: clocksInserted) {
            ClocksMenuView(now: clock.now)
                .environment(container)
        } label: {
            Text(ClockFormat.label(for: container.preferences.worldClocks, at: clock.now))
                .monospacedDigit()
        }
        Settings {
            SettingsView()
                .environment(container)
        }
    }

    /// Shown while there is at least one clock; the Clocks tab is the only way to change that.
    private var clocksInserted: Binding<Bool> {
        Binding(get: { !container.preferences.worldClocks.isEmpty }, set: { _ in })
    }
}
