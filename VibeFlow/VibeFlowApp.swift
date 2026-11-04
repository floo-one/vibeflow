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
        let container = AppContainer()
        _container = State(initialValue: container)
        // The VibeFlow icon and its panel are an own status item (menu bar popover R1), made in
        // applicationDidFinishLaunching.
        AppDelegate.container = container
    }

    var body: some Scene {
        // First, so SwiftUI's openWindow and openSettings have a live scene to work from.
        Window("VibeFlow", id: SceneAnchor.id) {
            SceneAnchor()
                .environment(container)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
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

/// An invisible 1×1 window that exists from launch to quit. SwiftUI's openWindow and
/// openSettings only work from a live SwiftUI scene, and the menu bar panel is AppKit-hosted
/// (menu bar popover R1), so this hands both to the container for the panel, notification
/// clicks (file transcription D10) and right-click Settings (StatusItemRightClick).
private struct SceneAnchor: View {
    static let id = "scene-anchor"
    @Environment(AppContainer.self) private var container
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowHider())
            .onAppear {
                container.openWindow = openWindow
                container.openSettings = openSettings
                StatusItemRightClick.install(container: container)
            }
    }
}

/// Makes the anchor's window invisible, click-through and absent from Mission Control.
private struct WindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.styleMask = [.borderless]
            window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .stationary]
            window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
