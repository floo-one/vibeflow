import Foundation
import Testing
@testable import VibeFlowCore

/// Sleeps take no real time but still count, so the walk's 2 s and 8 s budgets run instantly.
private final class InstantClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var slept: Duration = .zero
    var total: Duration { lock.withLock { slept } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { slept += duration }
        await Task.yield()
    }
}

private struct LaunchError: Error, LocalizedError {
    var errorDescription: String? { "no such app" }
}

/// A Mac with screens, desktops and windows, standing in for all three ports.
@MainActor
private final class FakeMac: DesktopControl, DesktopWindows, AppLauncher {
    struct Window {
        var id: UInt32
        var bundleID: String
        var title: String
        var desktop: Int?
    }

    var screens: [DesktopLayout.Screen]
    var focusedScreen: Int? = 0
    var readable = true
    /// Control+N works for these desktops.
    var switchable: Set<Int>
    var windows: [Window] = []
    var running: Set<String> = []
    var unreadable: Set<String> = []
    var unplaced: Set<String> = []
    var restoring: Set<String> = []
    /// Chrome profile directory -> name, for the titles of new windows.
    var profileNames: [String: String] = ["Default": "floo.one", "Profile 2": "Work"]
    /// Where new windows land; nil = the desktop that was switched to last.
    var landOn: Int?
    var windowsAppear = true
    var movable = true
    var failsToOpen = false
    /// Runs after each open, for a user who switches desktops or a walk that gets cancelled.
    var afterOpen: (() -> Void)?

    private(set) var switches: [Int] = []
    private(set) var tints: [(desktop: Int, color: String)] = []
    private(set) var opened: [LaunchRequest] = []
    private var nextID: UInt32 = 100

    init(screens: [[Int]]) {
        self.screens = screens.map { .init(desktops: $0, showing: $0.first) }
        switchable = Set(screens.flatMap { $0 })
    }

    func window(_ bundleID: String, _ title: String = "", on desktop: Int?) {
        nextID += 1
        windows.append(Window(id: nextID, bundleID: bundleID, title: title, desktop: desktop))
        running.insert(bundleID)
    }

    func userShows(_ desktop: Int) {
        guard let index = screens.firstIndex(where: { $0.desktops.contains(desktop) }) else { return }
        screens[index].showing = desktop
    }

    // DesktopControl

    func layout() -> DesktopLayout? {
        readable ? DesktopLayout(screens: screens, focusedScreen: focusedScreen) : nil
    }

    func switchTo(desktop: Int) {
        switches.append(desktop)
        if switchable.contains(desktop) { userShows(desktop) }
    }

    func tint(desktop: Int, role: DesktopRole) { tints.append((desktop, role.colorHex)) }

    // DesktopWindows

    func inventory(ofDesktop desktop: Int) -> DesktopInventory {
        let here = windows.filter { $0.desktop == desktop }
            .map { DesktopWindow(id: $0.id, bundleID: $0.bundleID, title: $0.title) }
        return DesktopInventory(windows: here, unreadable: unreadable)
    }

    func appWindows(bundleID: String) -> AppWindows {
        AppWindows(
            isRunning: running.contains(bundleID),
            desktops: Set(windows.filter { $0.bundleID == bundleID }.compactMap(\.desktop)),
            hasUnplacedWindows: unplaced.contains(bundleID))
    }

    func windowIDs(bundleID: String) -> Set<UInt32> {
        Set(windows.filter { $0.bundleID == bundleID && $0.desktop != nil }.map(\.id))
    }

    func desktop(ofWindow id: UInt32) -> Int? { windows.first { $0.id == id }?.desktop }

    func moveWindow(_ id: UInt32, toScreenOf desktop: Int) -> Bool {
        guard movable, layout()?.isShowing(desktop) == true, let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        windows[index].desktop = desktop
        return true
    }

    // AppLauncher

