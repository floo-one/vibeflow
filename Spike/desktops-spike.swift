// Desktop Roles, task T1: spike for the open questions in docs/designs/desktop-roles.md (eng review D2).
//
// Answers on the real Mac, before any app code:
//   premise 4  read-only private calls list the desktops and the active one        spaces
//   premise 2  a new window opens on the desktop that is active at launch         chrome
//   premise 3  the wallpaper is stored per desktop                                 tint, wallpaper
//   Q1  does a Chrome window's Accessibility title carry its profile name?         chrome, windows
//   Q2  where does a new profile window land while Chrome has windows elsewhere?   chrome
//   Q4  does the tint survive sleep and a monitor unplug/replug?                   wallpaper
//   Q5  does AXWindows list only this desktop's windows (minimized, hidden apps)?  windows
//   Q6  where do restored windows land when Chrome starts (D8c, blocking)?         chrome --bare (Chrome quit first)
//   Q7  do apps launched hidden own phantom windows in CGWindowList?               windows --all
//   Q8  can a window move to another desktop with SIP on (title-bar drag + Control+N)?  throw
//   Q9  can a desktop be added with SIP on (Mission Control's + via Accessibility)?      add-desktop
//
// Usage (from the repo root; Command Line Tools are enough):
//   swift Spike/desktops-spike.swift spaces                  desktops per display, active one, the four settings
//   swift Spike/desktops-spike.swift switch 3                press Control+3, wait up to 2 s for the change
//   swift Spike/desktops-spike.swift tint 3 '#3B82F6'        switch to desktop 3 and tint every screen there
//   swift Spike/desktops-spike.swift wallpaper               the wallpaper of each screen on this desktop
//   swift Spike/desktops-spike.swift set-wallpaper <path>    put a wallpaper back (tint prints the old ones)
//   swift Spike/desktops-spike.swift windows [--all]         AX against CGWindowList, with each window's desktop
//   swift Spike/desktops-spike.swift profiles                Chrome profiles from Chrome's Local State
//   swift Spike/desktops-spike.swift add-desktop [--screen N] open Mission Control, press + (on screen N, 1 = first),
//       confirm a desktop was added, close Mission Control
//   swift Spike/desktops-spike.swift throw 3 [--grab-x 0.5]  after 3 s, carry the focused window to desktop 3
//       the way yabai-dockstack does with SIP on: press on its title bar, Control+3, release.
//       Click the window to move during the 3 s. --grab-x is where along the title bar to press
//       (0...1 of the width; Chrome's tab strip needs an empty spot, try 0.9).
//   swift Spike/desktops-spike.swift chrome 'Profile 1' https://claude.ai [--bare] [--no-activate] [--move-to N]
//       open a window of that profile while this desktop is active and watch where it lands;
//       --bare (when Chrome is not running) starts Chrome without arguments first and lets the
//       session restore settle, the order chosen in D8c; --move-to N moves a window that landed on the
//       wrong screen onto desktop N's screen (the premise 2 fix to prove)
//
// switch, tint, windows and chrome need the Accessibility permission for the terminal app that
// runs this script (System Settings > Privacy & Security > Accessibility). Switching needs
// "Switch to Desktop N" on in Keyboard Shortcuts > Mission Control. tint replaces your wallpaper
// on that desktop: it prints the previous one and the command that puts it back.
// Nothing here writes private state: the SkyLight calls only read.

import AppKit
import ApplicationServices

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let text): return "usage: \(text)"
        case .failed(let text): return text
        }
    }
}

// MARK: - Private, read-only SkyLight calls (loaded at runtime, nil when missing)

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

/// The SLS name first, then the older CGS alias that CoreGraphics still exports.
func privateSymbol<T>(_ names: String..., as type: T.Type) -> T? {
    for name in names {
        if let skyLight, let pointer = dlsym(skyLight, name) { return unsafeBitCast(pointer, to: type) }
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(pointer, to: type) }
    }
    return nil
}

typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let mainConnection = privateSymbol("SLSMainConnectionID", "CGSMainConnectionID", as: MainConnectionFn.self)
let copyManagedDisplaySpaces = privateSymbol("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
let getActiveSpace = privateSymbol("SLSGetActiveSpace", "CGSGetActiveSpace", as: GetActiveSpaceFn.self)
let copySpacesForWindows = privateSymbol("SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
let axGetWindow = privateSymbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)

// MARK: - Desktops

struct Space {
    let id: UInt64
    /// 0 is a regular desktop, 4 a full-screen app.
    let type: Int
}

struct DisplaySpaces {
    let display: String
    let current: UInt64
    let spaces: [Space]

    /// Desktop numbers count regular desktops only, the way Control+N does.
    var desktops: [Space] { spaces.filter { $0.type == 0 } }
}

func spaceID(_ dict: [String: Any]) -> UInt64? {
    (dict["id64"] as? NSNumber)?.uint64Value ?? (dict["ManagedSpaceID"] as? NSNumber)?.uint64Value
}

func managedSpaces() throws -> [DisplaySpaces] {
    guard let mainConnection, let copyManagedDisplaySpaces else {
        throw SpikeError.failed("premise 4 FAILED: SLSCopyManagedDisplaySpaces / SLSMainConnectionID not found")
    }
    guard let list = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else {
        throw SpikeError.failed("premise 4 FAILED: SLSCopyManagedDisplaySpaces returned nothing")
    }
    return list.map { entry in
        let current = (entry["Current Space"] as? [String: Any]).flatMap(spaceID) ?? 0
        let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { dict -> Space? in
            guard let id = spaceID(dict) else { return nil }
            return Space(id: id, type: (dict["type"] as? NSNumber)?.intValue ?? -1)
        }
        return DisplaySpaces(display: entry["Display Identifier"] as? String ?? "?", current: current, spaces: spaces)
    }
}

func activeSpace() -> UInt64? {
    guard let mainConnection, let getActiveSpace else { return nil }
    return getActiveSpace(mainConnection())
}

/// Mission Control numbers regular desktops across displays in list order (with separate Spaces,
/// desktops 1-3 on the first display, 4-5 on the next); Control+N switches only that display.
func numberedDesktops(_ displays: [DisplaySpaces]) -> [(number: Int, display: DisplaySpaces, space: Space)] {
    var result: [(number: Int, display: DisplaySpaces, space: Space)] = []
    for display in displays {
        for space in display.desktops { result.append((result.count + 1, display, space)) }
    }
    return result
}

func displayName(_ display: DisplaySpaces) -> String {
    if display.display == "Main" { return "all screens" }
    return screen(for: display).map(\.localizedName) ?? String(display.display.prefix(8))
}

/// "desktop 3 on Monitor", "full screen on <screen>" or the raw id when it is in no list.
func describe(_ id: UInt64, in displays: [DisplaySpaces]) -> String {
    if let match = numberedDesktops(displays).first(where: { $0.space.id == id }) {
        return "desktop \(match.number) on \(displayName(match.display))"
    }
    if let display = displays.first(where: { $0.spaces.contains { $0.id == id } }) { return "full screen on \(displayName(display))" }
    return "space \(id) (unknown)"
}

/// The desktop number of the active space, nil on a full-screen space or when unreadable.
func activeDesktopNumber() -> Int? {
    guard let displays = try? managedSpaces(), let active = activeSpace() else { return nil }
    return numberedDesktops(displays).first(where: { $0.space.id == active })?.number
}

/// The NSScreen behind a display UUID from SkyLight; nil for "Main" (all screens) or an unknown UUID.
func screen(for display: DisplaySpaces) -> NSScreen? {
    NSScreen.screens.first { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return false }
        return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(display.display) == .orderedSame
    }
}

/// The screens a desktop shows on: its own display with separate Spaces, every screen without.
func screens(forDesktop n: Int) -> [NSScreen] {
    guard let displays = try? managedSpaces(), let match = numberedDesktops(displays).first(where: { $0.number == n }),
          match.display.display != "Main", let screen = screen(for: match.display)
    else { return NSScreen.screens }
    return [screen]
}

/// The desktop number currently showing on the screen that holds desktop n.
func currentDesktopNumber(onScreenOf n: Int) -> Int? {
    guard let displays = try? managedSpaces(), let match = numberedDesktops(displays).first(where: { $0.number == n }) else { return nil }
    return numberedDesktops(displays).first(where: { $0.space.id == match.display.current })?.number
}

/// Whether desktop n is the current desktop of its display (with separate Spaces each display has one).
func isCurrent(desktop n: Int) -> Bool {
    guard let displays = try? managedSpaces(), let match = numberedDesktops(displays).first(where: { $0.number == n }) else { return false }
    return match.display.current == match.space.id
}

func spaces(ofWindow id: CGWindowID) -> [UInt64] {
    guard let mainConnection, let copySpacesForWindows else { return [] }
    let ids = [NSNumber(value: id)] as CFArray
    // Mask 7: current, other and user spaces.
    let result = copySpacesForWindows(mainConnection(), 7, ids)?.takeRetainedValue() as? [NSNumber]
    return result?.map(\.uint64Value) ?? []
}

// MARK: - Settings (read only)

func preference(_ key: String, _ domain: CFString) -> Any? {
    CFPreferencesAppSynchronize(domain)
    return CFPreferencesCopyAppValue(key as CFString, domain)
}

