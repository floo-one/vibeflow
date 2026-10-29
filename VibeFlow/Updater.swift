import AppKit
import CoreGraphics
import OSLog
import Sparkle

/// The release keeps itself current (docs/designs/dev-prod-channels.md, P1). Sparkle reads the
/// feed in Info.plist (SUFeedURL) every 6 hours and downloads a new version in the background;
/// this installs it once VibeFlow is not reading or dictating and the Mac has had no keyboard
/// or mouse input for a few minutes, so the relaunch never cuts off a read or loses the last
/// dictation while you work. Quitting VibeFlow installs a downloaded update as well.
/// VibeFlow Dev never creates one.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    /// How long the Mac has to sit untouched before a downloaded update installs.
    static let idleBeforeInstall: TimeInterval = 5 * 60

    private let log = Logger(subsystem: "one.floo.vibeflow", category: "update")
    private let isBusy: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var install: (() -> Void)?
    private var waiting: Task<Void, Never>?

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Menu "Check for Updates…": Sparkle's window, in front, since VibeFlow has no Dock icon.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Sparkle downloaded an update and would install it at quit. Taking it over means Sparkle
    /// stops checking until it is installed, which happens below or at quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.notice("update: \(item.displayVersionString, privacy: .public) downloaded, installs when idle")
        install = immediateInstallHandler
        waiting?.cancel()
        waiting = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.canInstallNow {
                    self.log.notice("update: installing and relaunching")
                    self.install?()
                    return
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        return true
    }

    private var canInstallNow: Bool {
        !isBusy() && Self.secondsSinceLastInput >= Self.idleBeforeInstall
    }

    /// Keyboard, mouse or trackpad, not VibeFlow's own simulated Copy and Paste.
    private static var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}
