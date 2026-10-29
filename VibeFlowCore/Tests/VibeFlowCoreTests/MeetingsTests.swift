import Foundation
import Testing
@testable import VibeFlowCore

private let me = "florian@example.com"
private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

/// A timed meeting with one other person, the shape most real invites have.
private func event(_ id: String = "e1", summary: String = "Standup", start: String = "2026-10-29T09:00:00Z",
                   end: String = "2026-10-29T09:30:00Z", attendees: [CalendarEvent.Attendee]? = nil,
                   configure: (inout CalendarEvent) -> Void = { _ in }) -> CalendarEvent {
    var event = CalendarEvent(
        id: id, summary: summary, start: .init(dateTime: start), end: .init(dateTime: end),
        attendees: attendees ?? [.init(email: me, responseStatus: "accepted"), .init(email: "alex@example.com", responseStatus: "accepted")])
    configure(&event)
    return event
}

@Suite struct MeetingFilterTests {
    private func kept(_ event: CalendarEvent, me: String = me) -> Bool {
        MeetingFilter.meeting(from: event, calendarID: "primary", me: me) != nil
    }

    @Test func aTimedMeetingWithSomeoneElseCounts() throws {
        let meeting = try #require(MeetingFilter.meeting(from: event(), calendarID: "primary", me: me))
        #expect(meeting.title == "Standup")
        #expect(meeting.start == utc("2026-10-29T09:00:00Z"))
        #expect(meeting.end == utc("2026-10-29T09:30:00Z"))
        #expect(meeting.calendarID == "primary")
    }

    @Test(arguments: ["focusTime", "outOfOffice", "workingLocation", "birthday"])
    func nonMeetingEventTypesAreDropped(type: String) {
        #expect(!kept(event { $0.eventType = type }))
    }

    @Test func fromGmailAndMissingTypeCount() {
        #expect(kept(event { $0.eventType = "fromGmail" }))
        #expect(kept(event { $0.eventType = nil }))
    }

    @Test func cancelledAllDayAndFreeAreDropped() {
        #expect(!kept(event { $0.status = "cancelled" }))
        #expect(!kept(event { $0.start = .init(date: "2026-10-29"); $0.end = .init(date: "2026-10-30") }))
        #expect(!kept(event { $0.transparency = "transparent" }))
        #expect(kept(event { $0.status = "tentative" }))
    }

    @Test func declinedByYouIsDroppedCaseInsensitively() {
        let attendees: [CalendarEvent.Attendee] = [.init(email: "Florian@Example.com", responseStatus: "declined"),
                                                   .init(email: "alex@example.com", responseStatus: "accepted")]
        #expect(!kept(event(attendees: attendees)))
    }

    @Test func nobodyButYouIsDropped() {
        #expect(!kept(event(attendees: [])))
        #expect(!kept(event { $0.attendees = nil }))
        #expect(!kept(event(attendees: [.init(email: me)])))
        // A booked room is not a person.
        #expect(!kept(event(attendees: [.init(email: me), .init(email: "room-3@resource.calendar.google.com", resource: true)])))
    }

