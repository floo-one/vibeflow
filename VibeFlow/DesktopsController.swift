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

    static let releaseBundleID = "one.floo.vibeflow"

    init(preferences: Preferences, isBusy: @escaping @MainActor () -> Bool) {
        let live = LiveDesktops()
        self.live = live
        self.preferences = preferences
        setup = DesktopSetup(control: live, windows: live, launcher: live, isBusy: isBusy)
        observe()
        refresh()
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
            return
        }
        let focused = layout.focusedScreen.flatMap { layout.screens.indices.contains($0) ? layout.screens[$0].showing : nil }
        currentRole = roles.first { $0.desktopNumber == focused }
        if !setup.isRunning { setup.retintShowing(roles) }
    }

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
