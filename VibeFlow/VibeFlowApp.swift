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
        MenuBarExtra(isInserted: meetingsInserted) {
            MeetingsMenuView(now: clock.now)
                .environment(container)
        } label: {
            Text(MeetingSchedule.label(for: container.meetings.nudge(at: clock.now)) ?? "")
                .monospacedDigit()
        }
        Settings {
            SettingsView()
                .environment(container)
        }
        Window("History", id: HistoryWindow.id) {
            HistoryView()
                .environment(container)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 440)
    }

    /// Shown from the lead time until 5 minutes after a meeting starts (M2); re-evaluated on
    /// each minute tick and whenever a sync changes the list.
    private var meetingsInserted: Binding<Bool> {
        Binding(get: { container.meetings.nudge(at: clock.now) != .hidden }, set: { _ in })
    }

    /// Shown while there is at least one clock; the Clocks tab is the only way to change that.
    private var clocksInserted: Binding<Bool> {
        Binding(get: { !container.preferences.worldClocks.isEmpty }, set: { _ in })
    }
}
