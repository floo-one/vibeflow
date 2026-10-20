import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import VibeFlowCore

// Real implementations of the VibeFlowCore ports (design: Protocol seams, D2 Live/).

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
struct LivePasteboard: VibeFlowCore.Pasteboard {
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

// MARK: - Dictation cues on NSSound

/// Short system sounds when the microphone opens and closes, like FreeFlow. Loaded once and
/// restarted on each cue so a quick press-release-press still plays every sound.
@MainActor
final class DictationSounds {
    private let started = NSSound(named: "Tink")
    private let stopped = NSSound(named: "Pop")

    init() {
        started?.volume = 0.5
        stopped?.volume = 0.5
    }

    func play(_ cue: DictationCue) {
        let sound = cue == .recordingStarted ? started : stopped
        sound?.stop()
        sound?.play()
    }
}
