import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "usage")

/// One day's use of one model: request count, units and the estimated cost, priced when
/// each request was made (a later price change does not rewrite the past).
public struct UsageRecord: Codable, Equatable, Sendable {
    /// "2026-11-05", in the Mac's time zone.
    public var day: String
    public var provider: UsageProvider
    public var kind: UsageKind
    public var model: String
    public var requests = 0
    public var characters = 0
    public var audioSeconds = 0.0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cost = 0.0
    /// Requests whose model is not in the price table, so `cost` leaves them out.
    public var unpricedRequests = 0

    public init(day: String, provider: UsageProvider, kind: UsageKind, model: String) {
        self.day = day
        self.provider = provider
        self.kind = kind
        self.model = model
    }

    public var feature: String { UsageEvent.feature(provider, kind) }

    /// "Flash v2.5" for eleven_flash_v2_5: the Settings picker's name without its note.
    public var modelName: String {
        let all = ModelOptions.voice + ModelOptions.smartRead + ModelOptions.transcription + ModelOptions.cleanup
        let name = all.first { $0.id == model }?.name ?? (model == ScribeTranscriber.defaultModel ? "Scribe v2" : model)
        return name.split(separator: " (").first.map(String.init) ?? name
    }

    mutating func add(_ event: UsageEvent) {
        requests += 1
        characters += event.characters
        audioSeconds += event.audioSeconds
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        if let price = UsagePricing.cost(event) { cost += price } else { unpricedRequests += 1 }
    }

    mutating func add(_ other: UsageRecord) {
        requests += other.requests
        characters += other.characters
        audioSeconds += other.audioSeconds
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cost += other.cost
        unpricedRequests += other.unpricedRequests
    }

    func sameBucket(as other: UsageRecord) -> Bool {
        provider == other.provider && kind == other.kind && model == other.model
    }
}

/// A span the Usage pane shows: a week (from the locale's first weekday), month or year,
/// or one bar of its chart (a day, or a month of a year).
public enum UsagePeriod: String, CaseIterable, Sendable {
    case day, week, month, year

    public var title: String { rawValue.capitalized }

    /// The periods the pane's picker offers; a day is a click on a week's or month's bar.
    public static let browsable: [UsagePeriod] = [.week, .month, .year]

    /// One bar of this period's chart.
    public var bar: UsagePeriod { self == .year ? .month : .day }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

public struct UsageRange: Equatable, Sendable {
    public let period: UsagePeriod
    /// 0 is the current period, -1 the one before.
    public let offset: Int
    public let start: Date
    /// Exclusive.
    public let end: Date
}

/// What the charts colour by.
public enum UsageGrouping: String, CaseIterable, Sendable {
    case feature, provider, model

    public var title: String { rawValue.capitalized }

    public func key(_ record: UsageRecord) -> String {
        switch self {
        case .feature: record.feature
        case .provider: record.provider.title
        case .model: record.modelName
        }
    }
}

/// One feature, provider or model in a range, with the per-model rows it is made of.
public struct UsageGroup: Equatable, Sendable {
    public let group: String
    public let cost: Double
    public let lines: [UsageRecord]
    public var requests: Int { lines.reduce(0) { $0 + $1.requests } }
}

public struct UsagePoint: Hashable, Sendable {
    public let date: Date
    public let group: String
    public let cost: Double
}

/// What the paid APIs cost, per day and model, in one small JSON file on this Mac (no
/// database: a year is a few hundred rows). Counts only, never text. Kept for 400 days.
@MainActor
@Observable
public final class UsageLog {
    public private(set) var records: [UsageRecord] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    public static let keepDays = 400

    /// `fileURL` nil keeps the log in memory only (previews and tests).
    public init(fileURL: URL?, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
        load()
        if prune() { save() }
    }

