import Foundation
import Observation

// MARK: - Ports (the app's LiveDesktops supplies all three)

/// The desktops of every screen, numbered across screens like Mission Control does.
public struct DesktopLayout: Hashable, Sendable {
    public struct Screen: Hashable, Sendable {
        /// Desktop numbers on this screen, in order.
        public var desktops: [Int]
        /// The desktop showing now; nil while a full-screen app is showing.
        public var showing: Int?

        public init(desktops: [Int], showing: Int?) {
            self.desktops = desktops
            self.showing = showing
        }
    }

    public var screens: [Screen]
    /// Index into `screens` of the screen with keyboard focus.
    public var focusedScreen: Int?

    public init(screens: [Screen], focusedScreen: Int?) {
        self.screens = screens
        self.focusedScreen = focusedScreen
    }

    public var desktopCount: Int { screens.reduce(0) { $0 + $1.desktops.count } }

    public func isShowing(_ desktop: Int) -> Bool {
        screens.contains { $0.showing == desktop }
    }
}

/// Reads and switches desktops and owns their wallpaper. Reading uses private, read-only
/// SkyLight calls; switching posts Control+N.
@MainActor
public protocol DesktopControl: AnyObject {
    /// nil when the desktops cannot be read; nothing launches then.
    func layout() -> DesktopLayout?
    /// Posts Control+N. Confirmation comes from `layout()`, never from a notification alone.
    func switchTo(desktop: Int)
    /// Sets the tint, with the role's name on it, on the screen that is showing `desktop`. The name
    /// is on the wallpaper because a menu bar item looks the same on every screen.
    func tint(desktop: Int, colorHex: String, name: String)
}

/// Windows as Accessibility and the window list see them.
@MainActor
public protocol DesktopWindows: AnyObject {
    /// Standard windows on `desktop`, which must be showing. Accessibility only sees showing desktops.
    func inventory(ofDesktop desktop: Int) -> DesktopInventory
    /// Where the app's real windows are, across all desktops.
    func appWindows(bundleID: String) -> AppWindows
    /// Real windows of the app that sit on some desktop (helper windows sit on none).
    func windowIDs(bundleID: String) -> Set<UInt32>
    func desktop(ofWindow id: UInt32) -> Int?
    /// Moves a window onto the screen of `desktop`, which must be showing. macOS allows moving a
    /// window between screens but not between desktops of one screen (spike, 2026-11-04).
    func moveWindow(_ id: UInt32, toScreenOf desktop: Int) -> Bool
}

public enum LaunchRequest: Hashable, Sendable {
    case app(bundleID: String)
    /// Chrome with no arguments, so a restored session appears before anything is requested (D8c).
    case chromeBare
    case chromeWindow(profileDirectory: String, urls: [String])
}

@MainActor
public protocol AppLauncher: AnyObject {
    func open(_ request: LaunchRequest) async throws
    /// Whether this Chrome profile reopens its last session on startup (Chrome's "On startup").
    func restoresSession(chromeProfile directory: String) -> Bool
}

// MARK: - Report

public struct SetupReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case opened
        case alreadyThere
        case unresolved(UnresolvedReason)
    }

    public struct Entry: Hashable, Sendable {
        public var role: String
        public var desktop: Int
        public var item: RoleItem
        public var outcome: Outcome
    }

    /// Why the walk did not start at all.
    public enum Refusal: Hashable, Sendable {
        /// Dictation or smart read is running; a walk would move their paste target (D8a).
        case busy
        case alreadyRunning
        /// The desktops could not be read.
        case unknownDesktops
    }

    public var entries: [Entry] = []
    public var refusal: Refusal?

    public init(entries: [Entry] = [], refusal: Refusal? = nil) {
        self.entries = entries
        self.refusal = refusal
    }

    public func count(_ matches: (Outcome) -> Bool) -> Int { entries.filter { matches($0.outcome) }.count }
    public var opened: Int { count { $0 == .opened } }
    public var alreadyThere: Int { count { $0 == .alreadyThere } }
    public var unresolved: [Entry] {
        entries.filter { if case .unresolved = $0.outcome { return true } else { return false } }
    }
}

// MARK: - The walk