    // Value: protects=invites with a hidden guest list (only you visible) count when someone else invited you, while solo blocks on your own, a colleague's or a secondary calendar do not; fails_when=the organizer rule is dropped or counts events you are not invited to; why_new=no fixture had a hidden guest list; seam=none; no_claim=Google's real attendee truncation (fixture)
    @Test func hiddenGuestListCountsWhenSomeoneElseInvitedYou() {
        #expect(kept(event(attendees: [.init(email: me)]) { $0.organizer = .init(email: "host@example.com") }))
        #expect(!kept(event(attendees: [.init(email: me)]) { $0.organizer = .init(email: "Florian@Example.com") }))
        // A colleague's own lunch on their calendar, and an event on a secondary calendar.
        #expect(MeetingFilter.meeting(from: event { $0.attendees = nil; $0.organizer = .init(email: "colleague@example.com") },
                                      calendarID: "colleague@example.com", me: me) == nil)
        #expect(MeetingFilter.meeting(from: event { $0.attendees = nil; $0.organizer = .init(email: "abc123@group.calendar.google.com") },
                                      calendarID: "abc123@group.calendar.google.com", me: me) == nil)
    }

    /// R9: on a colleague's calendar, `self` would be the colleague. Only your own email counts.
    @Test func sharedCalendarJudgesYouNotTheOwner() {
        let colleagueDeclined: [CalendarEvent.Attendee] = [
            .init(email: "colleague@example.com", responseStatus: "declined"),
            .init(email: me, responseStatus: "accepted"),
            .init(email: "alex@example.com"),
        ]
        #expect(MeetingFilter.meeting(from: event(attendees: colleagueDeclined), calendarID: "colleague@example.com", me: me) != nil)

        let colleagueAlone: [CalendarEvent.Attendee] = [.init(email: "colleague@example.com"), .init(email: "alex@example.com")]
        #expect(MeetingFilter.meeting(from: event(attendees: colleagueAlone), calendarID: "colleague@example.com", me: me) != nil)
    }

    @Test func blankTitleAndMissingEnd() throws {
        let meeting = try #require(MeetingFilter.meeting(from: event(summary: "  ") { $0.end = nil }, calendarID: "primary", me: me))
        #expect(meeting.title == "(No title)")
        #expect(meeting.end == meeting.start)
    }

    @Test func sameEventOnTwoCalendarsIsKeptOnceSortedByStart() {
        let early = event("early", summary: "Early", start: "2026-10-29T08:00:00Z", end: "2026-10-29T08:30:00Z")
        let shared = event("shared")
        let meetings = MeetingFilter.meetings(from: [("primary", [shared]), ("colleague@example.com", [shared, early])], me: me)
        #expect(meetings.map(\.id) == ["early", "shared"])
        #expect(meetings.last?.calendarID == "primary")
    }

    /// The payload shape Google sends, offsets and all (trimmed from the T1b spike run).
    @Test func decodesARealEventsPage() throws {
        let json = """
        {"items":[
          {"id":"wl1","status":"confirmed","eventType":"workingLocation","summary":"Office",
           "start":{"date":"2026-10-29"},"end":{"date":"2026-10-30"},"transparency":"transparent"},
          {"id":"m1","status":"confirmed","eventType":"default","summary":"Alex and Florian",
           "htmlLink":"https://www.google.com/calendar/event?eid=abc",
           "start":{"dateTime":"2026-10-29T16:30:00+07:00","timeZone":"Asia/Bangkok"},
           "end":{"dateTime":"2026-10-29T17:00:00+07:00"},
           "organizer":{"email":"alex@example.com","displayName":"Alex"},
           "attendees":[{"email":"alex@example.com","organizer":true,"responseStatus":"accepted"},
                        {"email":"florian@example.com","self":true,"responseStatus":"needsAction"}],
           "conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1-555"},
                                            {"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}],
                             "conferenceSolution":{"name":"Google Meet"}}}
        ]}
        """
        struct Page: Decodable { let items: [CalendarEvent] }
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        let meetings = MeetingFilter.meetings(from: [("primary", page.items)], me: me)
        #expect(meetings.count == 1)
        let meeting = try #require(meetings.first)
        #expect(meeting.start == utc("2026-10-29T09:30:00Z"))
        #expect(meeting.organizer == "Alex")
        #expect(meeting.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(meeting.htmlLink?.host() == "www.google.com")
    }
}

@Suite struct JoinLinkTests {
    @Test func hangoutLinkWinsThenVideoEntryPoint() {
        let both = event {
            $0.hangoutLink = "https://meet.google.com/aaa-bbbb-ccc"
            $0.conferenceData = .init(entryPoints: [.init(entryPointType: "video", uri: "https://zoom.us/j/1")])
        }
        #expect(JoinLink.find(in: both)?.absoluteString == "https://meet.google.com/aaa-bbbb-ccc")

        let phoneFirst = event {
            $0.conferenceData = .init(entryPoints: [.init(entryPointType: "phone", uri: "tel:+1"),
                                                    .init(entryPointType: "video", uri: "https://us02web.zoom.us/j/123")])
        }
        #expect(JoinLink.find(in: phoneFirst)?.absoluteString == "https://us02web.zoom.us/j/123")
    }

