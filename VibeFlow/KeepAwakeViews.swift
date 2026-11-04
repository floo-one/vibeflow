import SwiftUI
import VibeFlowCore

/// The session choices, shared by the VibeFlow menu's Keep Awake submenu and the keep-awake
/// item: a duration starts (or replaces) a session, End Session stops it.
struct KeepAwakeMenuItems: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let awake = container.keepAwake
        Text(KeepAwakeFormat.status(until: awake.endsAt))
        if awake.isActive {
            Button("End Session") { awake.stop() }
        }
        Divider()
        ForEach(KeepAwakeDuration.presets, id: \.self) { duration in
            Button(duration.title) { awake.start(duration) }
        }
        Divider()
        Toggle("Allow Display Sleep", isOn: Binding(
            get: { !container.preferences.keepAwakeDisplayOn },
            set: { container.setKeepAwakeDisplayOn(!$0) }
        ))
        Button("Keep Awake Settings…") { SettingsWindow.present(openSettings, container: container, tab: .keepAwake) }
    }
}

/// Settings > Keep Awake: state and Start or End in the header (a live countdown while on),
/// the duration Start uses and whether the display stays on.
struct KeepAwakePane: View {
    @Environment(AppContainer.self) private var container
    @State private var duration = KeepAwakeDuration.minutes(60)

    var body: some View {
        let awake = container.keepAwake
        Form {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PaneHeader(.keepAwake, subtitle: status(at: context.date)) {
                    if awake.isActive {
                        Button("End Session") { awake.stop() }
                    } else {
                        Button("Start for \(duration.title)") { awake.start(duration) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section {
                Picker("Duration", selection: $duration) {
                    ForEach(KeepAwakeDuration.presets, id: \.self) { Text($0.title).tag($0) }
                }
                if awake.isActive {
                    LabeledContent("Restart with this duration") {
                        Button("Restart") { awake.start(duration) }
                    }
                }
                Toggle(isOn: Binding(
                    get: { container.preferences.keepAwakeDisplayOn },
                    set: { container.setKeepAwakeDisplayOn($0) }
                )) {
                    Text("Keep the display on")
                    Text("Off: the screen may sleep, the Mac stays awake.")
                }
            } header: {
                Text("Session")
            } footer: {
                Text("While a session runs, a cup with the time left sits in the menu bar. Closing the lid still puts the Mac to sleep.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// "Off · the Mac sleeps as usual", or the session's status and time left.
    private func status(at now: Date) -> String {
        let awake = container.keepAwake
        guard awake.isActive else { return "Off · the Mac sleeps as usual" }
        let left = KeepAwakeFormat.countdown(until: awake.endsAt, now: now)
        let status = KeepAwakeFormat.status(until: awake.endsAt)
        return left.isEmpty ? status : "\(status) · \(left) left"
    }
}

/// The menu bar item while a session runs, like Amphetamine's pill: a cup and the time left.
struct KeepAwakeLabel: View {
    @Environment(AppContainer.self) private var container
    let now: Date

    var body: some View {
        let awake = container.keepAwake
        // `now` only redraws the label each minute; a session starts between ticks, so the
        // time left is counted from the real time.
        let remaining = KeepAwakeFormat.remaining(until: awake.endsAt, now: max(now, Date()))
        HStack(spacing: 3) {
            Image(systemName: awake.keepsDisplayOn ? "cup.and.saucer.fill" : "cup.and.saucer")
            if !remaining.isEmpty {
                Text(remaining).monospacedDigit()
            }
        }
    }
}
