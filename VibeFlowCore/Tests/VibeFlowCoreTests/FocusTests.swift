import Foundation
import Testing
@testable import VibeFlowCore

@Suite("FocusEngine")
struct FocusEngineTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func run(_ commands: [(FocusCommand, Double)], preset: FocusPreset = .classic,
             from session: FocusSession? = nil) -> (session: FocusSession?, logged: [FocusBlock]) {
        var session = session
        var logged: [FocusBlock] = []
        for (command, at) in commands {
            let t = FocusEngine.apply(command, to: session, preset: preset, now: minutes(at), newID: { sessionID })
            session = t.session
            if let block = t.logged { logged.append(block) }
        }
        return (session, logged)
    }

    @Test func fullCycleLogsOnceAndWaitsForClicks() {
        let start = FocusEngine.apply(.start, to: nil, preset: .classic, now: t0, newID: { sessionID })
        #expect(start.session?.stage == .running(.focus, deadline: minutes(25)))

        let expired = FocusEngine.apply(.tick, to: start.session, preset: .classic, now: minutes(25))
        #expect(expired.ended == .focus)
        #expect(expired.logged == FocusBlock(id: "\(sessionID.uuidString)-1", start: t0, end: minutes(25), preset: .classic, minutes: 25))
        #expect(expired.session?.stage == .awaiting(.shortBreak))

        // A second expire on the same state logs nothing.
        let again = FocusEngine.apply(.tick, to: expired.session, preset: .classic, now: minutes(26))
        #expect(again.logged == nil && again.ended == nil)

        let breakEnd = run([(.start, 30), (.tick, 35)], from: expired.session)
        #expect(breakEnd.session?.stage == .awaiting(.focus))
        #expect(breakEnd.logged.isEmpty)
    }

    @Test func blockExpiredDuringSleepEndsAtTheDeadline() {
        let r = run([(.start, 0), (.tick, 8 * 60)])
        #expect(r.logged.count == 1)
        #expect(r.logged[0].end == minutes(25))
        #expect(r.session?.stage == .awaiting(.shortBreak))
    }

    @Test func commandAfterTheDeadlineLogsTheBlockFirst() {
        let paused = run([(.start, 0), (.pause, 25.1)])
        #expect(paused.logged.count == 1)
        #expect(paused.session?.stage == .awaiting(.shortBreak))

        let skipped = run([(.start, 0), (.skip, 25.1)])
        #expect(skipped.logged.count == 1)
        // Skip then applies to the awaited break.
        #expect(skipped.session?.stage == .awaiting(.focus))
    }

    @Test func pauseFreezesTheRemainingTimeAndResumeContinues() {
        let r = run([(.start, 0), (.pause, 10), (.tick, 60), (.resume, 60)])
        #expect(r.session?.stage == .running(.focus, deadline: minutes(75)))
        let done = run([(.tick, 75)], from: r.session)
        #expect(done.logged.first?.start == t0)
        #expect(done.logged.first?.minutes == 25)
    }

    @Test func longBreakAfterThePresetsCountThenTheCycleResets() {
        var commands: [(FocusCommand, Double)] = [(.start, 0)]
        var at = 0.0
        for block in 1...4 {
            at += 25; commands.append((.tick, at))
            if block < 4 { commands += [(.start, at), (.tick, at + 5), (.start, at + 5)]; at += 5 }
        }
        let r = run(commands)
        #expect(r.logged.count == 4)
        #expect(r.session?.stage == .awaiting(.longBreak))
        let after = run([(.start, at), (.tick, at + 15)], from: r.session)
        #expect(after.session?.stage == .awaiting(.focus))
        #expect(after.session?.completed == 0)
    }

    @Test func deepReachesItsLongBreakAfterTwo() {
        let r = run([(.start, 0), (.tick, 90), (.start, 90), (.tick, 110), (.start, 110), (.tick, 200)], preset: .deep)
        #expect(r.session?.stage == .awaiting(.longBreak))
    }

    @Test func twoCyclesInOneSessionLogEveryBlockOnce() {
        var session: FocusSession?
        var ids: [String] = []
        var now = 0.0
        session = FocusEngine.apply(.start, to: nil, preset: .deep, now: minutes(now), newID: { sessionID }).session
        for _ in 0..<4 {
            now += 90
            let t = FocusEngine.apply(.tick, to: session, preset: .deep, now: minutes(now))
            if let block = t.logged { ids.append(block.id) }
            session = FocusEngine.apply(.skip, to: t.session, preset: .deep, now: minutes(now)).session
            session = FocusEngine.apply(.start, to: session, preset: .deep, now: minutes(now)).session
        }
        #expect(ids.count == 4)
        #expect(Set(ids).count == 4)
    }

    @Test func skipRules() {
        // A skipped focus block is neither logged nor counted.
        let skippedFocus = run([(.start, 0), (.skip, 10)])
        #expect(skippedFocus.logged.isEmpty)
        #expect(skippedFocus.session?.completed == 0)
        #expect(skippedFocus.session?.stage == .awaiting(.shortBreak))

        // Skipping a short break keeps the count.
        let one = run([(.start, 0), (.tick, 25), (.skip, 25)])
        #expect(one.session?.completed == 1)
        #expect(one.session?.stage == .awaiting(.focus))

        // Skipping the long break, awaiting or running, resets the cycle.
        var deep = run([(.start, 0), (.tick, 90), (.start, 90), (.tick, 110), (.start, 110), (.tick, 200)], preset: .deep)
        #expect(deep.session?.stage == .awaiting(.longBreak))
        let skippedAwaiting = run([(.skip, 200)], from: deep.session)
        #expect(skippedAwaiting.session?.completed == 0)
        deep = run([(.start, 200), (.skip, 205)], from: deep.session)
        #expect(deep.session?.completed == 0)
        #expect(deep.session?.stage == .awaiting(.focus))
    }

    @Test func presetChangeMidBlockLogsTheSnapshot() {
        let r = run([(.start, 0), (.selectPreset(.deep), 5), (.tick, 25)])
        #expect(r.logged.first?.preset == .classic)
        #expect(r.logged.first?.minutes == 25)
        // The break uses the new preset.
        let brk = run([(.start, 25)], from: r.session)
        #expect(brk.session?.stage == .running(.shortBreak, deadline: minutes(45)))
    }

    @Test func presetChangesKeepEarnedProgress() {
        var r = run([(.start, 0)])
        for i in 1...3 { r = run([(.tick, Double(i) * 30 - 5), (.skip, Double(i) * 30 - 5), (.start, Double(i) * 30 - 5)], from: r.session) }
        // Three Classic blocks done; the fourth is running.
        r = run([(.tick, 115)], from: r.session)
        #expect(r.session?.completed == 4)
        // Recompute while awaiting: still the long break, and back again keeps the count.
        let deep = run([(.selectPreset(.deep), 116)], from: r.session)
        #expect(deep.session?.stage == .awaiting(.longBreak))
        let back = run([(.selectPreset(.classic), 117)], from: deep.session)
        #expect(back.session?.completed == 4)
        #expect(back.session?.stage == .awaiting(.longBreak))
    }

    @Test func presetChangeWhileAwaitingRecomputesTheBreak() {
        // Classic with 2 done awaits a short break; Deep (2 before long) makes it the long break.
        let r = run([(.start, 0), (.tick, 25), (.skip, 25), (.start, 25), (.tick, 50)])
        #expect(r.session?.stage == .awaiting(.shortBreak))
        let deep = run([(.selectPreset(.deep), 51)], from: r.session)
        #expect(deep.session?.stage == .awaiting(.longBreak))
        #expect(FocusEngine.dots(for: deep.session, preset: .deep) == (2, 2))
    }

    @Test func stopDiscardsThePartialBlock() {
        let r = run([(.start, 0), (.stop, 20)])
        #expect(r.session == nil)
        #expect(r.logged.isEmpty)
    }

    @Test func staleNotificationActionsAreIgnored() {
        let r = run([(.start, 0), (.tick, 25)])
        let session = r.session!
        #expect(FocusEngine.accepts(sessionID: sessionID, blockIndex: 1, phase: .shortBreak, session: session))
        #expect(!FocusEngine.accepts(sessionID: sessionID, blockIndex: 1, phase: .longBreak, session: session))
        #expect(!FocusEngine.accepts(sessionID: UUID(), blockIndex: 1, phase: .shortBreak, session: session))
        #expect(!FocusEngine.accepts(sessionID: sessionID, blockIndex: 0, phase: .shortBreak, session: session))
        // Already started from the menu.
        let started = run([(.start, 26)], from: session)
        #expect(!FocusEngine.accepts(sessionID: sessionID, blockIndex: 1, phase: .shortBreak, session: started.session))
        #expect(!FocusEngine.accepts(sessionID: sessionID, blockIndex: 1, phase: .shortBreak, session: nil))
    }
}