func printSettings(desktopCount: Int, displayEntries: Int) {
    let spans = (preference("spans-displays", "com.apple.spaces" as CFString) as? NSNumber)?.boolValue ?? false
    let mru = (preference("mru-spaces", "com.apple.dock" as CFString) as? NSNumber)?.boolValue ?? true
    let switchOnActivate = (preference("AppleSpacesSwitchOnActivate", kCFPreferencesAnyApplication) as? NSNumber)?.boolValue ?? true
    // Separate Spaces (one desktop list per screen) is what the plan uses since 2026-11-03. The setting
    // only takes effect after a log out; until then macOS keeps the old layout.
    let pendingLogout = (!spans && displayEntries == 1 && NSScreen.screens.count > 1) || (spans && displayEntries > 1)
    func row(_ ok: Bool, _ text: String) { print("  [\(ok ? "ok" : "CHANGE")] \(text)") }
    print("Settings the plan relies on:")
    row(!spans && !pendingLogout, "Displays have separate Spaces: "
        + (pendingLogout ? "changed in Settings, not active yet: log out and back in" : spans ? "off (turn on, needs log out)" : "on"))
    row(!mru, "Automatically rearrange Spaces: \(mru ? "on (turn off)" : "off")")
    row(!switchOnActivate, "Switch to a Space with open windows: \(switchOnActivate ? "on (turn off)" : "off")")
    let hotkeys = preference("AppleSymbolicHotKeys", "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
    let shown = max(1, min(desktopCount, 9))
    for n in 1...shown {
        // Symbolic hotkey ids 118...126 are Switch to Desktop 1...9.
        let entry = hotkeys[String(117 + n)] as? [String: Any]
        let enabled = (entry?["enabled"] as? NSNumber)?.boolValue ?? false
        row(enabled, "Switch to Desktop \(n) shortcut: \(enabled ? "on" : "off (Keyboard Shortcuts > Mission Control)")")
    }
}

// MARK: - Switching

/// kVK_ANSI_1 ... kVK_ANSI_9; the digits are not in key-code order.
let digitKeyCodes: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]

final class Flag: @unchecked Sendable {
    var value = false
}

/// Runs the main run loop until `done` returns true or the timeout passes. Returns whether it finished.
@discardableResult
func wait(seconds: TimeInterval, step: TimeInterval = 0.05, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(step))
    }
    return done()
}

func switchToDesktop(_ n: Int) throws {
    guard let key = digitKeyCodes[n] else { throw SpikeError.usage("desktop number 1...9") }
    // Posting key events needs Accessibility too; a sandboxed shell may drop them silently.
    try requireAccessibility()
    if isCurrent(desktop: n) {
        print("Desktop \(n) is already showing on its screen.")
        return
    }
    let changed = Flag()
    let center = NSWorkspace.shared.notificationCenter
    let token = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        changed.value = true
    }
    defer { center.removeObserver(token) }
    let source = CGEventSource(stateID: .hidSystemState)
    let started = Date()
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
        // Control only: held modifiers from the key that started the walk must not leak in (R3-4).
        event?.flags = .maskControl
        event?.post(tap: .cghidEventTap)
    }
    // Confirm by probing the screen's current desktop; the workspace notification is reported but not
    // required, since a command-line process may never receive it (2026-11-04: switch worked, no notification).
    let arrived = wait(seconds: 2) { changed.value || isCurrent(desktop: n) }
    if arrived, !changed.value { wait(seconds: 0.3) { changed.value } }
    let notified = changed.value
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    let landed = currentDesktopNumber(onScreenOf: n)
    if isCurrent(desktop: n) {
        print("Switched to desktop \(n) in \(elapsed) ms (probe confirms; notification \(notified ? "received" : "not received")).")
    } else {
        throw SpikeError.failed(
            "Switch to desktop \(n) not confirmed after \(elapsed) ms: notification \(notified ? "yes" : "no"), "
                + "that screen still shows \(landed.map { "desktop \($0)" } ?? "an unknown / full-screen space"). "
                + "Does pressing Control+\(n) by hand work? If it does, run this from Terminal.app (with Accessibility), "
                + "not from a sandboxed shell.")
    }
}

// MARK: - Adding a desktop (Q9)

/// Every element under `root` (depth-first), with its depth, up to `limit` elements.
func axTree(_ root: AXUIElement, limit: Int = 4000) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var stack = [root]
    while let element = stack.popLast(), out.count < limit {
        out.append(element)
        if let children = attribute(element, kAXChildrenAttribute, as: [AXUIElement].self) {
            stack.append(contentsOf: children.reversed())
        }
    }
    return out
}

