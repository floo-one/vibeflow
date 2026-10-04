import Foundation
import Testing
@testable import VibeFlowCore

@MainActor
struct InsertionHarness {
    let accessibility = FakeAccessibility()
    let pasteboard: FakePasteboard
    let clock = FakeClock()
    let insertion: TextInsertion
    let target: PasteTarget

    init(pasteboard: FakePasteboard = FakePasteboard(text: "my clipboard")) {
        self.pasteboard = pasteboard
        accessibility.pasteboard = pasteboard
        insertion = TextInsertion(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
        target = PasteTarget(app: accessibility.frontmost!, field: accessibility.focused)
    }

    /// Runs the insertion, advancing the fake clock until it returns.
    func run(_ text: String = "Hello Anna.", target override: PasteTarget? = nil, onPress: (@MainActor () -> Void)? = nil) async -> InsertionResult {
        let done = Flag()
        let destination = override ?? target
        let task = Task { let r = await insertion.insert(text, into: destination); done.set(); return r }
        var pressed = false
        var steps = 0
        while !done.isSet && steps < 200 {
            for _ in 0..<10 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(2))
            if !pressed, !accessibility.pastePresses.isEmpty || accessibility.pasteKeystrokes > 0 { pressed = true; onPress?() }
            clock.advance(by: .milliseconds(50))
            steps += 1
        }
        return await task.value
    }
}

@Suite("TextInsertion (D6, D10)") @MainActor
struct TextInsertionTests {
    @Test func pastesThroughTheCmdVItemAndRestoresTheClipboardTransiently() async {
        let h = InsertionHarness()
        let result = await h.run()
        #expect(result == .pasted(note: nil))
        #expect(h.accessibility.pastePresses == [h.target.app])
        #expect(h.pasteboard.writes.map(\.text) == ["Hello Anna.", "my clipboard"])
        let allTransient = h.pasteboard.writes.allSatisfy { $0.transient }
        #expect(allTransient)
        #expect(h.pasteboard.string() == "my clipboard")
    }

    @Test func restoreWaitsTheFullDelay() async throws {
        let h = InsertionHarness()
        let task = Task { await h.insertion.insert("Hello.", into: h.target) }
        var spins = 0
        while (h.accessibility.pastePresses.isEmpty || h.clock.sleeperCount != 1) && spins < 400 {
            try await Task.sleep(for: .milliseconds(5)); spins += 1
        }
        #expect(spins < 400, "paste never reached the restore delay")
        h.clock.advance(by: .milliseconds(749))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.pasteboard.string() == "Hello.", "not restored before 750 ms")
        h.clock.advance(by: .milliseconds(1))
        _ = await task.value
        #expect(h.pasteboard.string() == "my clipboard")
    }

    @Test func foreignWriteDuringTheDelaySkipsTheRestore() async {
        let h = InsertionHarness()
        let result = await h.run(onPress: { h.pasteboard.externalWrite("user copied this") })
        #expect(result == .pasted(note: ClipboardSnapshot.notRestoredNote))
        #expect(h.pasteboard.string() == "user copied this")
    }

    @Test func missingPasteMenuItemFallsBackToAKeystroke() async {
        let h = InsertionHarness()
        h.accessibility.pasteError = .copyMenuItemNotFound
        let result = await h.run()
        #expect(result == .pasted(note: nil))
        #expect(h.accessibility.pasteKeystrokes == 1)
    }

    @Test func changedTextFieldCopiesInsteadOfPasting() async {
        let h = InsertionHarness()
        h.accessibility.focused = FocusedElement("another-channel")
        let result = await h.run()
        #expect(result == .copiedInstead(reason: "the text field changed"))
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.pasteboard.string() == "Hello Anna.")
        #expect(h.pasteboard.writes.last?.transient == false, "copied text is a real clipboard entry")
    }

    @Test func fieldThatDisappearedCopiesInstead() async {
        let h = InsertionHarness()
        h.accessibility.focused = nil
        #expect(await h.run() == .copiedInstead(reason: "the text field changed"))
    }

    @Test func appWithoutAFocusedElementUsesTheAppLevelCheck() async {
        let h = InsertionHarness()
        let noField = PasteTarget(app: h.target.app, field: nil)
        h.accessibility.focused = nil
        let result = await h.run("Hi.", target: noField)
        #expect(result == .pasted(note: nil))
    }

    @Test func secureInputAtPasteTimeCopiesInstead() async {
        let h = InsertionHarness()
        h.accessibility.isSecureInputActive = true
        #expect(await h.run() == .copiedInstead(reason: "a password field has focus"))
        #expect(h.accessibility.pastePresses.isEmpty)
    }

    @Test func appThatLostFocusCopiesInstead() async {
        let h = InsertionHarness()
        h.accessibility.frontmost = FrontmostApp(pid: 999, bundleID: "com.other")
        #expect(await h.run() == .copiedInstead(reason: "the app lost focus"))
    }

    @Test func nonTextClipboardIsOverwrittenWithANote() async {
        let h = InsertionHarness(pasteboard: FakePasteboard(nonText: true))
        #expect(await h.run() == .pasted(note: ClipboardSnapshot.nonTextNote))
    }
}
