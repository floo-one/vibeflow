import AppKit
import Observation
import OSLog
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "desktops")

/// Desktop Roles in the app (docs/designs/desktop-roles.md): runs the morning walk, keeps the
/// menu bar tag on the focused desktop's role and the tint of every showing desktop current.
@MainActor
@Observable
final class DesktopsController {
    let setup: DesktopSetup
    /// The role of the desktop showing on the focused screen; nil hides the tag.
    private(set) var currentRole: DesktopRole?
    /// VibeFlow Dev leaves the desktops to the release while both run (eng review D8d).
    private(set) var isPaused = false
    /// The last walk, while it runs; the shortcut pressed again cancels it.
    @ObservationIgnored private var walk: Task<Void, Never>?
    @ObservationIgnored private let live: LiveDesktops
    @ObservationIgnored private let preferences: Preferences
    /// The menu bar tag. An own NSStatusItem set straight from `refresh()`: a SwiftUI
    /// MenuBarExtra followed a desktop switch only when SwiftUI re-evaluated the scene, visibly late.
    @ObservationIgnored private lazy var tag = RoleTagItem(controller: self)
    /// Set by AppContainer: opens Settings > Desktops, and names apps for the tag's report lines.
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var appName: (String?) -> String = { $0 ?? "" }

    static let releaseBundleID = "one.floo.vibeflow"

    init(preferences: Preferences, isBusy: @escaping @MainActor () -> Bool) {
        let live = LiveDesktops()
        self.live = live
        self.preferences = preferences
        setup = DesktopSetup(control: live, windows: live, launcher: live, isBusy: isBusy)
        observe()
        refresh()
        watchForReorders()
        // Core Image takes half a second to start: pay it now, off the main thread, so
        // Settings > Desktops opens at once.
        let roles = preferences.desktopRoles
        Task.detached(priority: .utility) {
            for role in roles {
                for background in [role.background] + BackgroundPicker.offered.map(RoleBackground.colored) {
                    _ = RoleWallpaper.thumbnail(background, colorHex: role.colorHex, size: BackgroundPicker.thumbnailSize)
                }
            }
        }
    }

    var roles: [DesktopRole] { preferences.desktopRoles }
    var isWalking: Bool { setup.isRunning }
    var layout: DesktopLayout? { live.layout() }

    /// Shortcut and "Set Up All": every role, or stop the walk that is running.
    func setUpOrStop() {
        if let walk {
            walk.cancel()
            return
        }
        setUp(roles)
    }

    /// Some mornings need only some roles: sets up just these.
    func setUp(_ roles: [DesktopRole]) {
        guard walk == nil, !isPaused, !roles.isEmpty else { return }
        walk = Task { [weak self] in
            guard let self else { return }
            let report = await setup.run(roles)
            log.notice("walk: opened \(report.opened), already there \(report.alreadyThere), unresolved \(report.unresolved.count), refusal \(String(describing: report.refusal), privacy: .public)")
            walk = nil
            refresh()
        }
    }

    /// Roles changed in Settings: the tag and tints follow at once.
    func rolesChanged() { refresh() }

    /// Re-reads the focused desktop's role and re-tints what is showing. Never switches desktops.
    func refresh() {
        #if DEBUG
        isPaused = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.releaseBundleID).isEmpty
        #endif
        guard !isPaused, !roles.isEmpty, let layout = live.layout() else {
            currentRole = nil
            tag.show(nil)
            return
        }
        // Roles follow their desktops: a reorder in Mission Control moves the numbers along.
        let bound = DesktopBinding.reconcile(roles, ids: layout.desktopIDs)
        if bound != roles { preferences.desktopRoles = bound }
        let focused = layout.focusedDesktop
        currentRole = bound.first { $0.desktopNumber == focused }
        // The tag first: it is what you look at right after switching.
        tag.show(preferences.desktopRoleTag ? currentRole : nil)
        if !setup.isRunning { setup.retintShowing(roles) }
    }

    /// Dragging desktops around in Mission Control posts no notification, so the layout is read
    /// again every 2 s (one SkyLight call, microseconds) and refreshed only when the order changed.
    private func watchForReorders() {
        Task { [weak self] in
            var last = self?.live.layout()?.desktopIDs
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard !roles.isEmpty, !isWalking else { continue }
                let now = live.layout()?.desktopIDs
                if now != last {
                    last = now
                    refresh()
                }
            }
        }
    }

    /// The desktop ID at `number` now, for Settings when a role is moved by hand.
    func desktopID(at number: Int) -> String? { live.layout()?.desktopIDs[number] }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

// MARK: - Setup check (Settings > Desktops)

/// The macOS settings Desktop Roles relies on, read only (spike `spaces`).
enum DesktopsCheck {
    struct Row: Identifiable {
        let title: String
        let ok: Bool
        let detail: String
        let fix: URL?
        var id: String { title }
    }

