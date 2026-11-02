import SwiftUI
import VibeFlowCore

/// The focus item in the menu bar: the countdown while a phase runs, "Break?" or "Focus?"
/// while it waits for a click, a timer symbol when idle.
struct FocusLabel: View {
    let focus: FocusTimer

    var body: some View {
        if let session = focus.session {
            switch session.stage {
            case .running:
                Text(FocusStats.countdown(session.remaining(at: focus.now) ?? 0)).monospacedDigit()
            case .paused(_, let remaining):
                HStack(spacing: 2) {
                    Image(systemName: "pause.fill")
                    Text(FocusStats.countdown(remaining)).monospacedDigit()
                }
            case .awaiting(let phase):
                Text(phase.isBreak ? "Break?" : "Focus?")
            }
        } else {
            Image(systemName: "timer")
        }
    }
}

/// The focus popup: countdown, cycle dots, the buttons for each state, today and the last
/// seven days, the preset. It stays open after a click and closes when you click elsewhere.
/// `now` is the per-minute menu bar clock, so "Today" rolls over at midnight while idle.
struct FocusMenuView: View {
    @Environment(AppContainer.self) private var container
    let now: Date

    private var focus: FocusTimer { container.focus }

    var body: some View {
        VStack(spacing: 10) {
            timer
            Divider()
            stats
            Divider()
            presetPicker
            if focus.saveFailed {
                Label("Couldn't save focus data", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    // MARK: Timer

    @ViewBuilder private var timer: some View {
        let session = focus.session
        if let session {
            Text(heading(session))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(FocusStats.countdown(session.remaining(at: focus.now) ?? 0))
                .font(.system(size: 40, weight: .light))
                .monospacedDigit()
        }
        dots(session)
        HStack(spacing: 8) { buttons(session) }
            .controlSize(.large)
    }

    private func heading(_ session: FocusSession) -> String {
        switch session.stage {
        case .running(let phase, _): return "\(name(phase)) · \(session.preset.title)"
        case .paused(let phase, _): return "\(name(phase)) paused"
        case .awaiting(let phase):
            let dots = FocusEngine.dots(for: session, preset: focus.preset)
            return phase.isBreak ? "Focus done · \(dots.filled) of \(dots.total)" : "Break over"
        }
    }

    private func name(_ phase: FocusPhase) -> String {
        switch phase {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long break"
        }
    }

    private func dots(_ session: FocusSession?) -> some View {
        let dots = FocusEngine.dots(for: session, preset: focus.preset)
        let runningFocus: Bool = {
            if case .running(.focus, _) = session?.stage { return true }
            if case .paused(.focus, _) = session?.stage { return true }
            return false
        }()
        return HStack(spacing: 8) {
            ForEach(0..<dots.total, id: \.self) { index in
                if index < dots.filled {
                    Circle().fill(.primary)
                } else if runningFocus && index == dots.filled {
                    Circle().strokeBorder(.primary, lineWidth: 2).overlay(Circle().fill(.primary).padding(3))
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1.5)
                }
            }
            .frame(width: 9, height: 9)
        }
        .accessibilityElement()
        .accessibilityLabel("\(dots.filled) of \(dots.total) focus blocks done")
    }

    @ViewBuilder private func buttons(_ session: FocusSession?) -> some View {
        switch session?.stage {
        case nil:
            Button("Start focus (\(focus.preset.focusMinutes) min)") { focus.send(.start) }
                .buttonStyle(.borderedProminent)
        case .running?:
            Button("Pause") { focus.send(.pause) }
            Button("Skip") { focus.send(.skip) }
            Button("Stop") { focus.send(.stop) }
        case .paused?:
            Button("Resume") { focus.send(.resume) }
                .buttonStyle(.borderedProminent)
            Button("Stop") { focus.send(.stop) }
        case .awaiting(let phase)?:
            let minutes = focus.preset.minutes(for: phase)
            Button(phase.isBreak ? "Start break (\(minutes) min)" : "Start focus (\(minutes) min)") { focus.send(.start) }
                .buttonStyle(.borderedProminent)
            if phase.isBreak {
                Button("Skip break") { focus.send(.skip) }
            }
            Button("Stop") { focus.send(.stop) }
        }
    }

    // MARK: Stats

    private var stats: some View {
        let today = FocusStats.today(focus.blocks, now: now)
        let week = FocusStats.week(focus.blocks, now: now)
        let peak = max(week.map(\.minutes).max() ?? 0, 1)
        let weekMinutes = week.reduce(0) { $0 + $1.minutes }
        return VStack(alignment: .leading, spacing: 6) {
            Text(today.blocks == 0 ? "**Today** · no blocks yet"
                 : "**Today** · \(today.blocks) \(today.blocks == 1 ? "block" : "blocks") · \(FocusStats.duration(minutes: today.minutes))")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(week, id: \.date) { day in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.minutes == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                            .frame(height: max(36 * CGFloat(day.minutes) / CGFloat(peak), 2))
                            .frame(height: 36, alignment: .bottom)
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(day.date.formatted(.dateTime.weekday(.wide).day().month())): \(FocusStats.duration(minutes: day.minutes))")
                }
            }
            Text("This week · \(FocusStats.duration(minutes: weekMinutes))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetPicker: some View {
        Picker("Preset", selection: Binding(get: { focus.preset }, set: { focus.selectPreset($0) })) {
            ForEach(FocusPreset.allCases, id: \.self) { preset in
                Text("\(preset.summary) · long \(preset.longBreakMinutes) after \(preset.blocksBeforeLong)").tag(preset)
            }
        }
    }
}
