import Foundation

/// One clock in the menu bar: a time zone shown under the city the user picked.
public struct WorldClock: Codable, Hashable, Sendable, Identifiable {
    /// An identifier macOS accepts (see TimeZoneCatalog for the alias fallback).
    public var zoneID: String
    public var city: String
    public var countryCode: String

    public init(zoneID: String, city: String, countryCode: String) {
        self.zoneID = zoneID
        self.city = city
        self.countryCode = countryCode
    }

    public var id: String { zoneID + "|" + city }
    public var timeZone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }

    /// "DE" -> 🇩🇪; no country (UTC) -> 🌐.
    public var flag: String {
        let scalars = countryCode.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : "🌐"
    }

    public static let berlin = WorldClock(zoneID: "Europe/Berlin", city: "Berlin", countryCode: "DE")
}

/// Formatting for the menu bar label, the menu lines and the Clocks tab.
public enum ClockFormat {
    /// The whole menu bar label, e.g. "🇩🇪 14:05  🇺🇸 08:05".
    public static func label(for clocks: [WorldClock], at date: Date) -> String {
        clocks.map { "\($0.flag) \(time(date, in: $0.timeZone))" }.joined(separator: "  ")
    }

    /// "14:05", always 24 hour.
    public static func time(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: zone, calendar: calendar(zone)))
    }

    /// "Monday 12 October"
    public static func day(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .wide) \(day: .defaultDigits) \(month: .wide)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: zone, calendar: calendar(zone)))
    }

    /// "UTC+2", "UTC-3:30", "UTC".
    public static func offset(_ date: Date, in zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        if seconds == 0 { return "UTC" }
        let minutes = abs(seconds) / 60
        let sign = seconds < 0 ? "-" : "+"
        return minutes % 60 == 0 ? "UTC\(sign)\(minutes / 60)" : "UTC\(sign)\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// Menu line, e.g. "🇩🇪 Berlin: Monday 12 October, 14:05 (UTC+2)".
    public static func detail(for clock: WorldClock, at date: Date) -> String {
        let zone = clock.timeZone
        return "\(clock.flag) \(clock.city): \(day(date, in: zone)), \(time(date, in: zone)) (\(offset(date, in: zone)))"
    }

    /// Start of the next minute, when the label next changes.
    public static func nextMinute(after date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