func addDesktop(screenIndex: Int) throws {
    try requireAccessibility()
    let before = numberedDesktops(try managedSpaces()).count
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        throw SpikeError.failed("the Dock is not running")
    }
    let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(dockElement, 1)
    let started = Date()
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    // Mission Control's desktop bar shows each screen's + as a button with no title; its
    // description is localized ("add desktop", "Schreibtisch hinzufügen"), so look at all buttons
    // inside a "Spaces Bar"-like group and print them.
    var buttons: [(element: AXUIElement, description: String, x: CGFloat)] = []
    wait(seconds: 3) {
        buttons = axTree(dockElement).compactMap { element in
            guard attribute(element, kAXRoleAttribute, as: String.self) == kAXButtonRole else { return nil }
            let description = attribute(element, kAXDescriptionAttribute, as: String.self) ?? ""
            let title = attribute(element, kAXTitleAttribute, as: String.self) ?? ""
            let identifier = attribute(element, kAXIdentifierAttribute, as: String.self) ?? ""
            let text = [description, title, identifier].filter { !$0.isEmpty }.joined(separator: " | ")
            var origin = CGPoint.zero
            if let value = attribute(element, kAXPositionAttribute, as: AXValue.self) { AXValueGetValue(value, .cgPoint, &origin) }
            return (element, text, origin.x)
        }
        return !buttons.isEmpty
    }
    print("Mission Control buttons (\(buttons.count)) after \(Int(Date().timeIntervalSince(started) * 1000)) ms:")
    for button in buttons { print("  x=\(Int(button.x))  \(button.description.isEmpty ? "(no text)" : button.description)") }
    // AXIdentifier "mc.spaces.add" (2026-11-05, macOS 26.5) is not localized; the words are a fallback.
    let add = buttons
        .filter { b in ["mc.spaces.add", "add desktop", "hinzu"].contains { b.description.lowercased().contains($0) } }
        .sorted { $0.x < $1.x }
    guard !add.isEmpty else {
        pressEscape()
        throw SpikeError.failed("no add-desktop button found in Mission Control (list above)")
    }
    let target = add[min(max(screenIndex - 1, 0), add.count - 1)]
    print("Pressing: \(target.description) (x=\(Int(target.x)))")
    AXUIElementPerformAction(target.element, kAXPressAction as CFString)
    let added = wait(seconds: 2) { ((try? numberedDesktops(managedSpaces()).count) ?? before) > before }
    wait(seconds: 0.3) { false }
    pressEscape()
    let after = numberedDesktops(try managedSpaces()).count
    print("Desktops: \(before) before, \(after) now.")
    print(added ? "RESULT: desktop added. Q9 yes." : "RESULT: no desktop added. Q9 no.")
}

func pressEscape() {
    let source = CGEventSource(stateID: .hidSystemState)
    for keyDown in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
    }
}

// MARK: - Throwing a window to another desktop (Q8)

func throwFocusedWindow(to n: Int, grabX: Double) throws {
    try requireAccessibility()
    guard let key = digitKeyCodes[n] else { throw SpikeError.usage("desktop number 1...9") }
    print("Click the window to move. Carrying it to desktop \(n) in 3 s…")
    wait(seconds: 3) { false }
    guard let app = NSWorkspace.shared.frontmostApplication else { throw SpikeError.failed("no frontmost app") }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = attribute(appElement, kAXFocusedWindowAttribute, as: AXUIElement.self) else {
        throw SpikeError.failed("\(app.localizedName ?? "the app") has no focused window")
    }
    var origin = CGPoint.zero, size = CGSize.zero
    if let value = attribute(window, kAXPositionAttribute, as: AXValue.self) { AXValueGetValue(value, .cgPoint, &origin) }
    if let value = attribute(window, kAXSizeAttribute, as: AXValue.self) { AXValueGetValue(value, .cgSize, &size) }
    var id: CGWindowID = 0
    let hasID = axGetWindow.map { $0(window, &id) == .success } ?? false
    let before = hasID ? spaces(ofWindow: id) : []
    let displays = try managedSpaces()
    print("Window: \(app.localizedName ?? "?") \(Int(size.width))x\(Int(size.height)) at \(Int(origin.x)),\(Int(origin.y)); "
        + "on \(before.map { describe($0, in: displays) }.joined(separator: ", "))")

    // AX and CGEvent share global coordinates (top-left origin). 12 pt down is inside the title bar.
    let grab = CGPoint(x: origin.x + size.width * grabX, y: origin.y + 12)
    let home = CGEvent(source: nil)?.location ?? grab
    let source = CGEventSource(stateID: .hidSystemState)
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let started = Date()
    mouse(.mouseMoved, grab)
    wait(seconds: 0.05) { false }
    mouse(.leftMouseDown, grab)
    wait(seconds: 0.1) { false }
    // A small drag so the window server treats it as a window move, not a click.
    mouse(.leftMouseDragged, CGPoint(x: grab.x + 4, y: grab.y))
    wait(seconds: 0.1) { false }
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
        event?.flags = .maskControl
        event?.post(tap: .cghidEventTap)
    }
    let arrived = wait(seconds: 2) { isCurrent(desktop: n) }
    // Hold a moment after the switch, as a person would, then let go where it was grabbed.
    wait(seconds: 0.4) { false }
    mouse(.leftMouseUp, CGPoint(x: grab.x + 4, y: grab.y))
    wait(seconds: 0.3) { false }
    mouse(.mouseMoved, home)
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    let after = hasID ? spaces(ofWindow: id) : []
    let now = try managedSpaces()
    print("Switch \(arrived ? "confirmed" : "NOT confirmed") after \(elapsed) ms.")
    print("Window is now on \(after.map { describe($0, in: now) }.joined(separator: ", ")).")
    let target = numberedDesktops(now).first { $0.number == n }?.space.id
    if let target, after.contains(target) {
        print("RESULT: moved to desktop \(n). Q8 yes.")
    } else {
        print("RESULT: not moved. Q8 no (or the press missed the title bar: try another --grab-x).")
    }
}

