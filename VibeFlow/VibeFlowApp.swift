import VibeFlowCore
import SwiftUI

@main
struct VibeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container: AppContainer
    @State private var clock = MenuBarClock()

    init() {
        AppDelegate.quitOlderCopies()
        FeedbackSender.start()
        _container = State(initialValue: AppContainer())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(container)
        } label: {
            MenuBarIcon()
                .environment(container)
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
        MenuBarExtra(isInserted: focusInserted) {
            FocusMenuView(now: clock.now)
                .environment(container)
        } label: {
            FocusLabel(focus: container.focus)
        }
        .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: keepAwakeInserted) {
            KeepAwakeMenuItems()
                .environment(container)
        } label: {
            KeepAwakeLabel(now: clock.now)
                .environment(container)
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
        Window("Transcribe File", id: TranscribeFileWindow.id) {
            TranscribeFileView()
                .environment(container)
        }
        .windowResizability(.contentSize)
        Window("Transcript", id: TranscriptWindow.id) {
            TranscriptView()
                .environment(container)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 700)
        Window("Context", id: ContextWindow.id) {
            ContextView()
                .environment(container)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 620)
        Window("Send Feedback", id: FeedbackWindow.id) {
            FeedbackView()
                .environment(container)
        }
        .windowResizability(.contentSize)
    }

    /// Shown from the lead time until 5 minutes after a meeting starts (M2); re-evaluated on
    /// each minute tick and whenever a sync changes the list.
    private var meetingsInserted: Binding<Bool> {
        Binding(get: { container.meetings.nudge(at: clock.now) != .hidden }, set: { _ in })
    }

    /// Shown while a Pomodoro session exists (running, paused or waiting for a click); started
    /// from the VibeFlow menu or Settings > Pomodoro, like Keep Awake.
    private var focusInserted: Binding<Bool> {
        Binding(get: { container.focus.session != nil }, set: { _ in })
    }

    /// Shown while a keep-awake session runs; started from the VibeFlow menu.
    private var keepAwakeInserted: Binding<Bool> {
        Binding(get: { container.keepAwake.isActive }, set: { _ in })
    }

    /// Shown while there is at least one clock; the Clocks tab is the only way to change that.
    private var clocksInserted: Binding<Bool> {
        Binding(get: { !container.preferences.worldClocks.isEmpty }, set: { _ in })
    }
}

/// The VibeFlow icon (with DEV in the dev build). It is always on screen, so it also hands
/// SwiftUI's window opener to the container for notification clicks (file transcription D10)
/// and installs right-click to open Settings (StatusItemRightClick).
private struct MenuBarIcon: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        icon.onAppear {
            container.openWindow = openWindow
            StatusItemRightClick.install(openSettings: openSettings, container: container)
        }
    }

    @ViewBuilder private var icon: some View {
        #if DEBUG
        HStack(spacing: 2) {
            Image(systemName: container.iconSymbol)
            Text("DEV")
        }
        #else
        Image(systemName: container.iconSymbol)
        #endif
    }
}