    func open(_ request: LaunchRequest) async throws {
        opened.append(request)
        defer { afterOpen?() }
        if failsToOpen { throw LaunchError() }
        let target = landOn ?? switches.last ?? screens[0].showing
        switch request {
        case .app(let bundleID):
            running.insert(bundleID)
            if windowsAppear { window(bundleID, bundleID, on: target) }
        case .chromeBare:
            running.insert(RoleItem.chromeBundleID)
            for name in restoredProfiles { window(RoleItem.chromeBundleID, "Tab - Google Chrome - Sam (\(name))", on: target) }
        case .chromeWindow(let directory, _):
            running.insert(RoleItem.chromeBundleID)
            if windowsAppear {
                window(RoleItem.chromeBundleID, "Claude - Google Chrome - Sam (\(profileNames[directory] ?? directory))", on: target)
            }
        }
    }

    /// Profile names a bare Chrome start brings back.
    var restoredProfiles: [String] = []

    func restoresSession(chromeProfile directory: String) -> Bool { restoring.contains(directory) }
}

@MainActor
@Suite struct DesktopSetupTests {
    private let slack = "com.tinyspeck.slackmacgap"
    private let mail = "com.apple.mail"
    private let chrome = RoleItem.chromeBundleID

    private func setup(_ mac: FakeMac, clock: InstantClock = InstantClock(), busy: Bool = false) -> DesktopSetup {
        DesktopSetup(control: mac, windows: mac, launcher: mac, clock: clock, isBusy: { busy })
    }

    private func role(_ name: String, _ desktop: Int, _ items: [RoleItem]) -> DesktopRole {
        DesktopRole(name: name, colorHex: "#3B82F6", desktopNumber: desktop, items: items)
    }

    private func personal(_ desktop: Int = 3) -> RoleItem {
        .chrome(profileDirectory: "Default", profileName: "floo.one", urls: ["https://claude.ai"])
    }

    // MARK: Opening and running again

    @Test func opensWhatIsMissingOnItsDesktopTintsItAndPutsTheScreensBack() async {
        let mac = FakeMac(screens: [[1], [2, 3]])
        let report = await setup(mac).run([role("Comms", 3, [.app(bundleID: slack), .app(bundleID: mail)])])

        #expect(report.opened == 2)
        #expect(mac.windows.allSatisfy { $0.desktop == 3 })
        #expect(mac.tints.map(\.desktop) == [3])
        #expect(mac.screens[1].showing == 2, "the monitor went back to the desktop it showed")
        #expect(mac.switches == [3, 2])
    }

    @Test func runningAgainOpensNothing() async {
        let mac = FakeMac(screens: [[1], [2, 3]])
        let walk = setup(mac)
        let roles = [role("Comms", 3, [.app(bundleID: slack), personal()])]
        _ = await walk.run(roles)
        let opens = mac.opened.count

        let again = await walk.run(roles)
        #expect(again.alreadyThere == 2)
        #expect(again.opened == 0)
        #expect(mac.opened.count == opens)
        #expect(walk.lastReport == again)
    }

    // MARK: Planner rules (never move, never duplicate)

    @Test func appOpenOnAnotherDesktopIsLeftThere() async {
        let mac = FakeMac(screens: [[1, 2, 3]])
        mac.window(slack, on: 1)
        let report = await setup(mac).run([role("Comms", 3, [.app(bundleID: slack)])])

        #expect(report.entries.map(\.outcome) == [.unresolved(.openOnAnotherDesktop([1]))])
        #expect(mac.opened.isEmpty)
    }