    /// ~/Library/Application Support/VibeFlow/usage.json
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "VibeFlow/usage.json")
    }

    /// Hands events from any thread to the log on the main actor; give it to the metered clients.
    public nonisolated func sink() -> @Sendable (UsageEvent) -> Void {
        { [weak self] event in Task { @MainActor in self?.record(event) } }
    }

    public func record(_ event: UsageEvent) {
        let day = dayKey(event.date)
        if let index = records.firstIndex(where: { $0.day == day && $0.provider == event.provider && $0.kind == event.kind && $0.model == event.model }) {
            records[index].add(event)
        } else {
            var record = UsageRecord(day: day, provider: event.provider, kind: event.kind, model: event.model)
            record.add(event)
            records.append(record)
        }
        save()
    }

    // MARK: Summaries

    /// The day, week, month or year `offset` periods back from now (0 = the current one).
    public func range(_ period: UsagePeriod, offset: Int = 0) -> UsageRange {
        let anchor = calendar.date(byAdding: period.component, value: offset, to: now()) ?? now()
        let interval = calendar.dateInterval(of: period.component, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
        return UsageRange(period: period, offset: offset, start: interval.start, end: interval.end)
    }

    /// The day, week, month or year that holds `date` (a clicked chart bar).
    public func range(_ period: UsagePeriod, containing date: Date) -> UsageRange {
        let interval = calendar.dateInterval(of: period.component, for: date) ?? DateInterval(start: date, duration: 86_400)
        let current = calendar.dateInterval(of: period.component, for: now())?.start ?? now()
        let offset = calendar.dateComponents([period.component], from: current, to: interval.start).value(for: period.component) ?? 0
        return UsageRange(period: period, offset: offset, start: interval.start, end: interval.end)
    }

    /// The cost per bar (per day, or per month of a year) so far: the current period counts
    /// only the bars up to now.
    public func average(in range: UsageRange) -> Double {
        let unit = range.period.bar.component
        let until = min(now(), range.end)
        let elapsed = (calendar.dateComponents([unit], from: range.start, to: until).value(for: unit) ?? 0) + (until < range.end ? 1 : 0)
        return elapsed > 0 ? total(in: range) / Double(elapsed) : 0
    }

    /// Whether anything was used before `range`, so the pane can offer to go back.
    public func hasUse(before range: UsageRange) -> Bool {
        let first = dayKey(range.start)
        return records.contains { $0.day < first }
    }

    public func records(in range: UsageRange) -> [UsageRecord] {
        let first = dayKey(range.start)
        let last = dayKey(range.end.addingTimeInterval(-1))
        return records.filter { $0.day >= first && $0.day <= last }
    }

    /// One row per model in `range`, the most expensive first.
    public func lines(in range: UsageRange) -> [UsageRecord] {
        var lines: [UsageRecord] = []
        for record in records(in: range) {
            if let index = lines.firstIndex(where: { $0.sameBucket(as: record) }) {
                lines[index].add(record)
            } else {
                lines.append(record)
            }
        }
        return lines.sorted { ($0.cost, $0.requests) > ($1.cost, $1.requests) }
    }

    public func total(in range: UsageRange) -> Double {
        records(in: range).reduce(0) { $0 + $1.cost }
    }

    /// Each feature, provider or model in `range`, the most expensive first.
    public func groups(in range: UsageRange, by grouping: UsageGrouping) -> [UsageGroup] {
        Dictionary(grouping: lines(in: range), by: grouping.key)
            .map { UsageGroup(group: $0.key, cost: $0.value.reduce(0) { $0 + $1.cost }, lines: $0.value) }
            .sorted { ($0.cost, $0.requests, $1.group) > ($1.cost, $1.requests, $0.group) }
    }

    /// Cost per day (per month for a year) and group, for a stacked chart. Days without use
    /// have no point.
    public func series(in range: UsageRange, by grouping: UsageGrouping) -> [UsagePoint] {
        let unit = range.period.bar.component
        var costs: [Date: [String: Double]] = [:]
        for record in records(in: range) {
            guard let day = date(fromDayKey: record.day),
                  let bucket = calendar.dateInterval(of: unit, for: day)?.start else { continue }
            costs[bucket, default: [:]][grouping.key(record), default: 0] += record.cost
        }
        return costs.flatMap { bucket, groups in groups.map { UsagePoint(date: bucket, group: $0.key, cost: $0.value) } }
            .sorted { ($0.date, $0.group) < ($1.date, $1.group) }
    }

    public func clear() {
        records = []
        save()
    }

    // MARK: Storage

    private func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    @discardableResult
    private func prune() -> Bool {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -Self.keepDays, to: now()) else { return false }
        let cutoff = dayKey(cutoffDate)
        let before = records.count
        records.removeAll { $0.day < cutoff }
        return records.count != before
    }

    /// Rows this version cannot decode (a provider from a newer VibeFlow) are skipped, not
    /// the whole file.
    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let lossy = try JSONDecoder().decode([Lossy].self, from: Data(contentsOf: fileURL))
            records = lossy.compactMap(\.record)
        } catch {
            log.notice("Usage unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            records = []
        }
    }

    private struct Lossy: Decodable {
        let record: UsageRecord?
        init(from decoder: Decoder) throws { record = try? UsageRecord(from: decoder) }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            log.notice("Usage not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
