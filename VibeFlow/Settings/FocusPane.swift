import KeyboardShortcuts
import SwiftUI
import VibeFlowCore

/// Settings > Focus: Start or Stop in the header with the running phase, the rhythm (one card
/// per preset and what one round looks like), what happens between phases with the start/pause
/// shortcut, and the last seven days.
struct FocusPane: View {
    @Environment(AppContainer.self) private var container

    private var focus: FocusTimer { container.focus }

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PaneHeader(.focus, subtitle: status(at: context.date)) {
                    if focus.session == nil {
                        Button("Start Focus") { focus.send(.start) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Stop") { focus.send(.stop) }
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(FocusPreset.allCases, id: \.self) { preset in
                        PresetCard(preset: preset, selected: preset == focus.preset) { focus.selectPreset(preset) }
                    }
                }
                RoundStrip(preset: focus.preset)
            } header: {
                Text("Rhythm")
            }

            Section("Between phases") {
                Toggle(isOn: $prefs.focusAutoAdvance) {
                    Text("Start the next phase on its own")
                    Text("Off: the menu bar shows Break? or Focus? and waits for your click.")
                }
                ShortcutRecorder("Start or pause", hint: "Starts, pauses and resumes focus from anywhere", name: .focusToggle)
            }

            Section("This week") {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        FocusTodayLine(blocks: focus.blocks, now: context.date)
                        FocusWeekChart(blocks: focus.blocks, now: context.date)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "A Pomodoro timer…" while idle, else the phase and time left: "Focus · 24:10 left · Classic".
    private func status(at now: Date) -> String {
        guard let session = focus.session else {
            return "A Pomodoro timer. It shows in the menu bar only while it runs."
        }
        switch session.stage {
        case .running(let phase, _):
            return "\(phase.title) · \(FocusStats.countdown(session.remaining(at: now) ?? 0)) left · \(session.preset.title)"
        case .paused(let phase, let remaining):
            return "\(phase.title) paused · \(FocusStats.countdown(remaining)) left"
        case .awaiting(let phase):
            return phase.isBreak ? "Focus done, waiting to start the break" : "Break over, waiting to start focus"
        }
    }
}

/// One preset as a card: "Classic", "25 / 5 min", "15 min long break after 4".
private struct PresetCard: View {
    let preset: FocusPreset
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(preset.title).fontWeight(.semibold)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(preset.focusMinutes)").font(.title2.weight(.semibold))
                    Text("/ \(preset.shortBreakMinutes) min").foregroundStyle(.secondary)
                }
                Text("\(preset.longBreakMinutes) min long break after \(preset.blocksBeforeLong)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One round of a preset drawn to scale: focus blocks, short breaks, the long break.
private struct RoundStrip: View {
    let preset: FocusPreset

    private var phases: [FocusPhase] {
        (1...preset.blocksBeforeLong).flatMap { block in
            [.focus, block == preset.blocksBeforeLong ? .longBreak : .shortBreak] as [FocusPhase]
        }
    }

    var body: some View {
        let total = phases.reduce(0) { $0 + preset.minutes(for: $1) }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let spacing: CGFloat = 3
                let width = geometry.size.width - spacing * CGFloat(phases.count - 1)
                HStack(spacing: spacing) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(phase))
                            .frame(width: width * CGFloat(preset.minutes(for: phase)) / CGFloat(total))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            HStack {
                Text("\(preset.blocksBeforeLong) × focus, \(preset.blocksBeforeLong - 1) breaks, 1 long break")
                Spacer()
                Text("One round: \(FocusStats.duration(minutes: total))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func color(_ phase: FocusPhase) -> Color {
        switch phase {
        case .focus: FeatureColor.tools
        case .shortBreak: FeatureColor.tools.opacity(0.3)
        case .longBreak: FeatureColor.tools.opacity(0.55)
        }
    }
}