// MARK: - Wallpaper

func color(fromHex text: String) throws -> NSColor {
    let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { throw SpikeError.usage("color as #RRGGBB") }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

/// One solid PNG per color; a fresh file name per color, since macOS caches wallpapers by URL.
func tintImage(_ hex: String) throws -> URL {
    let fill = try color(fromHex: hex)
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("one.floo.vibeflow.spike", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("tint-\(hex.replacingOccurrences(of: "#", with: "").uppercased()).png")
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw SpikeError.failed("could not create the tint bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    fill.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SpikeError.failed("PNG encoding failed") }
    try png.write(to: url)
    return url
}

func screenName(_ screen: NSScreen) -> String {
    screen.localizedName + (screen == NSScreen.main ? " (main)" : "")
}

func printWallpapers() {
    let where_ = activeDesktopNumber().map { "desktop \($0)" } ?? "this space"
    print("Wallpaper on \(where_):")
    for screen in NSScreen.screens {
        print("  \(screenName(screen)): \(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "none")")
    }
}

func tint(desktop n: Int, hex: String) throws {
    try switchToDesktop(n)
    let image = try tintImage(hex)
    let targets = screens(forDesktop: n)
    print("Previous wallpapers on desktop \(n) (to put one back: swift Spike/desktops-spike.swift set-wallpaper <path>, while on desktop \(n)):")
    for screen in targets {
        print("  \(screenName(screen)): \(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "none")")
    }
    let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
        .allowClipping: true,
    ]
    for screen in targets {
        try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: options)
    }
    wait(seconds: 0.5) { false }
    let applied = targets.allSatisfy { NSWorkspace.shared.desktopImageURL(for: $0) == image }
    print("Tinted desktop \(n) \(hex) on \(targets.count) screen(s): read back \(applied ? "matches" : "DIFFERS").")
    print("Premise 3: switch to another desktop and back (or run `wallpaper` there); only desktop \(n) should be tinted, and with separate Spaces only its own screen.")
}

func setWallpaper(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw SpikeError.usage("set-wallpaper <existing image path>") }
    for screen in NSScreen.screens {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }
    printWallpapers()
}

// MARK: - Windows

struct CGWindow {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let onScreen: Bool

    /// The "real window" filter from the plan: layer 0, at least 100 x 100 pt, visible alpha.
    var isReal: Bool { layer == 0 && bounds.width >= 100 && bounds.height >= 100 && alpha > 0 }
}

/// All windows, including other desktops, minimized and hidden ones. Titles would need the Screen
/// Recording permission, so this reads only ids, owners, layers and bounds.
func cgWindows() -> [CGWindow] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        var bounds = CGRect.zero
        if let dict = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
        }
        return CGWindow(
            id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1, bounds: bounds,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
            onScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }
}

struct AXWindow {
    let title: String
    /// AXWindow normally. AXApplication placeholders came back when this ran inside a sandboxed
    /// shell (2026-11-02); such results say nothing about the real AX behavior.
    let role: String
    let subrole: String
    let minimized: Bool
    let size: CGSize
    let windowID: CGWindowID?
}

func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// AXWindows of one app with the 0.5 s messaging cap from D7. The error is set when the call failed or
/// timed out, which D8b counts as an incomplete inventory.
func axWindows(pid: pid_t) -> (windows: [AXWindow], error: AXError?) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    guard result == .success, let elements = value as? [AXUIElement] else { return ([], result) }
    let windows = elements.map { element -> AXWindow in
        var size = CGSize.zero
        if let sizeValue = attribute(element, kAXSizeAttribute, as: AXValue.self) {
            AXValueGetValue(sizeValue, .cgSize, &size)
        }
        var id: CGWindowID = 0
        let hasID = axGetWindow.map { $0(element, &id) == .success } ?? false
        return AXWindow(
            title: attribute(element, kAXTitleAttribute, as: String.self) ?? "",
            role: attribute(element, kAXRoleAttribute, as: String.self) ?? "",
            subrole: attribute(element, kAXSubroleAttribute, as: String.self) ?? "",
            minimized: attribute(element, kAXMinimizedAttribute, as: Bool.self) ?? false,
            size: size, windowID: hasID ? id : nil)
    }
    return (windows, nil)
}

