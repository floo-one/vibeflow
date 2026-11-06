import AppKit
import ApplicationServices
import OSLog
import MaagicalCore

/// Owns the one runtime permission Maagical needs: Accessibility.
/// The trust check is repeated on every hotkey press later (design: Capture step 1),
/// because a rebuild with a different signature silently drops the grant.
/// Also keeps one running copy per app (SingleInstance).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "one.floo.vibeflow", category: "accessibility")
    private static let launchLog = Logger(subsystem: "one.floo.vibeflow", category: "launch")
    private var sigterm: DispatchSourceSignal?

    /// The newest copy wins: an older Maagical (or Maagical Dev) from any path gets SIGTERM.
    /// Called from MaagicalApp.init, before AppContainer, whose Keychain read can wait on an
    /// access dialog. A copy stuck there has no SIGTERM handler yet, so it ends on the spot.
    static func quitOlderCopies() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let older = SingleInstance.olderCopies(
            of: .init(pid: current.processIdentifier, launchDate: current.launchDate),
            among: running.map { .init(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        )
        for app in running where older.contains(app.processIdentifier) {
            launchLog.notice("launch: quitting older copy pid=\(app.processIdentifier, privacy: .public) at \(app.bundleURL?.path ?? "?", privacy: .public)")
            kill(app.processIdentifier, SIGTERM)
        }
    }

    /// Once launched, SIGTERM (kill, scripts/dev.sh, a newer copy taking over) quits like the
    /// Quit menu item instead of ending the process on the spot.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        sigterm = source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOnSIGTERM()
        // Prompts once if not trusted; returns the current state either way.
        // Literal key: kAXTrustedCheckOptionPrompt is a global var and not Sendable under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        // Readable with: log show --last 2m --predicate 'subsystem == "one.floo.vibeflow"'
        // .notice persists to disk; .info is memory-only and invisible to `log show`.
        log.notice("launch: accessibility trusted=\(trusted, privacy: .public)")
        // The Maagical icon and its panel (menu bar popover R1); a status item made before
        // launch finishes never shows up.
        if let container = Self.container { StatusItemController.install(container: container) }
    }

    /// Handed over by MaagicalApp.init, which owns the container.
    @MainActor static var container: AppContainer?
}

enum Accessibility {
    /// Current trust state, cheap enough to call on every hotkey press.
    @MainActor static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Deep link to System Settings > Privacy & Security > Accessibility.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