    @Test func callLinksInLocationOrDescription() {
        #expect(JoinLink.find(in: event { $0.location = "https://us06web.zoom.us/j/8812?pwd=abc." })?.absoluteString
                == "https://us06web.zoom.us/j/8812?pwd=abc")
        let teams = #"Join: <a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0">Click here</a>"#
        #expect(JoinLink.find(in: event { $0.description = teams })?.host() == "teams.microsoft.com")
        #expect(JoinLink.find(in: event { $0.description = "(https://acme.webex.com/meet/florian)" })?.absoluteString
                == "https://acme.webex.com/meet/florian")
    }

    // Value: protects=Join and the calendar link only ever open web URLs; fails_when=a file:, smb: or custom-scheme conference link becomes clickable; why_new=only https Meet/Zoom links were tested; seam=none; no_claim=what Google actually lets into conferenceData (fixture)
    @Test func onlyWebLinksAreOpened() {
        #expect(JoinLink.find(in: event { $0.hangoutLink = "file:///Applications/Calculator.app" }) == nil)
        #expect(JoinLink.find(in: event {
            $0.conferenceData = .init(entryPoints: [.init(entryPointType: "video", uri: "smb://share.example.com/x")])
        }) == nil)
        #expect(JoinLink.find(in: event { $0.hangoutLink = "https://meet.google.com/abc-defg-hij" })?.host() == "meet.google.com")
        let meeting = MeetingFilter.meeting(from: event { $0.htmlLink = "vibeflow-evil://x" }, calendarID: "primary", me: me)
        #expect(meeting?.htmlLink == nil)
    }

    // Value: protects=Zoom links inside HTML descriptions keep every query parameter (the passcode); fails_when=&amp; reaches URL parsing and pwd becomes amp;pwd; why_new=the HTML test link had no second parameter; seam=none; no_claim=every HTML entity Google may emit (only &amp; and &#38;)
    @Test func htmlEscapedAmpersandsKeepThePasscode() throws {
        let html = #"<a href="https://us06web.zoom.us/j/8812?omn=123&amp;pwd=abc">Join Zoom</a>"#
        let link = try #require(JoinLink.find(in: event { $0.description = html }))
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "pwd" }?.value == "abc")
    }

    // Value: protects=events with fractional-second timestamps still count; fails_when=the default ISO style rejects .123 and the meeting silently disappears; why_new=every fixture used whole seconds; seam=none; no_claim=how often Google sends fractions
    @Test func fractionalSecondsParse() {
        #expect(MeetingFilter.parseDate("2026-10-29T09:00:00.123Z") != nil)
        #expect(MeetingFilter.parseDate("2026-10-29T16:30:00+07:00") == utc("2026-10-29T09:30:00Z"))
        #expect(MeetingFilter.parseDate("not a date") == nil)
    }

    @Test func otherLinksAndLookalikesAreNotJoinLinks() {
        #expect(JoinLink.find(in: event { $0.location = "Room 4, https://maps.google.com/x" }) == nil)
        #expect(JoinLink.find(in: event { $0.description = "https://notzoom.us/j/1 and http://zoom.us/j/2" }) == nil)
        #expect(JoinLink.find(in: event()) == nil)
    }

    @Test func firstCallLinkSkipsEarlierOtherLinks() {
        let text = "Agenda https://docs.google.com/doc then https://meet.google.com/xyz-abcd-efg"
        #expect(JoinLink.firstCallLink(in: text)?.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }
}

@Suite struct MeetingScheduleTests {
    private func meeting(_ id: String, _ start: String, title: String = "Standup") -> Meeting {
        Meeting(id: id, title: title, start: utc(start), end: utc(start).addingTimeInterval(1800), calendarID: "primary")
    }
    private let standup = Meeting(id: "s", title: "Standup", start: try! Date("2026-10-29T10:00:00Z", strategy: .iso8601),
                                  end: try! Date("2026-10-29T10:30:00Z", strategy: .iso8601), calendarID: "primary")

    @Test func hiddenUntilLeadTimeThenCountsDown() {
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T09:49:59Z"), leadMinutes: 10) == .hidden)
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T09:50:00Z"), leadMinutes: 10) == .soon(standup, minutes: 10))
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T09:52:00Z"), leadMinutes: 10) == .soon(standup, minutes: 8))
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T09:59:30Z"), leadMinutes: 10) == .soon(standup, minutes: 1))
    }

    @Test func nowFromStartAndHiddenFiveMinutesLater() {
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T10:00:00Z"), leadMinutes: 10) == .now(standup))
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T10:04:59Z"), leadMinutes: 10) == .now(standup))
        #expect(MeetingSchedule.nudge(for: [standup], at: utc("2026-10-29T10:05:00Z"), leadMinutes: 10) == .hidden)
    }