func requireAccessibility() throws {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw SpikeError.failed(
            "Accessibility is off for this terminal app. Turn it on in System Settings > Privacy & Security > "
                + "Accessibility, then run the command again.")
    }
}

func desktopList(_ ids: [UInt64], _ displays: [DisplaySpaces]) -> String {
    ids.isEmpty ? "no desktop" : ids.map { describe($0, in: displays) }.joined(separator: ", ")
}

func printWindows(all: Bool) throws {
    try requireAccessibility()
    let displays = try managedSpaces()
    let active = activeSpace() ?? 0
    print("Active: \(describe(active, in: displays)). AX lists per app; CG lists \(all ? "every window" : "windows on this desktop").")
    let windows = cgWindows()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var placeholders = false
    defer {
        if placeholders {
            print("\nWARNING: AX returned AXApplication placeholders instead of windows. This happens in a sandboxed "
                + "shell; run the command from your own Terminal for real AX answers.")
        }
    }
    for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
        let pid = app.processIdentifier
        let ax = axWindows(pid: pid)
        if ax.windows.contains(where: { $0.role == kAXApplicationRole }) { placeholders = true }
        let mine = windows.filter { $0.pid == pid && $0.layer == 0 }
        let shown = all ? mine : mine.filter { spaces(ofWindow: $0.id).contains(active) }
        guard !ax.windows.isEmpty || !shown.isEmpty || ax.error != nil else { continue }
        print("\n\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))\(app.isHidden ? " HIDDEN" : "")")
        if let error = ax.error {
            print("  AX: error \(error.rawValue)\(error == .cannotComplete ? " (timed out at 0.5 s)" : "") -> inventory incomplete")
        }
        for window in ax.windows {
            let where_ = window.windowID.map { desktopList(spaces(ofWindow: $0), displays) } ?? "window id unknown"
            print("  AX  \"\(window.title)\" \(window.role)/\(window.subrole) \(Int(window.size.width))x\(Int(window.size.height))"
                + "\(window.minimized ? " MINIMIZED" : "") -> \(where_)")
        }
        for window in shown {
            print("  CG  #\(window.id) \(Int(window.bounds.width))x\(Int(window.bounds.height)) alpha \(window.alpha)"
                + "\(window.onScreen ? "" : " off-screen") \(window.isReal ? "REAL" : "phantom") -> "
                + desktopList(spaces(ofWindow: window.id), displays))
        }
    }
    print("\nQ5: AX rows on another desktop mean AXWindows is not per-desktop. Q7: phantom rows for hidden apps "
        + "show what the real-window filter has to drop.")
}

// MARK: - Chrome

let chromeID = "com.google.Chrome"

func chromeProfiles() -> [String: String] {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    guard let data = try? Data(contentsOf: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
    else { return [:] }
    var result: [String: String] = [:]
    for (directory, info) in cache {
        result[directory] = (info as? [String: Any])?["name"] as? String ?? directory
    }
    return result
}

func chromeWindowIDs() -> Set<CGWindowID> {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).map(\.processIdentifier))
    return Set(cgWindows().filter { pids.contains($0.pid) && $0.isReal }.map(\.id))
}

func openChrome(arguments: [String], activates: Bool) throws {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeID) else {
        throw SpikeError.failed("Google Chrome is not installed")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    // A running Chrome ignores arguments unless a new instance carries them over (eng review finding 3).
    configuration.createsNewApplicationInstance = !arguments.isEmpty
    configuration.activates = activates
    let done = Flag()
    let failure = Flag()
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error { print("  open failed: \(error.localizedDescription)"); failure.value = true }
        done.value = true
    }
    wait(seconds: 10) { done.value }
    if failure.value { throw SpikeError.failed("Chrome did not open") }
}

