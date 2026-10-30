import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import OSLog
import VibeFlowCore

/// VibeFlow Dev (the Debug build) adds Control to every default, and Command to the paste
/// shortcuts that already use Control, so it can run next to the installed release without
/// both apps grabbing the same keys.
#if DEBUG
private let defaultModifiers: NSEvent.ModifierFlags = [.option, .control]
private let pasteModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
#else
private let defaultModifiers: NSEvent.ModifierFlags = [.option]
private let pasteModifiers: NSEvent.ModifierFlags = [.control, .option]
#endif

/// The key that types "-" on the keyboard layout active at launch (US: kVK_ANSI_Minus,
/// German: kVK_ANSI_Slash), so dictation sits next to "." and "," everywhere. Read once, on
/// the main thread: the Names below are first used in AppContainer.init, and Text Input
/// Sources may assert off the main thread.
private let hyphenKey = KeyboardShortcuts.Key(rawValue: HyphenKey.keyCode(translate: KeyboardLayout.current()))

extension KeyboardShortcuts.Name {
    /// Read the selection. Default: Option-Period.
    static let read = Self("read", default: .init(.period, modifiers: defaultModifiers))
    /// Smart read the selection. Default: Option-Comma.
    static let smartRead = Self("smartRead", default: .init(.comma, modifiers: defaultModifiers))
    /// Speak the clipboard. Default: Shift-Option-Period.
    static let readClipboard = Self("readClipboard", default: .init(.period, modifiers: defaultModifiers.union(.shift)))
    /// Smart read the clipboard. Default: Shift-Option-Comma.
    static let smartReadClipboard = Self("smartReadClipboard", default: .init(.comma, modifiers: defaultModifiers.union(.shift)))
    /// Dictate, push-to-talk: hold to record, release to transcribe and paste. Default:
    /// Option and the key printed "-" on the current layout (hyphenKey).
    static let record = Self("record", default: .init(hyphenKey, modifiers: defaultModifiers))
    /// Dictate, toggle: press to start recording hands-free, press again to stop. Default:
    /// Shift-Option and the key printed "-".
    static let recordToggle = Self("recordToggle", default: .init(hyphenKey, modifiers: defaultModifiers.union(.shift)))
    /// Paste the last dictation again. Default: Control-Option-V, which types no character, so
    /// typing can never paste by accident.
    static let pasteLastDictation = Self("pasteLastDictation", default: .init(.v, modifiers: pasteModifiers))
    /// Paste the last smart read result. Default: Shift-Control-Option-V. Not "pasteAnswer": an
    /// old build stored that name on Option-Minus, the push-to-talk key.
    static let pasteLastAnswer = Self("pasteLastAnswer", default: .init(.v, modifiers: pasteModifiers.union(.shift)))
}

/// Translates key codes with the current keyboard layout's Unicode table (Carbon).
enum KeyboardLayout {
    /// A translator for HyphenKey: the character a key types with no modifiers, or nil.
    /// Input methods without a key table (some CJK ones) fall back to the ASCII-capable
    /// layout they type Latin with; with no table at all every key answers nil.
    static func current() -> (Int) -> String? {
        guard let data = layoutData(TISCopyCurrentKeyboardLayoutInputSource())
                ?? layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource())
        else { return { _ in nil } }
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            data.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, keyboardType,
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }

    private static func layoutData(_ source: Unmanaged<TISInputSource>?) -> Data? {
        guard let source = source?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}

/// One-time move of the dictation shortcuts off kVK_ANSI_Minus. Earlier builds bound
/// them to that key code, which is "ß" on German QWERTZ, and KeyboardShortcuts writes a
/// Name's default to UserDefaults the first time the Name is used, so existing installs kept
/// it even after the default learned the layout. Replaces a stored shortcut only when it is
/// exactly the old default; one the user recorded is never touched. Runs after
/// LegacyMigration, which can copy old bindings in, and before the hotkeys are registered.
@MainActor
enum ShortcutMigration {
    private static let markerKey = "migratedDictationToHyphenKey"
    private static let log = Logger(subsystem: "one.floo.vibeflow", category: "migration")

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(true, forKey: markerKey)
        for (name, modifiers) in [(KeyboardShortcuts.Name.record, defaultModifiers), (.recordToggle, defaultModifiers.union(.shift))] {
            let oldDefault = KeyboardShortcuts.Shortcut(.minus, modifiers: modifiers)
            guard let stored = KeyboardShortcuts.getShortcut(for: name),
                  HyphenKey.shouldMigrate(
                    storedKeyCode: stored.carbonKeyCode,
                    storedModifiers: stored.carbonModifiers,
                    defaultModifiers: oldDefault.carbonModifiers,
                    layoutKeyCode: hyphenKey.rawValue
                  )
            else { continue }
            KeyboardShortcuts.setShortcut(.init(hyphenKey, modifiers: modifiers), for: name)
            log.notice("shortcut migration: moved \(name.rawValue, privacy: .public) to key code \(hyphenKey.rawValue, privacy: .public)")
        }
    }
}
