import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.pwr_mgt
import MaagicalCore

// Real implementations of the MaagicalCore ports (design: Protocol seams, D2 Live/).

// MARK: - AccessibilityBridge on AXUIElement

@MainActor
final class LiveAccessibility: AccessibilityBridge {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    /// kAXSelectedTextAttribute of the system-wide focused element.
    func focusedSelectedText() throws -> String? {
        guard isTrusted else { throw AccessibilityError.notTrusted }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedResult == .success, let focused = focusedRef else { throw AccessibilityError.noFocusedElement }
        let element = focused as! AXUIElement
        var selectedRef: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard selectedResult == .success, let text = selectedRef as? String else { return nil }
        return text
    }

    /// Finds the menu item bound to plain Command-C in the app's menu bar (so it works in any
    /// UI language) and presses it.
    func pressCopyMenuItem(in app: FrontmostApp) throws {
        try pressMenuItem(commandCharacter: "C", in: app)
    }

    /// Same lookup for plain Command-V (dictation paste).
    func pressPasteMenuItem(in app: FrontmostApp) throws {
        try pressMenuItem(commandCharacter: "V", in: app)
    }

    /// Synthesized Cmd-V for apps without a paste menu item.
    func postPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// The system-wide focused element; AXUIElement is a CF type, so equality is CFEqual.
    func focusedElement() -> FocusedElement? {
        guard isTrusted else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return FocusedElement(ref as! AXUIElement)
    }

    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    private func pressMenuItem(commandCharacter: String, in app: FrontmostApp) throws {
        guard isTrusted else { throw AccessibilityError.notTrusted }
        let application = AXUIElementCreateApplication(app.pid)
        guard let menuBar = Self.child(of: application, attribute: kAXMenuBarAttribute) else {
            throw AccessibilityError.copyMenuItemNotFound
        }
        for topLevel in Self.children(of: menuBar) {
            for submenu in Self.children(of: topLevel) {
                for item in Self.children(of: submenu) where Self.isCommand(item, character: commandCharacter) {
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    guard result == .success else { throw AccessibilityError.pressFailed }
                    return
                }
            }
        }
        throw AccessibilityError.copyMenuItemNotFound
    }

    private static func isCommand(_ item: AXUIElement, character: String) -> Bool {
        var charRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charRef) == .success,
              let char = charRef as? String, char.uppercased() == character else { return false }
        var modRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modRef) == .success,
              let modifiers = modRef as? Int else { return false }
        return modifiers == 0 // 0 = Command only
    }

    private static func child(of element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else { return [] }
        return array
    }
}

// MARK: - Pasteboard on NSPasteboard

/// Called from a detached task with a timeout (D10), so not main-actor bound.
struct LivePasteboard: MaagicalCore.Pasteboard {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var changeCount: Int { NSPasteboard.general.changeCount }
    var isEmpty: Bool { NSPasteboard.general.pasteboardItems?.isEmpty ?? true }

    func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func setString(_ text: String, transient: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if transient {
            pb.declareTypes([.string, Self.transientType], owner: nil)
            pb.setString("", forType: Self.transientType)
        }
        pb.setString(text, forType: .string)
    }
}

// MARK: - ClipboardSourcing on NSWorkspace activations

/// Feeds every frontmost-app change and the pasteboard changeCount at that moment to
/// ClipboardSourceTracker, which attributes each clipboard change to the app that was in front.
@MainActor
final class LiveClipboardSource: ClipboardSourcing {
    private var tracker = ClipboardSourceTracker()
    private var observer: (any NSObjectProtocol)?

    init() {
        tracker.appActivated(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                             changeCount: NSPasteboard.general.changeCount)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            let changeCount = NSPasteboard.general.changeCount
            MainActor.assumeIsolated { self?.tracker.appActivated(bundleID, changeCount: changeCount) }
        }
    }

    func clipboardSourceBundleID() -> String? {
        let pb = NSPasteboard.general
        // Maagical's own restores and dictation pastes are marked transient: whatever app was in
        // front then did not write that text. Other apps' transient writes are unknown too.
        if pb.types?.contains(LivePasteboard.transientType) == true { return nil }
        return tracker.source(changeCount: pb.changeCount)
    }
}

// MARK: - Dictation cues on NSSound

/// Short system sounds when the microphone opens and closes, like FreeFlow, and a lower one
/// when a dictation is cancelled, so a cancel never sounds like a finished dictation. Loaded
/// once and restarted on each cue so a quick press-release-press still plays every sound.
@MainActor
final class DictationSounds {
    private let started = NSSound(named: "Tink")
    private let stopped = NSSound(named: "Pop")
    private let cancelled = NSSound(named: "Bottle")

    init() {
        started?.volume = 0.5
        stopped?.volume = 0.5
        cancelled?.volume = 0.5
    }

    func play(_ cue: DictationCue) {
        let sound = switch cue {
        case .recordingStarted: started
        case .recordingStopped: stopped
        case .cancelled: cancelled
        }
        sound?.stop()
        sound?.play()
    }
}

// MARK: - PowerAssertion on IOPMAssertion

/// The same assertion `caffeinate -d` (display on) or `caffeinate -i` (display may sleep) holds.
/// macOS drops it if the app quits or crashes, so nothing outlives Maagical.
@MainActor
final class LivePowerAssertion: PowerAssertion {
    private var id: IOPMAssertionID?
    /// What `pmset -g assertions` shows.
    private let name: String

    init(name: String = "Maagical Keep Awake") {
        self.name = name
    }

    func begin(keepsDisplayOn: Bool) -> Bool {
        end()
        let type = keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString, &newID)
        guard result == kIOReturnSuccess else { return false }
        id = newID
        return true
    }

    func end() {
        guard let id else { return }
        IOPMAssertionRelease(id)
        self.id = nil
    }
}