/// The proposed fix for premise 2: a window may not move between desktops, but it may move between
/// screens. Make desktop n current on its screen, then set the window's AX position onto that screen,
/// and check which desktop the window ends up on.
func move(window id: CGWindowID, toDesktop n: Int) throws {
    let displays = try managedSpaces()
    guard let target = numberedDesktops(displays).first(where: { $0.number == n }) else { throw SpikeError.usage("no desktop \(n)") }
    if spaces(ofWindow: id).contains(target.space.id) {
        print("Move: #\(id) is already on desktop \(n).")
        return
    }
    if !isCurrent(desktop: n) { try switchToDesktop(n) }
    let screens = target.display.display == "Main" ? NSScreen.screens : screen(for: target.display).map { [$0] } ?? []
    guard let destination = screens.first else { throw SpikeError.failed("no screen found for desktop \(n)") }
    var element: AXUIElement?
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: chromeID) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { continue }
        for window in windows {
            var windowID: CGWindowID = 0
            if axGetWindow?(window, &windowID) == .success, windowID == id { element = window }
        }
    }
    guard let element else { throw SpikeError.failed("Move: no AX element for #\(id) (is it on a desktop that is showing?)") }
    // AX positions are top-left based in global coordinates; NSScreen frames are bottom-left based.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let visible = destination.visibleFrame
    var point = CGPoint(x: visible.minX + 40, y: primaryHeight - visible.maxY + 40)
    guard let position = AXValueCreate(.cgPoint, &point) else { throw SpikeError.failed("Move: could not build AX position") }
    let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    wait(seconds: 0.5) { false }
    let now = describe(spaces(ofWindow: id).first ?? 0, in: try managedSpaces())
    let ok = spaces(ofWindow: id).contains(target.space.id)
    print("Move: set position on \(destination.localizedName) -> AX \(result == .success ? "ok" : "error \(result.rawValue)"); "
        + "#\(id) is now on \(now). Fix for premise 2 \(ok ? "WORKS" : "does NOT work").")
}

func printChromeWindows(_ ids: Set<CGWindowID>, profiles: [String: String], displays: [DisplaySpaces]) {
    var titles: [CGWindowID: String] = [:]
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: chromeID) {
        for window in axWindows(pid: app.processIdentifier).windows {
            if let id = window.windowID { titles[id] = window.title }
        }
    }
    for id in ids.sorted() {
        let title = titles[id] ?? "(no AX title: other desktop or not visible)"
        let named = profiles.values.filter { !$0.isEmpty && title.contains($0) }
        print("  #\(id) \"\(title)\" -> \(desktopList(spaces(ofWindow: id), displays))"
            + (named.isEmpty ? "" : "  [title names profile \(named.joined(separator: ", "))]"))
    }
}

func chrome(profile: String, url: String, bare: Bool, activates: Bool, moveTo: Int?) throws {
    try requireAccessibility()
    let profiles = chromeProfiles()
    if !profiles.isEmpty, profiles[profile] == nil {
        throw SpikeError.usage("unknown profile directory \"\(profile)\"; run `profiles` (known: \(profiles.keys.sorted().joined(separator: ", ")))")
    }
    var displays = try managedSpaces()
    let start = activeSpace() ?? 0
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).isEmpty
    print("Launching from \(describe(start, in: displays)); Chrome \(wasRunning ? "running" : "not running").")
    var before = chromeWindowIDs()
    if !wasRunning, bare {
        print("Bare start (D8c): Chrome without arguments, waiting for the restore to settle (stable 2 s, max 15 s)...")
        try openChrome(arguments: [], activates: activates)
        var count = -1
        var stableSince = Date()
        let settled = wait(seconds: 15, step: 0.2) {
            let now = chromeWindowIDs().count
            if now != count { count = now; stableSince = Date() }
            return now > 0 && Date().timeIntervalSince(stableSince) >= 2
        }
        before = chromeWindowIDs()
        displays = try managedSpaces()
        print("Q6: \(before.count) window(s) after the restore\(settled ? "" : " (still changing at 15 s)"):")
        printChromeWindows(before, profiles: profiles, displays: displays)
    } else if !wasRunning {
        print("Cold start without --bare: the profile window and any restored windows arrive together (Q6, old order).")
    }
    let launchSpace = activeSpace() ?? start
    print("Opening \(profile) (\(profiles[profile] ?? "?")) with \(url)...")
    try openChrome(arguments: ["--profile-directory=\(profile)", "--new-window", url], activates: activates)
    let budget: TimeInterval = wasRunning || bare ? 8 : 15
    var fresh: Set<CGWindowID> = []
    let started = Date()
    wait(seconds: budget, step: 0.2) {
        fresh = chromeWindowIDs().subtracting(before)
        return !fresh.isEmpty
    }
    // Give a cold start's restored windows a moment to show up next to the new one.
    if !wasRunning && !bare { wait(seconds: 3) { false }; fresh = chromeWindowIDs().subtracting(before) }
    displays = try managedSpaces()
    let after = activeSpace() ?? 0
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    guard !fresh.isEmpty else {
        print("No new Chrome window within \(Int(budget)) s: would be reported unresolved (no relaunch).")
        return
    }
    // Chrome also creates invisible helper windows that sit on no desktop; they are not user windows.
    let helpers = fresh.filter { spaces(ofWindow: $0).isEmpty }
    fresh.subtract(helpers)
    if !helpers.isEmpty { print("Ignored \(helpers.count) helper window(s) on no desktop.") }
    guard !fresh.isEmpty else {
        print("Only helper windows appeared within \(Int(budget)) s: would be reported unresolved.")
        return
    }
    print("\(fresh.count) new window(s) after \(elapsed) ms:")
    printChromeWindows(fresh, profiles: profiles, displays: displays)
    let landed = fresh.allSatisfy { spaces(ofWindow: $0).contains(launchSpace) }
    print("Premise 2 / Q2: \(landed ? "all landed on" : "NOT all on") the launch desktop \(describe(launchSpace, in: displays)).")
    print("Active desktop moved: \(after == launchSpace ? "no" : "yes, now \(describe(after, in: displays))").")
    if fresh.count > 1, !wasRunning { print("Q6: more than one new window: the cold start restored a session next to the profile window.") }
    print("Q1: see whether the titles above name the profile (the [title names profile ...] marks).")
    if let target = moveTo {
        for id in fresh { try move(window: id, toDesktop: target) }
    }
}

