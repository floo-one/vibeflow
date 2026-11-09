import Foundation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "capture")

/// Capture orchestrator (design: Capture steps 2 to 4). Trust is checked by the session.
///
/// 1. kAXSelectedText on the focused element. Non-empty: done.
/// 2. Otherwise the Copy fallback in `PasteboardCapture`.
/// 3. Empty or whitespace-only: nothing to read. A failed Copy is `.failed`, unless
///    Accessibility already reported an empty selection.
@MainActor
public final class SelectionCapture: SelectionCapturing {
    private let accessibility: any AccessibilityBridge
    private let fallback: PasteboardCapture

    public init(accessibility: any AccessibilityBridge, pasteboard: any Pasteboard, clock: any SessionClock) {
        self.accessibility = accessibility
        self.fallback = PasteboardCapture(accessibility: accessibility, pasteboard: pasteboard, clock: clock)
    }

    public func capture(from app: FrontmostApp?) async -> CaptureResult {
        var accessibilitySaysEmpty = false
        let bundle = app?.bundleID ?? "no app"
        do {
            if let direct = try accessibility.focusedSelectedText() {
                let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    log.notice("Capture in \(bundle, privacy: .public): Accessibility gave \(trimmed.count, privacy: .public) characters")
                    return CaptureResult(text: trimmed)
                }
                accessibilitySaysEmpty = true
                log.notice("Capture in \(bundle, privacy: .public): Accessibility says nothing is selected, trying Copy")
            } else {
                log.notice("Capture in \(bundle, privacy: .public): the focused element has no selected text attribute, trying Copy")
            }
        } catch {
            log.notice("Capture in \(bundle, privacy: .public): Accessibility failed (\(String(describing: error), privacy: .public)), trying Copy")
        }
        guard let app else { return accessibilitySaysEmpty ? .none : .failed }
        let copied = await fallback.capture(from: app)
        // With nothing selected, many apps disable Copy; Accessibility already said empty.
        if copied.failed && accessibilitySaysEmpty { return .none }
        return copied
    }
}
