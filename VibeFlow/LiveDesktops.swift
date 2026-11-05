import AppKit
import ApplicationServices
import VibeFlowCore

// Desktop Roles on the real Mac (eng review T3). Everything here was tried first in
// Spike/desktops-spike.swift on macOS 26; the findings are in docs/designs/desktop-roles.md.
// The SkyLight calls only read: they list desktops and say which desktop a window is on.
// Switching posts Control+N, placement uses Accessibility, wallpaper uses NSWorkspace.

// MARK: - Private, read-only SkyLight calls

private enum SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // Written once at first use and only read afterwards.
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    /// The SLS name first, then the CGS alias CoreGraphics still exports. nil when macOS dropped it.
    private static func symbol<T>(_ names: String..., as type: T.Type) -> T? {
        for name in names {
            if let handle, let pointer = dlsym(handle, name) { return unsafeBitCast(pointer, to: type) }
            if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(pointer, to: type) }
        }
        return nil
    }

    static let mainConnection = symbol("SLSMainConnectionID", "CGSMainConnectionID", as: MainConnection.self)
    static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    static let getActiveSpace = symbol("SLSGetActiveSpace", "CGSGetActiveSpace", as: GetActiveSpace.self)
    static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
    static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindow.self)
}

// MARK: - LiveDesktops

@MainActor
final class LiveDesktops: DesktopControl, DesktopWindows, AppLauncher {
    /// One display's desktops as SkyLight lists them; "Main" when separate Spaces are off.
    private struct Display {
        var identifier: String
        var current: UInt64
        /// Regular desktops only (type 0), in Mission Control order.
        var desktops: [UInt64]
        /// Every space including full-screen apps.
        var spaces: [UInt64]
    }

    /// kVK_ANSI_1 ... kVK_ANSI_9; the digits are not in key-code order.
    private static let digitKeyCodes: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
    /// Eng review D7: a hung app can block an Accessibility call for seconds.
    private static let accessibilityTimeout: Float = 0.5

    // MARK: DesktopControl

    func layout() -> DesktopLayout? {
        guard let displays = displays() else { return nil }
        let active = SkyLight.mainConnection.flatMap { connection in SkyLight.getActiveSpace.map { $0(connection()) } }
        var number = 0
        var screens: [DesktopLayout.Screen] = []
        var focused: Int?
        for (index, display) in displays.enumerated() {
            let numbers = display.desktops.map { _ in number += 1; return number }
            let showing = display.desktops.firstIndex(of: display.current).map { numbers[$0] }
            screens.append(.init(desktops: numbers, showing: showing))
            if let active, display.spaces.contains(active) { focused = index }
        }
        return DesktopLayout(screens: screens, focusedScreen: focused)
    }

