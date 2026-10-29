import Foundation
import Testing
@testable import VibeFlowCore

/// The Dev menu names the branch and commit it was built from (docs/designs/dev-prod-channels.md, P3).
@Suite("BuildStamp")
struct BuildStampTests {
    let info: [String: Any] = [
        "VFGitBranch": "smart-read",
        "VFGitCommit": "8767a8f*",
        "VFBuildDate": "2026-10-29T14:40:00Z",
    ]
    let locale = Locale(identifier: "en_GB")
    let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    func date(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }

    @Test func readsWhatDevShStamps() throws {
        let stamp = try #require(BuildStamp(info: info))
        #expect(stamp.branch == "smart-read")
        #expect(stamp.commit == "8767a8f*")
        #expect(stamp.built == (try date("2026-10-29T14:40:00Z")))
    }

    @Test func aBuildFromXcodeHasNoStamp() {
        #expect(BuildStamp(info: ["VFGitBranch": "", "VFGitCommit": "", "VFBuildDate": ""]) == nil)
        #expect(BuildStamp(info: [:]) == nil)
        #expect(BuildStamp(info: ["VFGitBranch": "main", "VFGitCommit": "abc1234", "VFBuildDate": "today"]) == nil)
    }

    @Test func todaysBuildShowsTheTime() throws {
        let stamp = try #require(BuildStamp(info: info))
        let title = stamp.menuTitle(now: try date("2026-10-29T20:00:00Z"), calendar: berlin, locale: locale)
        #expect(title == "smart-read · 8767a8f* · built 15:40")
    }

    @Test func anOlderBuildShowsTheDay() throws {
        let stamp = try #require(BuildStamp(info: info))
        let title = stamp.menuTitle(now: try date("2026-10-31T09:00:00Z"), calendar: berlin, locale: locale)
        #expect(title.hasPrefix("smart-read · 8767a8f* · built "))
        #expect(title.contains("29") && title.contains("Oct") && title.contains("15:40"), "\(title)")
    }
}
