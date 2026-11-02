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

/// Settings > Keep Awake: the same controls as the menu, with a live countdown.
struct KeepAwakePane: View {
    @Environment(AppContainer.self) private var container
    @State private var duration = KeepAwakeDuration.minutes(60)

    var body: some View {
        let awake = container.keepAwake
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent(KeepAwakeFormat.status(until: awake.endsAt)) {
                        Text(KeepAwakeFormat.countdown(until: awake.endsAt, now: context.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Duration", selection: $duration) {
                    ForEach(KeepAwakeDuration.presets, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Spacer()
                    if awake.isActive {
                        Button("End Session") { awake.stop() }
                    }
                    Button(awake.isActive ? "Restart" : "Start") { awake.start(duration) }
                        .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Session")
            } footer: {
                Text("While a session runs, a cup with the time left sits in the menu bar. Restart replaces the running session with the duration above.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep the display on", isOn: Binding(
                    get: { container.preferences.keepAwakeDisplayOn },
                    set: { container.setKeepAwakeDisplayOn($0) }
                ))
            } footer: {
                Text("Off lets the screen sleep while the Mac stays awake. Closing the lid still puts the Mac to sleep.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
