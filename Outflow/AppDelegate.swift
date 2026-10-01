import AppKit
import ApplicationServices
import OSLog

/// Owns the one runtime permission Outflow needs: Accessibility.
/// The trust check is repeated on every hotkey press later (design: Capture step 1),
/// because a rebuild with a different signature silently drops the grant.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "one.floo.outflow", category: "accessibility")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompts once if not trusted; returns the current state either way.
        // Literal key: kAXTrustedCheckOptionPrompt is a global var and not Sendable under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        // Readable with: log show --last 2m --predicate 'subsystem == "one.floo.outflow"'
        // .notice persists to disk; .info is memory-only and invisible to `log show`.
        log.notice("launch: accessibility trusted=\(trusted, privacy: .public)")
    }
}

enum Accessibility {
    /// Current trust state, cheap enough to call on every hotkey press.
    @MainActor static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Deep link to System Settings > Privacy & Security > Accessibility.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
