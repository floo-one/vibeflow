import Foundation

/// Result of one capture attempt. `text` is already trimmed; nil means nothing readable.
/// `note` is a status-line detail such as "Clipboard restored partially".
/// `failed` separates "nothing is selected" from "the selection could not be read" (Copy
/// failed, timed out, another app wrote the clipboard, the app lost focus). Follow-up questions
/// only continue the old text on the former (eng review D11).
public struct CaptureResult: Sendable, Equatable {
    public var text: String?
    public var note: String?
    public var failed: Bool

    public init(text: String?, note: String? = nil, failed: Bool = false) {
        self.text = text
        self.note = note
        self.failed = failed
    }

    /// Nothing selected.
    public static let none = CaptureResult(text: nil)
    /// The selection could not be read.
    public static let failed = CaptureResult(text: nil, failed: true)
}

/// The capture orchestrator seam (implemented by SelectionCapture in T5). The session
/// passes the frozen source app so the Copy fallback can verify it is still frontmost (D9).
@MainActor
public protocol SelectionCapturing: AnyObject {
    func capture(from app: FrontmostApp?) async -> CaptureResult
}
