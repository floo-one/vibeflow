import AppKit
import CoreGraphics
import OSLog
import Sparkle
import VibeFlowCore

/// The release keeps itself current (docs/designs/dev-prod-channels.md, P1). Sparkle reads the
/// feed in Info.plist (SUFeedURL) every 6 hours and downloads a new version in the background;
/// this installs it once VibeFlow is not reading or dictating and the Mac has had no keyboard
/// or mouse input for a few minutes, so the relaunch never cuts off a read or loses the last
/// dictation while you work. Quitting VibeFlow installs a downloaded update as well.
/// With Settings > Advanced > "Update to the newest main" it reads the nightly feed instead,
/// which scripts/nightly.sh refreshes on this Mac after every new main that passed CI.
/// VibeFlow Dev never creates one.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    /// How long the Mac has to sit untouched before a downloaded update installs.
    static let idleBeforeInstall: TimeInterval = 5 * 60
    /// The rolling "nightly" GitHub release, a pre-release, so .../latest never serves it.
    static let nightlyFeed = "https://github.com/floo-one/vibeflow/releases/download/nightly/appcast.xml"

    private let log = Logger(subsystem: "one.floo.vibeflow", category: "update")
    private let isBusy: () -> Bool
    private let followsMain: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var install: (() -> Void)?
    private var waiting: Task<Void, Never>?

    init(isBusy: @escaping () -> Bool, followsMain: @escaping () -> Bool) {
        self.isBusy = isBusy
        self.followsMain = followsMain
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// "1.2.0", or "1.2.0 · main 87d0257" for a nightly build of main (BuildStamp), in the menu
    /// and Settings > Advanced.
    static var installedVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard let stamp = BuildStamp(info: info) else { return version }
        return "\(version) · \(stamp.branch) \(stamp.commit)"
    }

    /// A nightly build of main, from scripts/release.sh --nightly (releases carry no BuildStamp).
    static var isNightly: Bool { BuildStamp(info: Bundle.main.infoDictionary ?? [:]) != nil }

    /// The newest release's DMG. Sparkle never installs an older build, so leaving a broken
    /// nightly means installing this one by hand.
    static let releaseDMG = URL(string: "https://github.com/floo-one/vibeflow/releases/latest/download/VibeFlow.dmg")!

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Menu and Settings "Check for Updates…": Sparkle's window, in front, since VibeFlow has no Dock icon.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// The setting changed: look at the other feed now instead of in up to 6 hours. Sparkle
    /// never goes back to a lower build, so leaving main waits for a release above it.
    func channelChanged() {
        controller?.updater.checkForUpdatesInBackground()
    }

    /// nil keeps SUFeedURL from Info.plist, the releases.
    func feedURLString(for updater: SPUUpdater) -> String? {
        followsMain() ? Self.nightlyFeed : nil
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