// MARK: - Main

func printSpaces() throws {
    let displays = try managedSpaces()
    let active = activeSpace()
    print("Displays: \(displays.count) (one \"Main\" entry means separate Spaces are off)")
    let numbered = numberedDesktops(displays)
    for display in displays {
        let list = display.spaces.map { space -> String in
            let label = numbered.first(where: { $0.space.id == space.id }).map { "desktop \($0.number)" } ?? "full screen"
            return label + (space.id == display.current ? " (current)" : "")
        }
        print("  \(displayName(display)) [\(display.display.prefix(8))]: \(list.joined(separator: ", "))")
    }
    print("Active: \(active.map { describe($0, in: displays) } ?? "unreadable (SLSGetActiveSpace missing)")")
    print("Private calls: CopyManagedDisplaySpaces ok, GetActiveSpace \(getActiveSpace == nil ? "MISSING" : "ok"), "
        + "CopySpacesForWindows \(copySpacesForWindows == nil ? "MISSING" : "ok"), _AXUIElementGetWindow \(axGetWindow == nil ? "MISSING" : "ok")")
    print("")
    printSettings(desktopCount: numbered.count, displayEntries: displays.count)
}

func run(_ args: [String]) throws {
    guard let command = args.first else {
        throw SpikeError.usage("swift Spike/desktops-spike.swift spaces | switch N | tint N #RRGGBB | wallpaper | set-wallpaper PATH | windows [--all] | profiles | chrome DIR URL [--bare] [--no-activate]")
    }
    let rest = Array(args.dropFirst())
    func number(_ index: Int) throws -> Int {
        guard index < rest.count, let n = Int(rest[index]), (1...9).contains(n) else { throw SpikeError.usage("\(command) needs a desktop number 1...9") }
        return n
    }
    switch command {
    case "spaces": try printSpaces()
    case "switch": try switchToDesktop(try number(0))
    case "tint":
        guard rest.count >= 2 else { throw SpikeError.usage("tint N #RRGGBB") }
        try tint(desktop: try number(0), hex: rest[1])
    case "wallpaper": printWallpapers()
    case "set-wallpaper":
        guard let path = rest.first else { throw SpikeError.usage("set-wallpaper PATH") }
        try setWallpaper(path)
    case "windows": try printWindows(all: rest.contains("--all"))
    case "add-desktop":
        let screen = rest.firstIndex(of: "--screen").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil } ?? 1
        try addDesktop(screenIndex: screen)
    case "throw":
        let grabX = rest.firstIndex(of: "--grab-x").flatMap { rest.indices.contains($0 + 1) ? Double(rest[$0 + 1]) : nil } ?? 0.5
        try throwFocusedWindow(to: try number(0), grabX: min(max(grabX, 0.05), 0.95))
    case "profiles":
        let profiles = chromeProfiles()
        if profiles.isEmpty { print("No Chrome profiles found (Local State missing or unreadable).") }
        for (directory, name) in profiles.sorted(by: { $0.key < $1.key }) { print("  \(directory): \(name)") }
    case "chrome":
        var moveTo: Int?
        if let index = rest.firstIndex(of: "--move-to") {
            guard index + 1 < rest.count, let n = Int(rest[index + 1]), (1...9).contains(n) else { throw SpikeError.usage("--move-to N (1...9)") }
            moveTo = n
        }
        // Positional arguments: everything that is not a flag and not the --move-to value.
        let moveValue = rest.firstIndex(of: "--move-to").map { $0 + 1 }
        let positional = rest.indices.filter { !rest[$0].hasPrefix("--") && $0 != moveValue }.map { rest[$0] }
        guard positional.count >= 2 else { throw SpikeError.usage("chrome 'Profile 1' https://example.com [--bare] [--no-activate] [--move-to N]") }
        try chrome(
            profile: positional[0], url: positional[1], bare: rest.contains("--bare"),
            activates: !rest.contains("--no-activate"), moveTo: moveTo)
    default: throw SpikeError.usage("unknown command \(command)")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
