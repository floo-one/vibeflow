import Foundation
import Testing
@testable import VibeFlowCore

@MainActor
private final class FakeAssertion: PowerAssertion {
    var held: Bool?
    var refuses = false
    var begins = 0

    func begin(keepsDisplayOn: Bool) -> Bool {
        begins += 1
        if refuses { return false }
        held = keepsDisplayOn
        return true
    }

    func end() { held = nil }
}

@MainActor
@Suite struct KeepAwakeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func timedSessionHoldsTheAssertionUntilItExpires() {
        var now = start
        let assertion = FakeAssertion()
        let awake = KeepAwake(assertion: assertion, keepsDisplayOn: true, now: { now })
        #expect(awake.start(.minutes(30)))
        #expect(assertion.held == true)
        #expect(awake.endsAt == start.addingTimeInterval(1800))

        now = start.addingTimeInterval(1799)
        awake.expireIfDue()
        #expect(awake.isActive)

        now = start.addingTimeInterval(1800)
        awake.expireIfDue()
        #expect(!awake.isActive)
        #expect(assertion.held == nil)
    }

    @Test func indefiniteNeverExpires() {
        var now = start
        let assertion = FakeAssertion()
        let awake = KeepAwake(assertion: assertion, keepsDisplayOn: false, now: { now })
        awake.start(.indefinitely)
        now = start.addingTimeInterval(86_400 * 30)
        awake.expireIfDue()
        #expect(awake.isIndefinite)
        #expect(assertion.held == false)
        awake.stop()
        #expect(assertion.held == nil)
    }

    @Test func togglingTheDisplayRetakesTheAssertion() {
        let assertion = FakeAssertion()
        let awake = KeepAwake(assertion: assertion, keepsDisplayOn: true, now: { self.start })
        awake.keepsDisplayOn = false
        #expect(assertion.begins == 0) // off: nothing to re-take
        awake.start(.minutes(15))
        awake.keepsDisplayOn = true
        #expect(assertion.held == true)
        #expect(assertion.begins == 2)
    }

    @Test func refusedAssertionLeavesItOff() {
        let assertion = FakeAssertion()
        assertion.refuses = true
        let awake = KeepAwake(assertion: assertion, keepsDisplayOn: true, now: { self.start })
        #expect(!awake.start(.indefinitely))
        #expect(!awake.isActive)
    }

    @Test func titlesAndLabels() {
        #expect(KeepAwakeDuration.presets.map(\.title) ==
                ["Indefinitely", "15 minutes", "30 minutes", "1 hour", "2 hours", "3 hours", "5 hours", "8 hours"])
        #expect(KeepAwakeFormat.remaining(until: start.addingTimeInterval(3900), now: start) == "1:05")
        #expect(KeepAwakeFormat.remaining(until: start.addingTimeInterval(61), now: start) == "0:02")
        #expect(KeepAwakeFormat.remaining(until: .distantFuture, now: start) == "")
        let utc = TimeZone(identifier: "UTC")!
        #expect(KeepAwakeFormat.status(until: nil) == "Not keeping awake")
        #expect(KeepAwakeFormat.status(until: .distantFuture) == "Awake indefinitely")
        #expect(KeepAwakeFormat.status(until: Date(timeIntervalSince1970: 52_200), in: utc) == "Awake until 14:30")
    }
}
