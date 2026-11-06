import Charts
import SwiftUI
import VibeFlowCore

/// What the paid APIs cost, laid out like Screen Time: a week, month or year as stacked bars
/// with the average, a click on a bar narrows to that day (or month), and one ranked list by
/// feature, provider or model. Estimated from what VibeFlow sent (UsageLog); an overview
/// only, nothing here limits a feature.
struct UsagePane: View {
    @Environment(AppContainer.self) private var container
    @State private var period = UsagePeriod.week
    @State private var offset = 0
    /// The start of the clicked bar; nil shows the whole period.
    @State private var selection: Date?
    @State private var grouping = UsageGrouping.feature

    var body: some View {
        let usage = container.usage
        let range = usage.range(period, offset: offset)
        let shown = selection.map { usage.range(period.bar, containing: $0) } ?? range
        let groups = usage.groups(in: shown, by: grouping)
        // Colours follow the whole period's ranking, so a bar keeps its colour when clicked.
        let colors = UsageColors(groups: usage.groups(in: range, by: grouping).map(\.group), grouping: grouping)

        Form {
            PaneHeader(.usage, subtitle: "Estimated from what Maagical sent") {
                Picker("Period", selection: $period) {
                    ForEach(UsagePeriod.browsable, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Section {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(shown)).foregroundStyle(.secondary)
                        Text(Self.dollars(usage.total(in: shown)))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if selection != nil {
                        Button("Show \(Self.title(range).lowercased())") { selection = nil }
                            .buttonStyle(.link)
                    }
                    ControlGroup {
                        Button("Earlier", systemImage: "chevron.left") { move(-1) }
                            .disabled(!usage.hasUse(before: range))
                        Button("Later", systemImage: "chevron.right") { move(1) }
                            .disabled(offset >= 0)
                    }
                    .fixedSize()
                }
                if usage.total(in: range) > 0 || !usage.records(in: range).isEmpty {
                    UsageChart(points: usage.series(in: range, by: grouping), range: range,
                               average: usage.average(in: range), colors: colors, selection: $selection,
                               barStart: { usage.range(period.bar, containing: $0).start })
                } else {
                    Text("Nothing paid \(Self.title(range).lowercased()). Apple's voice and on-device dictation are free.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if !usage.records(in: range).isEmpty {
                    Text(selection == nil ? "Click a bar to see that \(period.bar.rawValue)." : "Click the bar again to see \(Self.title(range).lowercased()).")
                        .foregroundStyle(.secondary)
                }
            }

            if !groups.isEmpty {
                Section {
                    ForEach(groups, id: \.group) { group in
                        GroupRow(group: group, grouping: grouping, share: group.cost / max(usage.total(in: shown), .ulpOfOne),
                                 color: colors.color(group.group))
                    }
                } header: {
                    HStack {
                        Text("Most expensive")
                        Spacer()
                        Picker("Show by", selection: $grouping) {
                            ForEach(UsageGrouping.allCases, id: \.self) { Text("By \($0.rawValue)").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                } footer: {
                    Text("List prices checked \(UsagePricing.checked), before free tiers, plan credits and tax; your provider's dashboard has the real bill. Counts requests from this Mac only\(Self.devNote).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: selection)
        .onChange(of: period) {
            offset = 0
            selection = nil
        }
    }

    private func move(_ step: Int) {
        offset += step
        selection = nil
    }

    #if DEBUG
    private static let devNote = "; Maagical Dev keeps its own count"
    #else
    private static let devNote = ""
    #endif

    /// Cents as money; under a cent the real amount, so small rows still tell apart.
    static func dollars(_ value: Double) -> String {
        if value > 0, value < 0.01 {
            return value.formatted(.currency(code: "USD").precision(.significantDigits(1...2)))
        }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// "This week", "Yesterday", "Tue 3 Nov", "3 – 9 Nov", "November 2026", "2025".
    static func title(_ range: UsageRange) -> String {
        let relative: [UsagePeriod: (String, String)] = [
            .day: ("Today", "Yesterday"), .week: ("This week", "Last week"),
            .month: ("This month", "Last month"), .year: ("This year", "Last year"),
        ]
        if range.offset == 0, let names = relative[range.period] { return names.0 }
        if range.offset == -1, let names = relative[range.period] { return names.1 }
        switch range.period {
        case .day:
            return range.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            let last = range.end.addingTimeInterval(-1)
            return "\(range.start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return range.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return range.start.formatted(.dateTime.year())
        }
    }
}

/// One colour per group: features keep the colours they have everywhere else in VibeFlow.
struct UsageColors {
    let groups: [String]
    let grouping: UsageGrouping

    static let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .yellow, .gray]

    func color(_ group: String) -> Color {
        switch (grouping, group) {
        case (.feature, UsageEvent.feature(.elevenLabs, .textToSpeech)): return FeatureColor.read
        case (.feature, UsageEvent.feature(.anthropic, .languageModel)): return FeatureColor.smartRead
        case (.feature, UsageEvent.feature(.groq, .speechToText)): return FeatureColor.dictation
        case (.feature, UsageEvent.feature(.groq, .languageModel)): return .orange
        case (.feature, UsageEvent.feature(.elevenLabs, .speechToText)): return FeatureColor.tools
        case (.provider, UsageProvider.elevenLabs.title): return .teal
        case (.provider, UsageProvider.groq.title): return .orange
        case (.provider, UsageProvider.anthropic.title): return Color(red: 0.85, green: 0.47, blue: 0.34)
        default:
            let index = groups.firstIndex(of: group) ?? 0
            return Self.palette[index % Self.palette.count]
        }
    }

    var range: [Color] { groups.map(color) }
}

/// Stacked bars per day (per month for a year) with a dashed average. A click selects a bar.
private struct UsageChart: View {
    let points: [UsagePoint]
    let range: UsageRange
    let average: Double
    let colors: UsageColors
    @Binding var selection: Date?
    let barStart: (Date) -> Date

    private var unit: Calendar.Component { range.period == .year ? .month : .day }

    var body: some View {
        Chart {
            ForEach(points, id: \.self) { point in
                BarMark(x: .value("Date", point.date, unit: unit), y: .value("Cost", point.cost))
                    .foregroundStyle(by: .value("Group", point.group))
                    .opacity(selection == nil || barStart(point.date) == selection ? 1 : 0.3)
                    .cornerRadius(2)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.gray)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("avg \(UsagePane.dollars(average))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: colors.groups, range: colors.range)
        .chartXScale(domain: range.start...range.end)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let cost = value.as(Double.self) { Text(UsagePane.dollars(cost)) } }
            }
        }
        .chartXAxis {
            switch range.period {
            case .year:
                AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow), centered: true) }
            case .week:
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) }
            default:
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day(), centered: true) }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geometry[plot].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        let start = barStart(date)
                        // Only bars with use can be selected; a click beside them clears.
                        let hasUse = points.contains { barStart($0.date) == start }
                        selection = (selection == start || !hasUse) ? nil : start
                    }
            }
        }
        .frame(height: 160)
        .padding(.vertical, 4)
    }
}

