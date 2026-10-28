import Foundation
import Testing
@testable import VibeFlowCore

/// Smart read key: tap versus hold (docs/designs/smart-read-follow-up.md, eng review D5, D9).
@Suite("PressClassifier") @MainActor
final class PressClassifierTests {
    let clock = FakeClock()
    var events: [String] = []
    private(set) var classifier: PressClassifier!

    init() {
        classifier = PressClassifier(
            clock: clock,
            onTap: { [unowned self] in self.events.append("tap") },
            onHoldStart: { [unowned self] in self.events.append("holdStart") },
            onHoldEnd: { [unowned self] in self.events.append("holdEnd") }
        )
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func quickReleaseIsOneTapAndNothingAtKeyDown() async {
        classifier.keyDown()
        await settle()
        #expect(events.isEmpty, "a tap does nothing at key down, so the microphone stays closed")
        clock.advance(by: .milliseconds(290))
        await settle()
        classifier.keyUp()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        #expect(events == ["tap"])
        #expect(classifier.lastPress == .tap)
    }

    @Test func holdStartsAtTheThresholdAndNeverTaps() async {
        classifier.keyDown()
        await settle()
        clock.advance(by: PressClassifier.holdThreshold)
        await settle()
        #expect(events == ["holdStart"])
        classifier.keyUp()
        #expect(events == ["holdStart", "holdEnd"])
        #expect(classifier.lastPress == .hold)
    }

    @Test func keyRepeatDoesNotRestartTheTimer() async {
        classifier.keyDown()
        await settle()
        clock.advance(by: .milliseconds(200))
        await settle()
        classifier.keyDown()
        await settle()
        clock.advance(by: .milliseconds(100))
        await settle()
        #expect(events == ["holdStart"])
    }

    @Test func strayKeyUpDoesNothing() {
        classifier.keyUp()
        #expect(events.isEmpty)
    }

    @Test func eachPressIsClassifiedOnItsOwn() async {
        classifier.keyDown()
        await settle()
        clock.advance(by: .seconds(1))
        await settle()
        classifier.keyUp()
        classifier.keyDown()
        classifier.keyUp()
        #expect(events == ["holdStart", "holdEnd", "tap"])
    }
}
