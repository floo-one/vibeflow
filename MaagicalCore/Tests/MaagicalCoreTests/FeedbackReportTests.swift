import Foundation
import Testing
@testable import MaagicalCore

/// Send Feedback reports carry the context to fix a bug and nothing personal
/// (docs/designs/feedback.md, D4, D5, D7, D12).
@Suite("FeedbackReport")
struct FeedbackReportTests {
    let home = "/Users/someone"

    func facts(environment: FeedbackReport.Environment = .stable, nightlyChannel: Bool = false,
               settings: [FeedbackReport.Setting] = []) -> FeedbackReport.Facts {
        FeedbackReport.Facts(version: "1.4.0", build: "3.52", environment: environment, nightlyChannel: nightlyChannel,
                             pane: "smartRead", macOS: "26.1", keyboardLayout: "German",
                             accessibilityGranted: true, microphoneGranted: false, settings: settings)
    }

    func report(_ kind: FeedbackReport.Kind = .bug, note: String = "smart read stops",
                facts: FeedbackReport.Facts? = nil, logs: FeedbackReport.Logs = .lines(["Read failed: x"])) -> FeedbackReport {
        FeedbackReport(kind: kind, note: note, facts: facts ?? self.facts(), logs: logs, home: home)
    }

    // MARK: Environment (D5)

    @Test(arguments: [
        (true, nil, FeedbackReport.Environment.dev),
        (true, "7dfb43b", .dev),
        (false, "7dfb43b", .nightly),
        (false, "", .stable),
        (false, nil, .stable),
    ] as [(Bool, String?, FeedbackReport.Environment)])
    func environmentComesFromTheRunningBuild(isDebug: Bool, commit: String?, expected: FeedbackReport.Environment) {
        #expect(FeedbackReport.Environment.of(isDebug: isDebug, commit: commit) == expected)
    }

    @Test func theChannelSettingIsItsOwnTag() {
        let switched = report(facts: facts(environment: .stable, nightlyChannel: true))
        #expect(switched.environment == .stable)
        #expect(switched.tags["channel"] == "nightly")
        #expect(report().tags["channel"] == "stable")
    }

    // MARK: Shape