/// The morning key: visits each role's desktop, tints it and opens only what is missing there,
/// then puts every screen back on the desktop it showed before. Safe to run again at any time.
@MainActor
@Observable
public final class DesktopSetup {
    public private(set) var isRunning = false
    public private(set) var lastReport: SetupReport?

    public static let switchTimeout: Duration = .seconds(2)
    public static let switchPoll: Duration = .milliseconds(100)
    public static let arrivalPoll: Duration = .milliseconds(200)
    /// Waiting for a window of an app that was already running, or one that had to start.
    public static let arrivalBudget: Duration = .seconds(8)
    public static let coldArrivalBudget: Duration = .seconds(15)
    /// A cold Chrome start counts as settled once its window count holds this long.
    public static let settleQuiet: Duration = .seconds(2)
    public static let settleLimit: Duration = .seconds(15)

    @ObservationIgnored private let control: any DesktopControl
    @ObservationIgnored private let windows: any DesktopWindows
    @ObservationIgnored private let launcher: any AppLauncher
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let isBusy: @MainActor () -> Bool

    public init(
        control: any DesktopControl, windows: any DesktopWindows, launcher: any AppLauncher,
        clock: any SessionClock = ContinuousSessionClock(), isBusy: @escaping @MainActor () -> Bool
    ) {
        self.control = control
        self.windows = windows
        self.launcher = launcher
        self.clock = clock
        self.isBusy = isBusy
    }

    /// Runs the walk. Cancel the calling task to stop it; the remaining items are reported as cancelled.
    @discardableResult
    public func run(_ roles: [DesktopRole]) async -> SetupReport {
        guard !isRunning else { return SetupReport(refusal: .alreadyRunning) }
        guard !isBusy() else { return finish(SetupReport(refusal: .busy)) }
        guard let start = control.layout() else { return finish(SetupReport(refusal: .unknownDesktops)) }
        isRunning = true
        defer { isRunning = false }

        var report = SetupReport()
        var stop: UnresolvedReason?
        var surprises = 0
        func record(_ role: DesktopRole, _ item: RoleItem, _ outcome: SetupReport.Outcome) {
            report.entries.append(.init(role: role.name, desktop: role.desktopNumber, item: item, outcome: outcome))
        }

        for role in roles.sorted(by: { $0.desktopNumber < $1.desktopNumber }) {
            let desktop = role.desktopNumber
            if stop == nil, Task.isCancelled { stop = .cancelled }
            if let stop {
                role.items.forEach { record(role, $0, .unresolved(stop)) }
                continue
            }
            guard desktop <= (control.layout()?.desktopCount ?? 0) else {
                role.items.forEach { record(role, $0, .unresolved(.missingDesktop)) }
                continue
            }
            var handled = 0
            do {
                guard try await show(desktop) else {
                    role.items.forEach { record(role, $0, .unresolved(.switchFailed)) }
                    continue
                }
                control.tint(desktop: desktop, colorHex: role.colorHex, name: role.name)
                for item in role.items {
                    if let stop {
                        record(role, item, .unresolved(stop))
                        handled += 1
                        continue
                    }
                    try Task.checkCancellation()
                    record(role, item, try await setUp(item, on: desktop))
                    handled += 1
                    // Something took the desktop away (D4): undo it once, stop the second time.
                    if control.layout()?.isShowing(desktop) != true {
                        surprises += 1
                        if surprises > 1 {
                            stop = .stoppedBecauseYouSwitched
                        } else if try await !show(desktop) {
                            stop = .switchFailed
                        }
                    }
                }
            } catch {
                stop = .cancelled
                role.items.dropFirst(handled).forEach { record(role, $0, .unresolved(.cancelled)) }
            }
        }
        await restore(start)
        return finish(report)
    }

    /// Re-applies the tint of every desktop that is showing now. The only other tint writer is
    /// the walk itself, so there is one owner (eng review, Architecture 2).
    public func retintShowing(_ roles: [DesktopRole]) {
        guard let layout = control.layout() else { return }
        for role in roles where layout.isShowing(role.desktopNumber) {
            control.tint(desktop: role.desktopNumber, colorHex: role.colorHex, name: role.name)
        }
    }

    // MARK: Steps

    private func finish(_ report: SetupReport) -> SetupReport {
        lastReport = report
        return report
    }

