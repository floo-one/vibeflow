import SwiftUI
import VibeFlowCore

/// The session choices, shared by the VibeFlow menu's Keep Awake submenu and the keep-awake
/// item: a duration starts (or replaces) a session, End Session stops it.
struct KeepAwakeMenuItems: View {
    @Environment(AppContainer.self) private var container

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