@Suite("FocusStats")
struct FocusStatsTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    func berlin(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }
    func block(_ id: String, end: String, minutes: Int = 25) -> FocusBlock {
        let endDate = berlin(end)
        return FocusBlock(id: id, start: endDate.addingTimeInterval(-Double(minutes) * 60), end: endDate, preset: .classic, minutes: minutes)
    }

    @Test func blocksCountOnTheDayTheyEnd() {
        // 23:50 to 00:15 Berlin time crosses midnight and counts on the 2nd.
        let crossing = block("a", end: "2026-11-01T23:15:00Z")
        let earlier = block("b", end: "2026-11-01T10:00:00Z")
        let now = berlin("2026-11-02T08:00:00Z")
        let today = FocusStats.today([crossing, earlier], now: now, calendar: calendar)
        #expect(today.blocks == 1)
        #expect(today.minutes == 25)
    }

    @Test func weekIsSevenDaysOldestFirst() {
        let now = berlin("2026-11-02T08:00:00Z")
        let week = FocusStats.week([block("a", end: "2026-11-02T07:00:00Z", minutes: 50),
                                    block("b", end: "2026-10-27T12:00:00Z"),
                                    block("c", end: "2026-10-26T12:00:00Z")], now: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.last?.minutes == 50)
        #expect(week.first?.minutes == 25) // 27 October; the 26th is outside the week
        #expect(week.map(\.minutes).reduce(0, +) == 75)
    }

    @Test func formatting() {
        #expect(FocusStats.countdown(25 * 60) == "25:00")
        #expect(FocusStats.countdown(61.2) == "1:02")
        #expect(FocusStats.duration(minutes: 75) == "1 h 15 min")
        #expect(FocusStats.duration(minutes: 45) == "45 min")
    }
}