/// One feature, provider or model: its colour, what it was, a bar for its share and the cost.
private struct GroupRow: View {
    let group: UsageGroup
    let grouping: UsageGrouping
    let share: Double
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.group)
                    Spacer()
                    Text(cost).monospacedDigit()
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareBar(share: share, color: color)
            }
        }
        .padding(.vertical, 2)
    }

    private var cost: String {
        let priced = group.lines.contains { $0.unpricedRequests < $0.requests }
        return priced ? UsagePane.dollars(group.cost) : "not priced"
    }

    /// Feature rows say which model and how much, provider rows which features, model rows
    /// which feature; every row ends with the request count.
    private var detail: String {
        let parts: [String] = switch grouping {
        case .feature: group.lines.map { "\($0.modelName), \(Self.amount($0))" }
        case .provider: group.lines.map(\.feature).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        case .model: group.lines.map { "\($0.feature), \(Self.amount($0))" }
        }
        let requests = "\(group.requests.formatted()) \(group.requests == 1 ? "request" : "requests")"
        return (parts + [requests]).joined(separator: " · ")
    }

    static func amount(_ record: UsageRecord) -> String {
        switch record.kind {
        case .textToSpeech:
            return "\(record.characters.formatted()) characters"
        case .speechToText:
            let minutes = record.audioSeconds / 60
            return "\(minutes.formatted(.number.precision(.fractionLength(minutes < 10 ? 1 : 0)))) min of audio"
        case .languageModel:
            let tokens = record.inputTokens + record.outputTokens
            return "\(tokens.formatted(.number.notation(.compactName))) tokens"
        }
    }
}

/// A thin capsule filled to `share`.
private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(geometry.size.width * min(share, 1), 3))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("\(share.formatted(.percent.precision(.fractionLength(0)))) of the total")
    }
}
