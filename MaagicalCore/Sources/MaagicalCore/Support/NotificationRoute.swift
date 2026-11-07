import Foundation
import UserNotifications

/// What a click on one of Maagical's notifications should do (file transcription eng review R4).
/// One pure function shared by the Pomodoro and file transcription notifications, so the
/// Pomodoro Start button is pinned by tests now that the delegate serves both.
public enum NotificationRoute: Equatable, Sendable {
    /// Pomodoro "Start break" / "Start focus": the phase it was posted for.
    case startFocusPhase(session: UUID, block: Int, phase: FocusPhase)
    /// "Transcript ready": open that transcript.
    case openTranscript(UUID)
    case none

    public static let focusStartAction = "one.floo.vibeflow.focus.start"
    public static let transcriptCategory = "one.floo.vibeflow.transcript.ready"
    public static let transcriptKey = "transcript"

    public static func from(category: String, action: String, userInfo: [AnyHashable: Any]) -> NotificationRoute {
        if category == transcriptCategory {
            // A click on the banner (default action) opens it; dismissing does nothing.
            guard action == UNNotificationDefaultActionIdentifier,
                  let id = (userInfo[transcriptKey] as? String).flatMap(UUID.init(uuidString:)) else { return .none }
            return .openTranscript(id)
        }
        // Pomodoro: unchanged from before the split, the Start action with session, block, phase.
        guard action == focusStartAction,
              let session = (userInfo["session"] as? String).flatMap(UUID.init(uuidString:)),
              let block = userInfo["block"] as? Int,
              let phase = (userInfo["phase"] as? String).flatMap(FocusPhase.init(rawValue:)) else { return .none }
        return .startFocusPhase(session: session, block: block, phase: phase)
    }
}