    @Test func runningAppWithNoWindowIsOpenedHere() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.running.insert("com.spotify.client")
        let report = await setup(mac).run([role("Personal", 2, [.app(bundleID: "com.spotify.client")])])
        #expect(report.opened == 1)
    }

    @Test func incompleteInventoryNeverLaunches() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.unreadable = [slack]
        mac.running.insert(mail)
        mac.unplaced = [mail]
        let report = await setup(mac).run([role("Comms", 2, [.app(bundleID: slack), .app(bundleID: mail)])])

        #expect(report.entries.map(\.outcome) == [.unresolved(.notResponding), .unresolved(.couldNotCheck)])
        #expect(mac.opened.isEmpty)
    }

    @Test func chromeWindowsAreMatchedByProfile() async {
        let mac = FakeMac(screens: [[1, 2, 3]])
        mac.window(chrome, "Gemini - Google Chrome - Sam (Work)", on: 3)
        let admin = RoleItem.chrome(profileDirectory: "Profile 2", profileName: "Work", urls: [])
        let report = await setup(mac).run([role("Build", 3, [admin, personal()])])

        #expect(report.entries.map(\.outcome) == [.alreadyThere, .opened], "another profile's window does not count")
    }

    @Test func chromeWindowWithoutProfileInItsTitleIsNotGuessed() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.window(chrome, "Claude - Google Chrome", on: 2)
        let report = await setup(mac).run([role("Build", 2, [personal()])])

        #expect(report.entries.map(\.outcome) == [.unresolved(.checkProfile)])
        #expect(mac.opened.isEmpty)
    }

    @Test func profileNameComesFromTheEndOfTheTitle() {
        func name(_ title: String) -> String? { DesktopWindow(id: 1, bundleID: chrome, title: title).chromeProfileName }
        #expect(name("Claude - Google Chrome - Sam (floo.one)") == "floo.one")
        #expect(name("Untitled - Google Chrome - Sam (floo.one)") == "floo.one")
        #expect(name("A (draft) - Google Chrome - Sam (Work)") == "Work")
        #expect(name("Claude - Google Chrome") == nil)
        #expect(name("Use claude.ai with google.com") == nil)
    }

    // MARK: Placement

    @Test func windowOnAnotherScreenIsMovedOver() async {
        let mac = FakeMac(screens: [[1], [2, 3]])
        mac.landOn = 2
        let report = await setup(mac).run([role("Personal", 1, [personal()])])

        #expect(report.entries.map(\.outcome) == [.opened])
        #expect(mac.windows.first?.desktop == 1)
    }

    @Test func windowThatCannotBeMovedIsReported() async {
        let mac = FakeMac(screens: [[1], [2, 3]])
        mac.landOn = 2
        mac.movable = false
        let report = await setup(mac).run([role("Personal", 1, [personal()])])
        #expect(report.entries.map(\.outcome) == [.unresolved(.landedElsewhere)])
    }

    @Test func windowThatNeverAppearsIsReportedAndNotRelaunched() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.windowsAppear = false
        let clock = InstantClock()
        let report = await setup(mac, clock: clock).run([role("Comms", 2, [.app(bundleID: slack)])])

        #expect(report.entries.map(\.outcome) == [.unresolved(.didNotAppear)])
        #expect(mac.opened.count == 1)
        #expect(clock.total >= DesktopSetup.coldArrivalBudget, "an app that was not running gets the longer budget")
    }

    @Test func failedLaunchIsReported() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.failsToOpen = true
        let report = await setup(mac).run([role("Comms", 2, [.app(bundleID: slack)])])
        #expect(report.entries.map(\.outcome) == [.unresolved(.launchFailed("no such app"))])
    }

    // MARK: Desktops

    @Test func missingDesktopIsReportedWithoutWaiting() async {
        let mac = FakeMac(screens: [[1], [2]])
        let clock = InstantClock()
        let report = await setup(mac, clock: clock).run([role("Build", 4, [.app(bundleID: slack)])])

        #expect(report.entries.map(\.outcome) == [.unresolved(.missingDesktop)])
        #expect(mac.switches.isEmpty)
        #expect(clock.total == .zero)
    }

    @Test func desktopThatDoesNotSwitchSkipsOnlyItsRole() async {
        let mac = FakeMac(screens: [[1, 2, 3]])
        mac.switchable = [1, 3]
        let report = await setup(mac).run([
            role("Comms", 2, [.app(bundleID: slack)]),
            role("Build", 3, [.app(bundleID: mail)]),
        ])
        #expect(report.entries.map(\.outcome) == [.unresolved(.switchFailed), .opened])
    }

    @Test func refusesWhileDictationIsBusyOrDesktopsAreUnreadable() async {
        let mac = FakeMac(screens: [[1, 2]])
        let busy = await setup(mac, busy: true).run([role("Comms", 2, [.app(bundleID: slack)])])
        #expect(busy.refusal == .busy)

        mac.readable = false
        let unknown = await setup(mac).run([role("Comms", 2, [.app(bundleID: slack)])])
        #expect(unknown.refusal == .unknownDesktops)
        #expect(mac.opened.isEmpty && mac.switches.isEmpty)
    }

    // MARK: You switched desktops during the walk (D4)

    @Test func firstSwitchAwayIsUndoneSecondStopsTheWalk() async {
        let mac = FakeMac(screens: [[1, 2]])
        var opens = 0
        mac.afterOpen = {
            opens += 1
            mac.userShows(1)
        }
        let report = await setup(mac).run([
            role("Comms", 2, [.app(bundleID: slack), .app(bundleID: mail)]),
            role("Build", 2, [.app(bundleID: "com.openai.chat")]),
        ])

        #expect(opens == 2)
        #expect(report.entries.map(\.outcome) == [.opened, .opened, .unresolved(.stoppedBecauseYouSwitched)])
    }

    // MARK: Chrome cold start (D8c, refined by the spike)

    @Test func coldChromeThatRestoresItsSessionStartsBareFirst() async {
        let mac = FakeMac(screens: [[1, 2]])
        mac.restoring = ["Default"]
        mac.restoredProfiles = ["floo.one"]
        let report = await setup(mac).run([role("Personal", 2, [personal()])])

        #expect(mac.opened == [.chromeBare], "the restored window already is the profile's window")
        #expect(report.entries.map(\.outcome) == [.alreadyThere])
    }

    @Test func coldChromeThatDoesNotRestoreOpensTheProfileDirectly() async {
        let mac = FakeMac(screens: [[1, 2]])
        let report = await setup(mac).run([role("Personal", 2, [personal()])])

        #expect(mac.opened == [.chromeWindow(profileDirectory: "Default", urls: ["https://claude.ai"])])
        #expect(report.opened == 1)
    }

    // MARK: Cancel, restore, tint

    @Test func cancellingReportsTheRestAsCancelled() async {
        let mac = FakeMac(screens: [[1, 2, 3]])
        mac.afterOpen = { withUnsafeCurrentTask { $0?.cancel() } }
        let report = await setup(mac).run([
            role("Comms", 2, [.app(bundleID: slack), .app(bundleID: mail)]),
            role("Build", 3, [.app(bundleID: "com.openai.chat")]),
        ])
        #expect(report.entries.map(\.outcome) == [.opened, .unresolved(.cancelled), .unresolved(.cancelled)])
        #expect(mac.opened.count == 1, "nothing opens after the cancel")
    }

    @Test func focusedScreenIsRestoredLast() async {
        let mac = FakeMac(screens: [[1, 2], [3, 4]])
        mac.focusedScreen = 0
        _ = await setup(mac).run([role("A", 2, []), role("B", 4, [])])
        #expect(mac.switches == [2, 4, 3, 1])
    }

    @Test func retintCoversOnlyShowingDesktops() {
        let mac = FakeMac(screens: [[1, 2], [3]])
        setup(mac).retintShowing([role("A", 1, []), role("B", 2, []), role("C", 3, [])])
        #expect(mac.tints.map(\.desktop) == [1, 3])
    }

    // MARK: Model and storage

    @Test func desktopNumbersMustBeUniqueAndOneToNine() {
        let roles = [role("A", 1, []), role("B", 1, []), role("C", 10, []), role("D", 9, [])]
        #expect(DesktopRole.invalidDesktopNumbers(in: roles) == [1, 10])
    }

    @Test func rolesSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "DesktopSetupTests"))
        defaults.removePersistentDomain(forName: "DesktopSetupTests")
        let roles = [role("Comms", 2, [.app(bundleID: slack), personal()])]
        Preferences(defaults: defaults).desktopRoles = roles
        #expect(Preferences(defaults: defaults).desktopRoles == roles)
        defaults.removePersistentDomain(forName: "DesktopSetupTests")
    }

    @Test func backgroundsSurviveARelaunch() throws {
        var glow = role("Build", 3, [])
        glow.background = .colored(.solid)
        var picture = role("Home", 4, [])
        picture.background = .image(path: "/System/Library/Desktop Pictures/Example.heic")
        let data = try JSONEncoder().encode([glow, picture])
        #expect(try JSONDecoder().decode([DesktopRole].self, from: data) == [glow, picture])
    }

    @Test func rolesSavedBeforeBackgroundsGetRadialInTheirColor() throws {
        let old = ##"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","colorHex":"#2563EB","desktopNumber":2,"items":[]}]"##
        let roles = try JSONDecoder().decode([DesktopRole].self, from: Data(old.utf8))
        #expect(roles.first?.background == .colored(.radial))
        #expect(roles.first?.colorHex == "#2563EB")
    }

    @Test func aStyleFromAnEarlierBuildBecomesRadial() throws {
        let old = ##"{"colored":{"_0":"aurora"}}"##
        #expect(try JSONDecoder().decode(RoleBackground.self, from: Data(old.utf8)) == .colored(.radial))
    }

    // MARK: Roles follow desktops

    private func bound(_ name: String, _ number: Int, _ id: String?) -> DesktopRole {
        var role = role(name, number, [])
        role.desktopID = id
        return role
    }

    @Test func aRoleFollowsItsDesktopWhenMissionControlReordersThem() {
        // Sales on desktop 2 (id B), Personal on 3 (id C); C is dragged before B.
        let roles = [bound("Sales", 2, "B"), bound("Personal", 3, "C")]
        let after = DesktopBinding.reconcile(roles, ids: [1: "A", 2: "C", 3: "B"])
        #expect(after.map(\.desktopNumber) == [3, 2])
        #expect(after.map(\.desktopID) == ["B", "C"])
    }

    @Test func unboundRolesBindToTheDesktopAtTheirNumber() {
        let after = DesktopBinding.reconcile([bound("Sales", 2, nil)], ids: [1: "A", 2: "B"])
        #expect(after.first?.desktopID == "B")
        #expect(after.first?.desktopNumber == 2)
    }

    @Test func aRoleWhoseDesktopWasDeletedBindsAgainByNumber() {
        let after = DesktopBinding.reconcile([bound("Sales", 3, "gone")], ids: [1: "A", 2: "B", 3: "C"])
        #expect(after.first?.desktopID == "C")
        #expect(after.first?.desktopNumber == 3)
    }

    @Test func anUnboundRoleNeverTakesABoundRolesDesktop() {
        // Personal's desktop moved to 2; Sales lost its desktop and still says 2.
        let roles = [bound("Sales", 2, "gone"), bound("Personal", 3, "C")]
        let after = DesktopBinding.reconcile(roles, ids: [1: "A", 2: "C", 3: "D"])
        #expect(after[1].desktopNumber == 2)
        #expect(after[0].desktopNumber == 1)
        #expect(after[0].desktopID == "A")
        #expect(DesktopRole.invalidDesktopNumbers(in: after).isEmpty)
    }

    @Test func unreadableDesktopsChangeNothing() {
        let roles = [bound("Sales", 2, "B")]
        #expect(DesktopBinding.reconcile(roles, ids: [:]) == roles)
    }

    @Test func bindingsSurviveARelaunch() throws {
        let roles = [bound("Sales", 2, "ECC5DBD4-DB2E-459B-BD18-814E0FCB20C8")]
        let data = try JSONEncoder().encode(roles)
        #expect(try JSONDecoder().decode([DesktopRole].self, from: data) == roles)
    }
}
