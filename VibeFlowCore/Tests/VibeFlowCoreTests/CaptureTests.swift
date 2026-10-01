import Foundation
import Testing
@testable import VibeFlowCore

@MainActor
struct CaptureHarness {
    let accessibility = FakeAccessibility()
    let pasteboard: FakePasteboard
    let clock = FakeClock()
    let capture: SelectionCapture
    let app = FrontmostApp(pid: 100, bundleID: "com.apple.Safari")

    init(pasteboard: FakePasteboard = FakePasteboard(text: "previous clipboard")) {
        self.pasteboard = pasteboard
        accessibility.pasteboard = pasteboard
        accessibility.clock = clock
        capture = SelectionCapture(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
    }

    /// Runs the capture while feeding the fake clock in poll-sized steps until it returns
    /// (or `maxSteps` elapse, so a genuine hang fails instead of stalling the suite).
    func run(maxSteps: Int = 400) async -> CaptureResult {
        let done = Flag()
        let task = Task {
            let result = await capture.capture(from: app)
            done.set()
            return result
        }
        var steps = 0
        while !done.isSet && steps < maxSteps {
            for _ in 0..<10 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(2))
            clock.advance(by: .milliseconds(20))
            steps += 1
        }
        if !done.isSet {
            Issue.record("capture did not finish within \(maxSteps) clock steps")
            task.cancel()
        }
        return await task.value
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite("SelectionCapture") @MainActor
struct CaptureTests {
    @Test func accessibilitySelectedTextWinsWithoutTouchingTheClipboard() async {
        let h = CaptureHarness()
        h.accessibility.selectedText = "  selected via AX  "
        let result = await h.run()
        #expect(result == CaptureResult(text: "selected via AX"))
        #expect(h.accessibility.copyPresses.isEmpty)
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func copyFallbackReadsTheNewTextAndRestoresTheOldClipboardTransiently() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "copied text"
        let result = await h.run()
        #expect(result == CaptureResult(text: "copied text", note: nil))
        #expect(h.accessibility.copyPresses == [h.app])
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.writes[0].text == "previous clipboard")
        #expect(h.pasteboard.writes[0].transient == true)
        #expect(h.pasteboard.string() == "previous clipboard")
    }

    @Test func delayedCopyWithinTheWindowStillSucceeds() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "late copy"
        h.accessibility.copyDelay = .milliseconds(100)
        let result = await h.run()
        #expect(result.text == "late copy")
    }

    @Test func copyTimeoutYieldsNoTextAndNoRestore() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = nil // the app never writes
        let result = await h.run()
        #expect(result == .none)
        #expect(h.pasteboard.writes.isEmpty, "never overwrite a clipboard we did not change")
        #expect(h.pasteboard.string() == "previous clipboard")
    }

    @Test func competingWriteRightAfterTheCopyIsRejected() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "copied text"
        // The Copy lands synchronously on the press (N+1); a clipboard manager or another app
        // writes during the grace poll, so the counter reads N+2 when we check.
        let task = Task { await h.capture.capture(from: h.app) }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        h.pasteboard.externalWrite("clipboard manager wrote this")
        for _ in 0..<5 {
            for _ in 0..<10 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(2))
            h.clock.advance(by: .milliseconds(20))
        }
        let result = await task.value
        #expect(result == .none)
        #expect(h.pasteboard.writes.isEmpty, "never restore over a clipboard someone else just wrote")
    }

    @Test func sourceAppNoLongerFrontmostIsRejected() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "copied text"
        h.accessibility.frontmost = FrontmostApp(pid: 999, bundleID: "com.other.app")
        let result = await h.run()
        #expect(result == .none)
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func whitespaceOnlyCopyIsNoText() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "   \n"
        let result = await h.run()
        #expect(result == .none)
    }

    @Test func copyMenuItemMissingIsNoText() async {
        let h = CaptureHarness()
        h.accessibility.copyError = .copyMenuItemNotFound
        let result = await h.run()
        #expect(result == .none)
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func nonTextClipboardIsNotRestoredAndSaysSo() async {
        let h = CaptureHarness(pasteboard: FakePasteboard(nonText: true))
        h.accessibility.copyProduces = "copied text"
        let result = await h.run()
        #expect(result == CaptureResult(text: "copied text", note: PasteboardCapture.nonTextNote))
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func emptyClipboardNeedsNoRestoreAndNoNote() async {
        let h = CaptureHarness(pasteboard: FakePasteboard())
        h.accessibility.copyProduces = "copied text"
        let result = await h.run()
        #expect(result == CaptureResult(text: "copied text", note: nil))
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func slowPasteboardReadIsBoundedAndSkipsTheRestore() async {
        let pb = FakePasteboard(text: "lazy provider")
        pb.readDelay = .milliseconds(300) // slower than the 200 ms snapshot timeout
        let h = CaptureHarness(pasteboard: pb)
        h.accessibility.copyProduces = "copied text"
        let result = await h.run()
        #expect(result.text == "copied text")
        #expect(result.note == PasteboardCapture.notRestoredNote)
        #expect(pb.writes.isEmpty)
    }

    @Test func cancellationDuringTheWaitReturnsNoTextAndDoesNotRestore() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "copied text"
        h.accessibility.copyDelay = .milliseconds(200)
        let task = Task { await h.capture.capture(from: h.app) }
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        task.cancel()
        let result = await task.value
        #expect(result == .none)
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func noFrontmostAppMeansNoFallback() async {
        let h = CaptureHarness()
        h.accessibility.copyProduces = "copied text"
        let result = await h.capture.capture(from: nil)
        #expect(result == .none)
        #expect(h.accessibility.copyPresses.isEmpty)
    }
}