@Suite("FocusLog") @MainActor
struct FocusLogTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "vibeflow-focus-\(UUID().uuidString)")
    var file: URL { folder.appending(path: "focus.json") }
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let sessionID = UUID()
    var sample: FocusFile {
        let session = FocusSession(id: sessionID, stage: .paused(.focus, remaining: 612.5), preset: .long, completed: 2,
                                   blockIndex: 3, blockStart: t0, blockPreset: .classic)
        return FocusFile(active: session, blocks: [FocusBlock(id: "x-1", start: t0, end: t0.addingTimeInterval(1500), preset: .classic, minutes: 25)])
    }

    @Test func relaunchRestoresEverything() throws {
        let log = FocusLog(fileURL: file)
        #expect(log.commit(sample))
        #expect(FocusLog(fileURL: file).file == sample)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func failedWriteKeepsThePreviousState() throws {
        // The parent "folder" is a file, so creating the directory fails.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "blocker")
        try Data().write(to: blocker)
        let log = FocusLog(fileURL: blocker.appending(path: "focus.json"))
        #expect(!log.commit(sample))
        #expect(log.file == FocusFile())
    }

    @Test func duplicateBlockIdsAreDroppedOnLoad() throws {
        var doubled = sample
        doubled.blocks.append(doubled.blocks[0])
        #expect(FocusLog(fileURL: file).commit(doubled))
        #expect(FocusLog(fileURL: file).file.blocks.count == 1)
    }

    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let log = FocusLog(fileURL: file)
        #expect(log.file == FocusFile())
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("focus.broken-") && $0.hasSuffix(".json") })
        #expect(!names.contains("focus.json"))
    }
}
