import Foundation
import Testing
import UserNotifications
@testable import VibeFlowCore

/// Regression guard for the Pomodoro buttons after the notification delegate started serving
/// "Transcript ready" too (file transcription eng review R4).
@Suite("NotificationRoute")
struct NotificationRouteTests {
    let session = UUID()

    func focusInfo(phase: String = "shortBreak") -> [AnyHashable: Any] {
        ["session": session.uuidString, "block": 2, "phase": phase]
    }

    @Test func pomodoroStartBreakStillStartsTheBreak() {
        #expect(NotificationRoute.from(category: "one.floo.vibeflow.focus.break", action: NotificationRoute.focusStartAction,
                                       userInfo: focusInfo()) == .startFocusPhase(session: session, block: 2, phase: .shortBreak))
    }

    @Test func pomodoroStartFocusStillStartsFocus() {
        #expect(NotificationRoute.from(category: "one.floo.vibeflow.focus.focus", action: NotificationRoute.focusStartAction,
                                       userInfo: focusInfo(phase: "focus")) == .startFocusPhase(session: session, block: 2, phase: .focus))
    }

    @Test func clickingAPomodoroBannerItselfStillDoesNothing() {
        // Before the split only the Start button acted; a plain click kept doing nothing.
        #expect(NotificationRoute.from(category: "one.floo.vibeflow.focus.break", action: UNNotificationDefaultActionIdentifier,
                                       userInfo: focusInfo()) == .none)
    }

    @Test func clickingTranscriptReadyOpensThatTranscript() {
        let id = UUID()
        #expect(NotificationRoute.from(category: NotificationRoute.transcriptCategory, action: UNNotificationDefaultActionIdentifier,
                                       userInfo: [NotificationRoute.transcriptKey: id.uuidString]) == .openTranscript(id))
    }

    @Test func dismissingOrBrokenInfoDoesNothing() {
        #expect(NotificationRoute.from(category: NotificationRoute.transcriptCategory, action: UNNotificationDismissActionIdentifier,
                                       userInfo: [NotificationRoute.transcriptKey: UUID().uuidString]) == .none)
        #expect(NotificationRoute.from(category: NotificationRoute.transcriptCategory, action: UNNotificationDefaultActionIdentifier,
                                       userInfo: [:]) == .none)
        #expect(NotificationRoute.from(category: "one.floo.vibeflow.focus.break", action: NotificationRoute.focusStartAction,
                                       userInfo: ["session": "nope", "block": 2, "phase": "focus"]) == .none)
        #expect(NotificationRoute.from(category: "something.else", action: "x", userInfo: [:]) == .none)
    }
}