    static let desktopSettings = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    static func rows(roles: [DesktopRole], layout: DesktopLayout?, accessibilityTrusted: Bool) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(
            title: "Accessibility", ok: accessibilityTrusted,
            detail: accessibilityTrusted ? "Granted" : "Needed to switch desktops and find windows",
            fix: accessibilityTrusted ? nil : Accessibility.settingsURL))
        let separate = !bool("spans-displays", "com.apple.spaces", default: false)
        rows.append(Row(
            title: "Displays have separate Spaces", ok: separate,
            detail: separate ? "On: each screen switches on its own" : "Turn on in Desktop & Dock, then log out",
            fix: separate ? nil : desktopSettings))
        let rearrange = bool("mru-spaces", "com.apple.dock", default: true)
        rows.append(Row(
            title: "Automatically rearrange Spaces", ok: !rearrange,
            detail: rearrange ? "Turn off, or desktop numbers shift" : "Off", fix: rearrange ? desktopSettings : nil))
        let jump = bool("AppleSpacesSwitchOnActivate", kCFPreferencesAnyApplication as String, default: true)
        rows.append(Row(
            title: "Switch to a Space with open windows", ok: !jump,
            detail: jump ? "Turn off, or opening an app jumps away" : "Off", fix: jump ? desktopSettings : nil))
        let count = layout?.desktopCount ?? 0
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        for role in roles.sorted(by: { $0.desktopNumber < $1.desktopNumber }) {
            let n = role.desktopNumber
            if n > count {
                rows.append(Row(title: "Desktop \(n) (\(role.name))", ok: false,
                                detail: "Missing: add it in Mission Control", fix: nil))
                continue
            }
            // Symbolic hotkey ids 118...126 are Switch to Desktop 1...9.
            let enabled = ((hotkeys[String(117 + n)] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue ?? false
            rows.append(Row(title: "Switch to Desktop \(n) (\(role.name))", ok: enabled,
                            detail: enabled ? "Shortcut on" : "Turn on in Keyboard Shortcuts > Mission Control",
                            fix: enabled ? nil : keyboardSettings))
        }
        return rows
    }

    private static func bool(_ key: String, _ domain: String, default value: Bool) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        return (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.boolValue ?? value
    }
}

// MARK: - Role tag (menu bar)

/// The role tag in the menu bar, shown when turned on in Settings > Desktops while the focused
/// screen shows a role's desktop. Its menu is built each time it opens (the Desktops menu:
/// set up all or one role, the last report, Desktops Settings).
@MainActor
final class RoleTagItem: NSObject, NSMenuDelegate {
    private unowned let controller: DesktopsController
    private var item: NSStatusItem?
    private var shown: (name: String, color: String)?

    init(controller: DesktopsController) {
        self.controller = controller
    }

    func show(_ role: DesktopRole?) {
        guard let role else {
            item?.isVisible = false
            shown = nil
            return
        }
        let item = item ?? makeItem()
        if shown?.name != role.name || shown?.color != role.colorHex {
            item.button?.image = RoleTag.image(name: role.name, colorHex: role.colorHex)
            item.button?.setAccessibilityLabel("Desktop role: \(role.name)")
            shown = (role.name, role.colorHex)
        }
        item.isVisible = true
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "VibeFlowDesktopRole"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let desktops = controller
        if desktops.isPaused {
            menu.addItem(withTitle: "Paused: the installed VibeFlow handles desktops", action: nil, keyEquivalent: "").isEnabled = false
        }
        let all = ActionMenuItem(desktops.isWalking ? "Stop Setting Up" : "Set Up All") { desktops.setUpOrStop() }
        all.isEnabled = !desktops.roles.isEmpty && !desktops.isPaused
        menu.addItem(all)
        for role in desktops.roles {
            let one = ActionMenuItem("Set Up \(role.name) · Desktop \(role.desktopNumber)") { desktops.setUp([role]) }
            one.isEnabled = !desktops.isWalking && !desktops.isPaused
            menu.addItem(one)
        }
        if let report = desktops.setup.lastReport {
            menu.addItem(.separator())
            menu.addItem(withTitle: DesktopReportFormat.summary(report), action: nil, keyEquivalent: "").isEnabled = false
            for entry in report.unresolved {
                menu.addItem(withTitle: DesktopReportFormat.line(entry, appName: desktops.appName), action: nil, keyEquivalent: "").isEnabled = false
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Desktops Settings…") { desktops.openSettings() })
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

/// The menu bar tag: the role name in white on a rounded rectangle of the role color. A drawn,
/// non-template image, because menu bar labels drop text color (eng review D3).
enum RoleTag {
    static func image(name: String, colorHex: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = NSSize(width: ceil(text.size().width) + 12, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(hex: colorHex).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let textSize = text.size()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension NSColor {
    /// "#RRGGBB"; grey for anything else.
    convenience init(hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = clean.count == 6 ? UInt32(clean, radix: 16) ?? 0x808080 : 0x808080
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}