    private func setUp(_ item: RoleItem, on desktop: Int) async throws -> SetupReport.Outcome {
        switch plan(item, on: desktop) {
        case .alreadyThere: return .alreadyThere
        case .unresolved(let reason): return .unresolved(reason)
        case .open: break
        }
        let bundleID = item.bundleID
        let wasRunning = windows.appWindows(bundleID: bundleID).isRunning
        if case .chrome(let directory, _, _) = item, !wasRunning, launcher.restoresSession(chromeProfile: directory) {
            // Let Chrome restore its session first, then take stock again (D8c).
            if let failure = try await launch(.chromeBare) { return failure }
            try await settle(bundleID)
            switch plan(item, on: desktop) {
            case .alreadyThere: return .alreadyThere
            case .unresolved(let reason): return .unresolved(reason)
            case .open: break
            }
        }
        let before = windows.windowIDs(bundleID: bundleID)
        if let failure = try await launch(request(for: item)) { return failure }
        let budget = wasRunning ? Self.arrivalBudget : Self.coldArrivalBudget
        var arrived: UInt32?
        _ = try await poll(every: Self.arrivalPoll, for: budget) {
            arrived = self.windows.windowIDs(bundleID: bundleID).subtracting(before).min()
            return arrived != nil
        }
        guard let window = arrived else { return .unresolved(.didNotAppear) }
        if windows.desktop(ofWindow: window) == desktop { return .opened }
        // New windows land on whichever screen the app picks; move it across (spike, 2026-11-04).
        if windows.moveWindow(window, toScreenOf: desktop), windows.desktop(ofWindow: window) == desktop { return .opened }
        return .unresolved(.landedElsewhere)
    }

    private func plan(_ item: RoleItem, on desktop: Int) -> ItemPlan {
        LaunchPlanner.plan(
            item, desktop: desktop, inventory: windows.inventory(ofDesktop: desktop),
            appWindows: windows.appWindows(bundleID: item.bundleID))
    }

    private func request(for item: RoleItem) -> LaunchRequest {
        switch item {
        case .app(let bundleID): return .app(bundleID: bundleID)
        case .chrome(let directory, _, let urls): return .chromeWindow(profileDirectory: directory, urls: urls)
        }
    }

    /// nil when the app opened; the report outcome when it failed. Cancellation propagates.
    private func launch(_ request: LaunchRequest) async throws -> SetupReport.Outcome? {
        do {
            try await launcher.open(request)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unresolved(.launchFailed(error.localizedDescription))
        }
    }

    /// Brings `desktop` up on its screen, confirmed by reading the layout.
    private func show(_ desktop: Int) async throws -> Bool {
        if control.layout()?.isShowing(desktop) == true { return true }
        control.switchTo(desktop: desktop)
        return try await poll(every: Self.switchPoll, for: Self.switchTimeout) {
            self.control.layout()?.isShowing(desktop) == true
        }
    }

    /// Waits until the app's window count holds for `settleQuiet`, at most `settleLimit`.
    private func settle(_ bundleID: String) async throws {
        var count = -1
        var quiet: Duration = .zero
        _ = try await poll(every: Self.arrivalPoll, for: Self.settleLimit) {
            let now = self.windows.windowIDs(bundleID: bundleID).count
            if now == count { quiet += Self.arrivalPoll } else { count = now; quiet = .zero }
            return now > 0 && quiet >= Self.settleQuiet
        }
    }

    /// Puts every screen back on the desktop it showed before, the focused screen last so focus
    /// ends where it started. A screen that showed a full-screen app is left alone.
    private func restore(_ start: DesktopLayout) async {
        let focused = start.focusedScreen.map { [$0] } ?? []
        let order = start.screens.indices.filter { !focused.contains($0) } + focused
        for index in order {
            guard let wanted = start.screens[index].showing, control.layout()?.isShowing(wanted) != true else { continue }
            control.switchTo(desktop: wanted)
            _ = try? await poll(every: Self.switchPoll, for: Self.switchTimeout) {
                self.control.layout()?.isShowing(wanted) == true
            }
        }
    }

    /// Checks `done` now and after each `interval` until `limit`; true once it held.
    private func poll(every interval: Duration, for limit: Duration, until done: () -> Bool) async throws -> Bool {
        var waited: Duration = .zero
        while !done() {
            guard waited < limit else { return false }
            try await clock.sleep(for: interval)
            waited += interval
        }
        return true
    }
}
