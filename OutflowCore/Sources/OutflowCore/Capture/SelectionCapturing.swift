import Foundation

/// Result of one capture attempt. `text` is already trimmed; nil means nothing readable.
/// `note` is a status-line detail such as "Clipboard restored partially".
public struct CaptureResult: Sendable, Equatable {
    public var text: String?
    public var note: String?

    public init(text: String?, note: String? = nil) {
        self.text = text
        self.note = note
    }

    public static let none = CaptureResult(text: nil)
}

/// The capture orchestrator seam (implemented by SelectionCapture in T5). The session
/// passes the frozen source app so the Copy fallback can verify it is still frontmost (D9).
@MainActor
public protocol SelectionCapturing: AnyObject {
    func capture(from app: FrontmostApp?) async -> CaptureResult
}