    @Test func carriesReleaseMessageAndTags() {
        let r = report()
        #expect(r.release == "vibeflow@1.4.0+3.52")
        #expect(r.message == "[Bug] smart read stops")
        #expect(r.tags == ["kind": "bug", "channel": "stable", "macos": "26.1", "pane": "smartRead",
                           "layout": "German", "accessibility": "granted", "microphone": "missing"])
    }

    @Test func settingsClosedHasNoPaneTag() {
        var f = facts()
        f.pane = nil
        let r = report(facts: f)
        #expect(r.tags["pane"] == nil)
        #expect(r.render().contains("Settings pane: closed"))
    }

    @Test(arguments: FeedbackReport.Kind.allCases)
    func everyKindHasTheSameShape(kind: FeedbackReport.Kind) {
        let r = report(kind, logs: .lines(["Dictation finished: Pasted"]))
        #expect(r.message.hasPrefix("[\(kind.title)] "))
        #expect(r.logFile == "Dictation finished: Pasted")
        #expect(r.render().contains("Logs (last 10 minutes, 1 lines, attached as vibeflow-log.txt)\nDictation finished: Pasted"))
    }

    @Test func thePreviewIsWhatGetsSent() throws {
        let r = report(facts: facts(settings: [.init("voice model", "eleven_flash_v2_5")]))
        let preview = r.render()
        #expect(preview.hasPrefix(r.message + "\n\n"))
        #expect(preview.contains("Maagical 1.4.0 (3.52), stable"))
        #expect(preview.contains("Settings\n  voice model: eleven_flash_v2_5"))
        let logFile = try #require(r.logFile)
        #expect(preview.hasSuffix(logFile))
    }

    @Test func aBuildStampNamesBranchAndCommit() throws {
        var f = facts(environment: .nightly)
        f.stamp = try #require(BuildStamp(info: ["VFGitBranch": "main", "VFGitCommit": "7dfb43b",
                                                 "VFBuildDate": "2026-11-01T14:00:00Z"]))
        #expect(report(facts: f).render().contains("Built from main @ 7dfb43b, 2026-11-01T14:00:00Z"))
    }

    @Test func unreadableLogsStillMakeAReport() {
        let r = report(logs: .unavailable(reason: "store not available"))
        #expect(r.logFile == nil)
        #expect(r.render().hasSuffix("Logs unavailable: store not available"))
    }

    // MARK: Scrubbing (D4)

    @Test(arguments: [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
        "sk-proj-ABCDEFGHIJKLMNOPQRSTUV",
        "gsk_ABCDEFGHIJKLMNOPQRSTUVWX",
        "sk_0123456789abcdef0123456789abcdef",
        "ya29.a0AfB_byC-some.access_token",
        "1//0gLongRefreshTokenValue-xyz",
        "QWxhZGRpbjpvcGVuIHNlc2FtZQQWxhZGRpbjpvcGVuIHNl",
    ])
    func keyShapedTextIsRedacted(secret: String) {
        let scrubbed = FeedbackReport.scrub("token \(secret) end", home: home)
        #expect(scrubbed == "token ‹redacted› end")
    }

    @Test func theHomeFolderBecomesTilde() {
        let line = "launch: quitting older copy pid=42 at /Users/someone/Applications/VibeFlow Dev.app"
        #expect(FeedbackReport.scrub(line, home: home) == "launch: quitting older copy pid=42 at ~/Applications/VibeFlow Dev.app")
    }

    @Test func ordinaryLogLinesSurvive() {
        let lines = [
            "Capture in com.apple.Safari: Accessibility gave 812 characters",
            "Recording from MacBook Pro Microphone (BuiltInMicrophoneDevice)",
            "Read failed: ElevenLabs error 429: rate limited",
            "Input 2F3A9C1E-7B44-4E0A-9D5B-1C2D3E4F5A6B not found, using the default input",
        ]
        for line in lines { #expect(FeedbackReport.scrub(line, home: home) == line) }
    }

    @Test func everyOutputIsScrubbed() {
        let key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"
        var f = facts(settings: [.init("model", key)])
        f.keyboardLayout = key
        let r = report(note: "my key is \(key)", facts: f, logs: .lines(["header \(key)", "path /Users/someone/x"]))
        #expect(!r.message.contains(key))
        #expect(!r.tags.values.contains { $0.contains(key) })
        #expect(!(r.logFile ?? "").contains(key))
        #expect(!r.render().contains(key))
        #expect(!r.render().contains(home))
    }

    // MARK: Size cap

    @Test func theCapKeepsTheNewestLines() {
        let lines = (1...5).map { "line \($0)" }          // 7 bytes each incl. newline
        let (kept, dropped) = FeedbackReport.cap(lines, bytes: 21)
        #expect(kept == ["line 3", "line 4", "line 5"])
        #expect(dropped == 2)
        #expect(FeedbackReport.cap(lines, bytes: 1_000) == (kept: lines, dropped: 0))
        #expect(FeedbackReport.cap([], bytes: 10) == (kept: [], dropped: 0))
    }

    @Test func aLongLogSaysHowManyLinesWereDropped() throws {
        let line = String(repeating: "ab ", count: 33)     // 100 bytes with newline, nothing key-like
        let r = report(logs: .lines(Array(repeating: line, count: 2_500)))
        let file = try #require(r.logFile)
        #expect(file.hasPrefix("… 500 older lines dropped\n"))
        #expect(file.utf8.count <= FeedbackReport.logCap + 40)
    }
}

/// The settings snapshot is an allowlist that never carries personal words (F7).
@MainActor @Suite("FeedbackReport settings")
struct FeedbackReportSettingsTests {
    @Test func vocabularyAndCalendarsAreCountsOnly() {
        let defaults = UserDefaults(suiteName: "feedback-tests-\(UUID())")!
        let preferences = Preferences(defaults: defaults)
        preferences.vocabulary = "Kubernetes, Floo\nVibeFlow"
        preferences.meetingsCalendars = ["someone@example.com", "team@example.com"]
        let settings = FeedbackReport.settings(from: preferences)
        let text = settings.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        #expect(settings.contains(.init("vocabulary", "3 terms")))
        #expect(settings.contains(.init("meeting calendars", "2")))
        for word in ["Kubernetes", "Floo", "someone@example.com", "team@example.com"] {
            #expect(!text.contains(word), "\(word) leaked")
        }
    }

    @Test func noCalendarsChosenSaysOwnCalendar() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "feedback-tests-\(UUID())")!)
        #expect(FeedbackReport.settings(from: preferences).contains(.init("meeting calendars", "own calendar")))
    }
}
