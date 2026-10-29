import Foundation

// Upcoming meetings (docs/designs/upcoming-meetings.md): which calendar events count as
// meetings, where their join link is, and when the menu bar item shows. Pure, no network.

/// The subset of a Google Calendar events resource the filter and the menu need.
public struct CalendarEvent: Decodable, Equatable, Sendable {
    public struct Time: Decodable, Equatable, Sendable {
        /// RFC 3339 with offset for timed events.
        public var dateTime: String?
        /// "2026-10-29" for all-day events.
        public var date: String?
        public init(dateTime: String? = nil, date: String? = nil) {
            self.dateTime = dateTime
            self.date = date
        }
    }

    public struct Attendee: Decodable, Equatable, Sendable {
        public var email: String?
        public var responseStatus: String?
        /// Rooms and equipment; not people.
        public var resource: Bool?
        public init(email: String?, responseStatus: String? = nil, resource: Bool? = nil) {
            self.email = email
            self.responseStatus = responseStatus
            self.resource = resource
        }
    }

    public struct Person: Decodable, Equatable, Sendable {
        public var email: String?
        public var displayName: String?
        public init(email: String? = nil, displayName: String? = nil) {
            self.email = email
            self.displayName = displayName
        }
    }

    public struct Conference: Decodable, Equatable, Sendable {
        public struct EntryPoint: Decodable, Equatable, Sendable {
            public var entryPointType: String?
            public var uri: String?
            public init(entryPointType: String?, uri: String?) {
                self.entryPointType = entryPointType
                self.uri = uri
            }
        }
        public var entryPoints: [EntryPoint]?
        public init(entryPoints: [EntryPoint]?) { self.entryPoints = entryPoints }
    }

    public var id: String
    public var summary: String?
    public var status: String?
    public var eventType: String?
    public var transparency: String?
    public var start: Time?
    public var end: Time?
    public var attendees: [Attendee]?
    public var organizer: Person?
    public var hangoutLink: String?
    public var conferenceData: Conference?
    public var location: String?
    public var description: String?
    public var htmlLink: String?

    public init(id: String, summary: String? = nil, status: String? = "confirmed", eventType: String? = "default",
                transparency: String? = nil, start: Time? = nil, end: Time? = nil, attendees: [Attendee]? = nil,
                organizer: Person? = nil, hangoutLink: String? = nil, conferenceData: Conference? = nil,
                location: String? = nil, description: String? = nil, htmlLink: String? = nil) {
        self.id = id
        self.summary = summary
        self.status = status
        self.eventType = eventType
        self.transparency = transparency
        self.start = start
        self.end = end
        self.attendees = attendees
        self.organizer = organizer
        self.hangoutLink = hangoutLink
        self.conferenceData = conferenceData
        self.location = location
        self.description = description
        self.htmlLink = htmlLink
    }
}

/// A calendar event that counts as a meeting (M5).
public struct Meeting: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendarID: String
    public var joinURL: URL?
    public var organizer: String?
    /// The event in Google Calendar on the web.
    public var htmlLink: URL?

    public init(id: String, title: String, start: Date, end: Date, calendarID: String,
                joinURL: URL? = nil, organizer: String? = nil, htmlLink: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarID = calendarID
        self.joinURL = joinURL
        self.organizer = organizer
        self.htmlLink = htmlLink
    }
}

// MARK: - Filter (M5, R5, R9)

public enum MeetingFilter {
    /// The event as a meeting, or nil if it is not one. Keeps eventType default and fromGmail;
    /// drops cancelled, all-day, "free", declined by you, and events with nobody but you.
    /// "You" is `me`, the signed-in account's email, never `attendees[].self`: on a shared
    /// calendar `self` marks that calendar's owner (R9). Rooms are not people.
    public static func meeting(from event: CalendarEvent, calendarID: String, me: String) -> Meeting? {
        let type = event.eventType ?? "default"
        guard type == "default" || type == "fromGmail",
              event.status != "cancelled",
              event.transparency != "transparent",
              let startText = event.start?.dateTime, let start = parseDate(startText)
        else { return nil }

        let me = me.lowercased()
        let attendees = event.attendees ?? []
        if attendees.contains(where: { $0.email?.lowercased() == me && $0.responseStatus == "declined" }) { return nil }
        // A hidden guest list shows only you; someone else organizing it still makes it a meeting.
        let organizedByOther = event.organizer?.email.map { $0.lowercased() != me } ?? false
        guard organizedByOther || attendees.contains(where: { $0.email?.lowercased() != me && $0.resource != true }) else { return nil }

        let end = event.end?.dateTime.flatMap(parseDate) ?? start
        let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Meeting(
            id: event.id,
            title: title.isEmpty ? "(No title)" : title,
            start: start,
            end: max(end, start),
            calendarID: calendarID,
            joinURL: JoinLink.find(in: event),
            organizer: event.organizer.flatMap { $0.displayName ?? $0.email },
            htmlLink: event.htmlLink.flatMap(JoinLink.webURL)
        )
    }