    func switchTo(desktop: Int) {
        guard let key = Self.digitKeyCodes[desktop] else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            // Control only: modifiers still held from the key that started the walk must not leak in.
            event?.flags = .maskControl
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Bumped on every tint per desktop, so a slow render that finishes after a newer one (quick
    /// color clicks in Settings) does not put the older look back.
    private var tintGeneration: [Int: Int] = [:]

    /// A wallpaper drawn before is set at once; a new one renders in the background (0.5 s or so at
    /// 5K) and is set when done, if that desktop is still showing then. A desktop the walk left
    /// before then gets it from the next retint, when it shows again.
    func tint(desktop: Int, role: DesktopRole) {
        let generation = (tintGeneration[desktop] ?? 0) + 1
        tintGeneration[desktop] = generation
        for screen in screens(showing: desktop) {
            let pixels = NSSize(width: screen.frame.width * screen.backingScaleFactor,
                                height: screen.frame.height * screen.backingScaleFactor)
            guard let url = try? RoleWallpaper.url(for: role, pixels: pixels) else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                setWallpaper(url, on: screen)
                continue
            }
            let display = Self.displayNumber(of: screen)
            Task { [weak self] in
                let rendered = await Task.detached(priority: .userInitiated) {
                    (try? RoleWallpaper.render(role, pixels: pixels, to: url)) != nil
                }.value
                guard rendered, let self, tintGeneration[desktop] == generation else { return }
                for screen in screens(showing: desktop) where Self.displayNumber(of: screen) == display {
                    setWallpaper(url, on: screen)
                }
            }
        }
    }

    private func setWallpaper(_ url: URL, on screen: NSScreen) {
        guard NSWorkspace.shared.desktopImageURL(for: screen) != url else { return }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .allowClipping: true,
        ]
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private static func displayNumber(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: DesktopWindows

    func inventory(ofDesktop desktop: Int) -> DesktopInventory {
        guard let space = spaceID(ofDesktop: desktop) else { return DesktopInventory() }
        var inventory = DesktopInventory()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard let windows = Self.axWindows(of: app.processIdentifier) else {
                inventory.unreadable.insert(bundleID)
                continue
            }
            for window in windows {
                // Standard windows only: Chrome's sign-in popups and bubbles are AXUnknown (spike).
                guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      let id = Self.windowID(of: window), spaces(ofWindow: id).contains(space)
                else { continue }
                inventory.windows.append(DesktopWindow(id: id, bundleID: bundleID, title: Self.string(window, kAXTitleAttribute) ?? ""))
            }
        }
        return inventory
    }

    func appWindows(bundleID: String) -> AppWindows {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { return .notRunning }
        let numbers = desktopNumbers()
        let desktops = Set(realWindows(pids: pids).flatMap { spaces(ofWindow: $0) }.compactMap { numbers[$0] })
        // Minimized windows: the spike could not yet tell them from helper windows, which also sit
        // on no desktop, so they are not reported as unplaced (open question in the design doc).
        return AppWindows(isRunning: true, desktops: desktops)
    }

    func windowIDs(bundleID: String) -> Set<UInt32> {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        return Set(realWindows(pids: pids).filter { !spaces(ofWindow: $0).isEmpty })
    }

    func desktop(ofWindow id: UInt32) -> Int? {
        let numbers = desktopNumbers()
        return spaces(ofWindow: id).lazy.compactMap { numbers[$0] }.first
    }

    func moveWindow(_ id: UInt32, toScreenOf desktop: Int) -> Bool {
        guard let screen = screens(showing: desktop).first, let element = Self.axElement(ofWindow: id) else { return false }
        // AX positions are top-left based in global coordinates; NSScreen frames are bottom-left based.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let visible = screen.visibleFrame
        var point = CGPoint(x: visible.minX + 40, y: primaryHeight - visible.maxY + 40)
        guard let position = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success
    }

    // MARK: AppLauncher

    func open(_ request: LaunchRequest) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        let bundleID: String
        switch request {
        case .app(let id):
            bundleID = id
        case .chromeBare:
            bundleID = RoleItem.chromeBundleID
        case .chromeWindow(let directory, let urls):
            bundleID = RoleItem.chromeBundleID
            configuration.arguments = ["--profile-directory=\(directory)", "--new-window"] + urls
            // A running Chrome ignores arguments unless a new instance hands them over.
            configuration.createsNewApplicationInstance = true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw LaunchFailure(bundleID: bundleID)
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func restoresSession(chromeProfile directory: String) -> Bool {
        let preferences = ChromeProfiles.folder.appendingPathComponent(directory).appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: preferences),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = json["session"] as? [String: Any]
        else { return false }
        // Chrome's "On startup": 1 = continue where you left off, 4 = specific pages, 5 = new tab.
        return (session["restore_on_startup"] as? Int) == 1
    }

    // MARK: Desktops

    private func displays() -> [Display]? {
        guard let connection = SkyLight.mainConnection, let copy = SkyLight.copyManagedDisplaySpaces,
              let list = copy(connection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        func id(_ dict: [String: Any]) -> UInt64? {
            (dict["id64"] as? NSNumber)?.uint64Value ?? (dict["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }
        return list.map { entry in
            let spaces = entry["Spaces"] as? [[String: Any]] ?? []
            return Display(
                identifier: entry["Display Identifier"] as? String ?? "",
                current: (entry["Current Space"] as? [String: Any]).flatMap(id) ?? 0,
                desktops: spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap(id),
                spaces: spaces.compactMap(id))
        }
    }

    /// Space id -> desktop number, numbered across screens like Mission Control.
    private func desktopNumbers() -> [UInt64: Int] {
        var numbers: [UInt64: Int] = [:]
        for space in (displays() ?? []).flatMap(\.desktops) { numbers[space] = numbers.count + 1 }
        return numbers
    }

    private func spaceID(ofDesktop desktop: Int) -> UInt64? {
        desktopNumbers().first { $0.value == desktop }?.key
    }

    private func spaces(ofWindow id: UInt32) -> [UInt64] {
        guard let connection = SkyLight.mainConnection, let copy = SkyLight.copySpacesForWindows else { return [] }
        // Mask 7: current, other and user spaces.
        let result = copy(connection(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return result?.map(\.uint64Value) ?? []
    }

    /// The screens showing `desktop`: its own screen with separate Spaces, every screen without.
    private func screens(showing desktop: Int) -> [NSScreen] {
        guard let space = spaceID(ofDesktop: desktop),
              let display = (displays() ?? []).first(where: { $0.desktops.contains(space) }),
              display.current == space
        else { return [] }
        if display.identifier == "Main" { return NSScreen.screens }
        return NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return false }
            return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(display.identifier) == .orderedSame
        }
    }

    // MARK: Windows

    /// Real windows of these processes: layer 0, at least 100 x 100 pt, visible. Window ids, owners,
    /// layers and bounds need no Screen Recording permission; titles would.
    private func realWindows(pids: Set<pid_t>) -> [UInt32] {
        guard !pids.isEmpty else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 100
            else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    /// The app's AX windows, nil when it did not answer within the 0.5 s cap (inventory incomplete).
    private static func axWindows(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) {
        case .success: return value as? [AXUIElement] ?? []
        case .cannotComplete: return nil
        default: return []
        }
    }

    private static func axElement(ofWindow id: UInt32) -> AXUIElement? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        guard let pid = (list.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        return axWindows(of: pid)?.first { windowID(of: $0) == id }
    }

    private static func windowID(of element: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        guard let get = SkyLight.axGetWindow, get(element, &id) == .success else { return nil }
        return id
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

struct LaunchFailure: LocalizedError {
    let bundleID: String
    var errorDescription: String? { "\(bundleID) is not installed" }
}

// MARK: - Chrome profiles (for the Desktops tab)

enum ChromeProfiles {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    /// Profile directory and the name Chrome shows for it, from Chrome's Local State, sorted by name.
    static func list() -> [(directory: String, name: String)] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [] }
        return cache.map { directory, info in (directory, (info as? [String: Any])?["name"] as? String ?? directory) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
