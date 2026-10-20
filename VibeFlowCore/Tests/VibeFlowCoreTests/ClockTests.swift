import Foundation
import Testing
@testable import VibeFlowCore

@Suite struct ClockFormatTests {
    private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }
    private let newYork = WorldClock(zoneID: "America/New_York", city: "New York", countryCode: "US")

    @Test func labelShowsEachClockWithItsFlag() {
        #expect(ClockFormat.label(for: [.berlin, newYork], at: utc("2026-07-01T12:05:30Z")) == "🇩🇪 14:05  🇺🇸 08:05")
        #expect(ClockFormat.label(for: [], at: utc("2026-07-01T12:05:30Z")) == "")
    }

    @Test func detailFollowsDaylightSaving() {
        #expect(ClockFormat.detail(for: .berlin, at: utc("2026-07-01T12:05:30Z")) == "🇩🇪 Berlin: Wednesday 1 July, 14:05 (UTC+2)")
        #expect(ClockFormat.detail(for: .berlin, at: utc("2026-12-24T23:30:00Z")) == "🇩🇪 Berlin: Friday 25 December, 00:30 (UTC+1)")
    }

    @Test func dstSwitchOnLastSundayOfOctober() {
        #expect(ClockFormat.time(utc("2026-10-25T00:59:00Z"), in: WorldClock.berlin.timeZone) == "02:59")
        #expect(ClockFormat.time(utc("2026-10-25T01:00:00Z"), in: WorldClock.berlin.timeZone) == "02:00")
    }

    @Test func offsetsWithMinutesAndNegatives() {
        let date = utc("2026-01-15T12:00:00Z")
        #expect(ClockFormat.offset(date, in: TimeZone(identifier: "Asia/Kolkata")!) == "UTC+5:30")
        #expect(ClockFormat.offset(date, in: TimeZone(identifier: "America/St_Johns")!) == "UTC-3:30")
        #expect(ClockFormat.offset(date, in: TimeZone(identifier: "UTC")!) == "UTC")
    }

    @Test func nextMinuteIsTheBoundary() {
        #expect(ClockFormat.nextMinute(after: utc("2026-07-01T12:05:30Z")) == utc("2026-07-01T12:06:00Z"))
        #expect(ClockFormat.nextMinute(after: utc("2026-07-01T12:05:00Z")) == utc("2026-07-01T12:06:00Z"))
    }

    @Test func flags() {
        #expect(WorldClock.berlin.flag == "🇩🇪")
        #expect(WorldClock(zoneID: "UTC", city: "UTC", countryCode: "").flag == "🌐")
    }
}

@Suite struct TimeZoneCatalogTests {
    private let catalog = TimeZoneCatalog.bundled

    @Test func bundledListLoadsAndEveryZoneResolves() {
        #expect(catalog.zones.count > 300)
        #expect(catalog.zones.allSatisfy { TimeZone(identifier: $0.id) != nil })
    }

    @Test func cityKeepsTheCityTheUserSearchedFor() {
        let first = catalog.search("Munich").first
        #expect(first == WorldClock(zoneID: "Europe/Berlin", city: "Munich", countryCode: "DE"))
    }

    @Test func accentBlind() {
        #expect(catalog.search("koln").first?.city == "Köln")
    }

    @Test func countryNameAndCode() {
        #expect(catalog.search("Germany").first == .berlin)
        #expect(catalog.search("de").contains(.berlin))
        #expect(catalog.search("United States", limit: 50).count > 5)
    }

    @Test func abbreviationAndIANAID() {
        #expect(catalog.search("CEST").contains { $0.zoneID == "Europe/Berlin" })
        #expect(catalog.search("America/New_York").first?.zoneID == "America/New_York")
        #expect(catalog.search("new york").first?.zoneID == "America/New_York")
    }

    @Test func kolkataResolvesThroughItsAlias() {
        let mumbai = catalog.search("Mumbai").first
        #expect(mumbai != nil)
        #expect(mumbai.map { TimeZone(identifier: $0.zoneID) != nil } == true)
    }

    @Test func utcIsAvailable() {
        #expect(catalog.search("UTC").first?.flag == "🌐")
    }

    @Test func emptyQueryFindsNothing() {
        #expect(catalog.search("  ").isEmpty)
    }
}

@MainActor @Suite struct WorldClockPreferencesTests {
    @Test func defaultsToBerlinAndPersistsOrder() {
        let defaults = UserDefaults(suiteName: "clock-tests-\(UUID())")!
        #expect(Preferences(defaults: defaults).worldClocks == [.berlin])
        let tokyo = WorldClock(zoneID: "Asia/Tokyo", city: "Tokyo", countryCode: "JP")
        Preferences(defaults: defaults).worldClocks = [tokyo, .berlin]
        #expect(Preferences(defaults: defaults).worldClocks == [tokyo, .berlin])
        Preferences(defaults: defaults).worldClocks = []
        #expect(Preferences(defaults: defaults).worldClocks.isEmpty)
    }
}