    /// Meetings from several calendars, sorted by start. The same event on two selected
    /// calendars (yours and a colleague's) shares an id and is kept once, from the first calendar.
    public static func meetings(from events: [(calendarID: String, events: [CalendarEvent])], me: String) -> [Meeting] {
        var seen = Set<String>()
        var result: [Meeting] = []
        for (calendarID, list) in events {
            for event in list {
                guard let meeting = meeting(from: event, calendarID: calendarID, me: me),
                      seen.insert(meeting.id).inserted else { continue }
                result.append(meeting)
            }
        }
        return result.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}

// MARK: - Join link

public enum JoinLink {
    /// Hosts whose links join a call, matched as the host or a subdomain of it.
    static let callHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]

    /// Google's own conference data first (exact), then the first call link in the location
    /// or description (Zoom, Teams and Webex invites put it there).
    public static func find(in event: CalendarEvent) -> URL? {
        if let link = event.hangoutLink.flatMap(webURL) { return link }
        if let uri = event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
           let link = webURL(uri) { return link }
        for text in [event.location, event.description].compactMap({ $0 }) {
            if let link = firstCallLink(in: text) { return link }
        }
        return nil
    }

    /// Only web links: a calendar event can carry any URL, and a click must never launch
    /// a file:, smb: or custom-scheme handler.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    static func firstCallLink(in text: String) -> URL? {
        for match in text.matches(of: #/https://[^\s"'<>]+/#) {
            let candidate = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            guard let url = URL(string: candidate), let host = url.host()?.lowercased() else { continue }
            if callHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return nil
    }
}

// MARK: - Schedule (M2, R10)

/// What the meetings menu bar item shows right now.
public enum MeetingNudge: Equatable, Sendable {
    case hidden
    /// Starts in `minutes` (rounded up, so it never says "in 0m").
    case soon(Meeting, minutes: Int)
    case now(Meeting)
}

public enum MeetingSchedule {
    public static let leadTimes: [Int] = [5, 10, 15]
    public static let defaultLeadMinutes = 10
    /// The item hides this long after a meeting starts (M2).
    public static let visibleAfterStart: TimeInterval = 5 * 60
    /// Menu bar title length, "…" included (R10).
    public static let titleLimit = 18

    /// From `leadMinutes` before start until 5 minutes after it. With two meetings in that
    /// window, the next one to start wins over one already running: it is the one to get to.
    public static func nudge(for meetings: [Meeting], at now: Date, leadMinutes: Int) -> MeetingNudge {
        let lead = TimeInterval(leadMinutes * 60)
        let visible = meetings.filter { now >= $0.start.addingTimeInterval(-lead) && now < $0.start.addingTimeInterval(visibleAfterStart) }
        if let next = visible.filter({ $0.start > now }).min(by: { $0.start < $1.start }) {
            return .soon(next, minutes: Int((next.start.timeIntervalSince(now) / 60).rounded(.up)))
        }
        if let running = visible.max(by: { $0.start < $1.start }) {
            return .now(running)
        }
        return .hidden
    }

    /// "📅 Standup in 8m", "📅 Standup now", or nil when hidden.
    public static func label(for nudge: MeetingNudge) -> String? {
        switch nudge {
        case .hidden: nil
        case .soon(let meeting, let minutes): "📅 \(cappedTitle(meeting.title)) in \(minutes)m"
        case .now(let meeting): "📅 \(cappedTitle(meeting.title)) now"
        }
    }

    public static func cappedTitle(_ title: String) -> String {
        guard title.count > titleLimit else { return title }
        return title.prefix(titleLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// For the menu: meetings that have not ended and start before the end of today.
    public static func restOfToday(_ meetings: [Meeting], at now: Date, calendar: Calendar = .current) -> [Meeting] {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return meetings.filter { $0.end > now && $0.start < endOfDay }.sorted { $0.start < $1.start }
    }

    /// The events.list window: today and tomorrow, so a meeting just after midnight still
    /// gets its nudge before midnight.
    public static func fetchWindow(at now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86_400)
        return DateInterval(start: start, end: end)
    }
}
