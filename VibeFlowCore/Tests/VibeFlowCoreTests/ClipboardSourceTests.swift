import Testing
@testable import VibeFlowCore

@Suite struct ClipboardSourceTests {
    @Test func copiedInTheFrontmostAppIsThatApp() {
        var tracker = ClipboardSourceTracker()
        tracker.appActivated("com.openai.chat", changeCount: 10)
        #expect(tracker.source(changeCount: 11) == "com.openai.chat")
    }

    @Test func copiedElsewhereThenSwitchingToTheAIAppKeepsTheOtherApp() {
        var tracker = ClipboardSourceTracker()
        tracker.appActivated("com.apple.mail", changeCount: 10)
        tracker.appActivated("com.openai.chat", changeCount: 11) // copied in Mail
        #expect(tracker.source(changeCount: 11) == "com.apple.mail")
    }

    @Test func copiedInTheAIAppSurvivesAQuickTripAway() {
        var tracker = ClipboardSourceTracker()
        tracker.appActivated("com.openai.chat", changeCount: 10)
        tracker.appActivated("com.apple.Safari", changeCount: 11) // copied in ChatGPT
        tracker.appActivated("com.openai.chat", changeCount: 11)
        #expect(tracker.source(changeCount: 11) == "com.openai.chat")
    }

    @Test func aClipboardOlderThanTrackingIsUnknown() {
        var tracker = ClipboardSourceTracker()
        #expect(tracker.source(changeCount: 5) == nil)
        tracker.appActivated("com.openai.chat", changeCount: 5) // seeded at launch
        #expect(tracker.source(changeCount: 5) == nil)
    }
}
