import Charts
import SwiftUI
import MaagicalCore

/// Settings > Pomodoro: the status and the session controls in the header, the rhythm as four
/// cards in plain words (Custom shows its steppers), what happens between phases with the
/// start/pause shortcut, the stats with a 30-day chart, and the history by day. The per-minute
/// timeline rolls "today" and the streak over at midnight.
struct PomodoroPane: View {
    @Environment(AppContainer.self) private var container
    /// Days of history shown; "Show older days…" adds two more weeks.
    @State private var historyDays = 14

    var body: some View {
        TimelineView(.everyMinute) { context in
            Form {
                session
                rhythm
                betweenPhases
                stats(at: context.date)
                history
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Session

    private var session: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let focus = container.focus
            PaneHeader(.pomodoro, subtitle: focus.session == nil
                       ? "Start a round here or from the Maagical menu. It shows in the menu bar only while it runs."
                       : focus.statusLine(at: context.date)) {
                HStack { PomodoroControls() }
            }
        }
    }

    // MARK: Between phases

    private var betweenPhases: some View {
        @Bindable var prefs = container.preferences
        return Section("Between phases") {
            Toggle(isOn: $prefs.focusAutoAdvance) {
                Text("Start the next phase on its own")
                Text("Off: the menu bar shows Break? or Focus? and waits for your click.")
            }
            ShortcutRecorder("Start or pause", hint: "Starts, pauses and resumes a round from anywhere", name: .focusToggle)
        }
    }

    // MARK: Rhythm

    private var rhythm: some View {
        let prefs = container.preferences
        return Section {
            HStack(spacing: 8) {
                ForEach(FocusPreset.allCases, id: \.self) { preset in
                    RhythmCard(preset: preset, rhythm: preset.rhythm(custom: prefs.focusCustom),
                               isSelected: prefs.focusPreset == preset) {
                        container.focus.selectPreset(preset)
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if prefs.focusPreset == .custom {
                customStepper("Focus", \.focusMinutes, in: FocusRhythm.focusRange, step: FocusRhythm.focusStep)
                customStepper("Break", \.shortBreakMinutes, in: FocusRhythm.shortBreakRange, step: 1)
                customStepper("Longer break", \.longBreakMinutes, in: FocusRhythm.longBreakRange, step: FocusRhythm.longBreakStep)
                LabeledContent("Longer break every") {
                    Stepper(FocusStats.rounds(prefs.focusCustom.rounds), value: customBinding(\.rounds),
                            in: FocusRhythm.roundsRange)
                }
            }
        } header: {
            Text("Rhythm")
        } footer: {
            Text("You get a chime and a notification when each part ends; the next one starts when you click.")
                .foregroundStyle(.secondary)
        }
    }

    private func customStepper(_ title: String, _ keyPath: WritableKeyPath<FocusRhythm, Int>,
                               in range: ClosedRange<Int>, step: Int) -> some View {
        LabeledContent(title) {
            Stepper("\(container.preferences.focusCustom[keyPath: keyPath]) min",
                    value: customBinding(keyPath), in: range, step: step)
        }
    }

    private func customBinding(_ keyPath: WritableKeyPath<FocusRhythm, Int>) -> Binding<Int> {
        Binding(
            get: { container.preferences.focusCustom[keyPath: keyPath] },
            set: { value in
                var rhythm = container.preferences.focusCustom
                rhythm[keyPath: keyPath] = value
                container.focus.setCustom(rhythm)
            }
        )
    }

    // MARK: Stats

    private func stats(at now: Date) -> some View {
        let blocks = container.focus.blocks
        let today = FocusStats.today(blocks, now: now)
        let weekMinutes = FocusStats.week(blocks, now: now).reduce(0) { $0 + $1.minutes }
        let streak = FocusStats.streak(blocks, now: now)
        let days = FocusStats.days(blocks, last: 30, now: now)
        return Section("Stats") {
            HStack(alignment: .top) {
                number("\(today.blocks)", "\(today.blocks == 1 ? "round" : "rounds") today · \(FocusStats.duration(minutes: today.minutes))")
                number(FocusStats.duration(minutes: weekMinutes), "this week")
                number(streak == 1 ? "1 day" : "\(streak) days", "streak")
            }
            VStack(spacing: 4) {
                Chart(days, id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(FeatureColor.tools)
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .accessibilityLabel("Focus minutes per day, last 30 days")
                HStack {
                    Text(days.first?.date.formatted(.dateTime.day().month()) ?? "")
                    Spacer()
                    Text("Today")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func number(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: History

    private var history: some View {
        let days = FocusStats.history(container.focus.blocks)
        return Section("History") {
            if days.isEmpty {
                Text("No rounds yet. Start one from the timer in the menu bar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days.prefix(historyDays), id: \.date) { day in
                HStack {
                    Text(title(for: day.date)).fontWeight(.semibold)
                    Spacer()
                    Text("\(FocusStats.rounds(day.blocks.count)) · \(FocusStats.duration(minutes: day.minutes))")
                        .foregroundStyle(.secondary)
                }
                ForEach(day.blocks) { round in
                    HStack {
                        Text("\(round.start.formatted(date: .omitted, time: .shortened)) – \(round.end.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                        Spacer()
                        Text("\(round.preset.title) · \(round.minutes) min")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    .contextMenu {
                        Button("Delete Round", role: .destructive) { container.focus.deleteRound(round.id) }
                    }
                }
            }
            if days.count > historyDays {
                Button("Show older days…") { historyDays += 14 }
                    .buttonStyle(.link)
            }
            if container.focus.saveFailed {
                Label("Couldn't save focus data", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func title(for day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if Calendar.current.isDateInToday(day) { return "Today, \(date)" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday, \(date)" }
        return date
    }
}

/// One rhythm as a card: the focus length large, then the break and the longer break in words.
private struct RhythmCard: View {
    let preset: FocusPreset
    let rhythm: FocusRhythm
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).fontWeight(.semibold)
                Text("\(rhythm.focusMinutes) min").font(.title3.weight(.semibold)).monospacedDigit()
                Text(rhythm.breakLine).font(.caption)
                Text(rhythm.longBreakLine).font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(9)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title): \(rhythm.focusMinutes) minutes \(rhythm.breakLine). \(rhythm.longBreakLine)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
