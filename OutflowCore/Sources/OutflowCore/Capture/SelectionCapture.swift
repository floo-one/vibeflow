import Foundation

/// Capture orchestrator (design: Capture steps 2 to 4). Trust is checked by the session.
///
/// 1. kAXSelectedText on the focused element. Non-empty: done.
/// 2. Otherwise the Copy fallback in `PasteboardCapture`.
/// 3. Empty or whitespace-only: nothing to read.
@MainActor
public final class SelectionCapture: SelectionCapturing {
    private let accessibility: any AccessibilityBridge
    private let fallback: PasteboardCapture

    public init(accessibility: any AccessibilityBridge, pasteboard: any Pasteboard, clock: any SessionClock) {
        self.accessibility = accessibility
        self.fallback = PasteboardCapture(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
    }

    public func capture(from app: FrontmostApp?) async -> CaptureResult {
        if let direct = try? accessibility.focusedSelectedText() {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return CaptureResult(text: trimmed) }
        }
        guard let app else { return .none }
        return await fallback.capture(from: app)
    }
}