    @Test(arguments: [(5, "2026-10-29T09:54:59Z", false), (5, "2026-10-29T09:55:00Z", true),
                      (15, "2026-10-29T09:44:59Z", false), (15, "2026-10-29T09:45:00Z", true)])
    func leadTimeMovesTheStart(lead: Int, at: String, shows: Bool) {
        #expect((MeetingSchedule.nudge(for: [standup], at: utc(at), leadMinutes: lead) != .hidden) == shows)
    }

    @Test func overlappingMeetingsTheNextOneWins() {
        let running = meeting("a", "2026-10-29T09:58:00Z")
        let next = meeting("b", "2026-10-29T10:02:00Z")
        let later = meeting("c", "2026-10-29T10:05:00Z")
        #expect(MeetingSchedule.nudge(for: [later, running, next], at: utc("2026-10-29T10:00:00Z"), leadMinutes: 10)
                == .soon(next, minutes: 2))
        // Two running: the one that started last.
        let first = meeting("x", "2026-10-29T09:57:00Z")
        #expect(MeetingSchedule.nudge(for: [running, first], at: utc("2026-10-29T10:00:00Z"), leadMinutes: 10) == .now(running))
    }

    @Test func meetingJustAfterMidnightNudgesBeforeMidnight() {
        let late = meeting("m", "2026-10-30T00:05:00Z")
        #expect(MeetingSchedule.nudge(for: [late], at: utc("2026-10-29T23:57:00Z"), leadMinutes: 10) == .soon(late, minutes: 8))
    }

    @Test func labelsAndTitleCap() {
        #expect(MeetingSchedule.label(for: .soon(standup, minutes: 8)) == "📅 Standup in 8m")
        #expect(MeetingSchedule.label(for: .now(standup)) == "📅 Standup now")
        #expect(MeetingSchedule.label(for: .hidden) == nil)
        #expect(MeetingSchedule.cappedTitle("Quarterly planning review") == "Quarterly plannin…")
        #expect(MeetingSchedule.cappedTitle("Quarterly plannin…").count == 18)
        #expect(MeetingSchedule.cappedTitle("Exactly eighteen!!") == "Exactly eighteen!!")
        #expect(MeetingSchedule.cappedTitle("Weekly sync with  ops") == "Weekly sync with…")
    }

    @Test func restOfTodayDropsEndedAndTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let ended = meeting("ended", "2026-10-29T07:00:00Z")
        let running = meeting("running", "2026-10-29T09:45:00Z")
        let tonight = meeting("tonight", "2026-10-29T21:30:00Z")
        let tomorrow = meeting("tomorrow", "2026-10-29T23:30:00Z") // 00:30 in Berlin
        let rest = MeetingSchedule.restOfToday([tomorrow, tonight, ended, running], at: utc("2026-10-29T10:00:00Z"), calendar: calendar)
        #expect(rest.map(\.id) == ["running", "tonight"])
    }

    /// Berlin's 25 October 2026 has 25 hours; the window still runs midnight to midnight.
    @Test func fetchWindowSpansTwoLocalDaysAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let window = MeetingSchedule.fetchWindow(at: utc("2026-10-25T12:00:00Z"), calendar: calendar)
        #expect(window.start == utc("2026-10-24T22:00:00Z"))
        #expect(window.end == utc("2026-10-26T23:00:00Z"))
    }
}

@MainActor @Suite struct MeetingsPreferencesTests {
    @Test func defaultsAndPersistence() {
        let defaults = UserDefaults(suiteName: "meetings-tests-\(UUID())")!
        let fresh = Preferences(defaults: defaults)
        #expect(fresh.meetingsEnabled)
        #expect(fresh.meetingsLeadMinutes == 10)
        #expect(fresh.meetingsCalendars == nil)

        fresh.meetingsEnabled = false
        fresh.meetingsLeadMinutes = 15
        fresh.meetingsCalendars = ["florian@example.com", "colleague@example.com"]
        let reloaded = Preferences(defaults: defaults)
        #expect(!reloaded.meetingsEnabled)
        #expect(reloaded.meetingsLeadMinutes == 15)
        #expect(reloaded.meetingsCalendars == ["florian@example.com", "colleague@example.com"])

        reloaded.meetingsCalendars = nil
        defaults.set(7, forKey: "meetings.leadMinutes")
        #expect(Preferences(defaults: defaults).meetingsCalendars == nil)
        #expect(Preferences(defaults: defaults).meetingsLeadMinutes == 10)
    }
}
