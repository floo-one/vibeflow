import AppKit
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
    /// Option and the key right of "." on every layout ("-" on German, "/" on US), so read,
    /// smart read and dictation are the three keys right above Option.
    static let record = Self("record", default: .init(.slash, modifiers: defaultModifiers))
    /// Dictate, toggle: press to start recording hands-free, press again to stop. Default:
    /// Shift-Option and the key right of ".".
    static let recordToggle = Self("recordToggle", default: .init(.slash, modifiers: defaultModifiers.union(.shift)))
    /// Paste the last dictation again. Default: Control-Option-V, which types no character, so
    /// typing can never paste by accident.
    static let pasteLastDictation = Self("pasteLastDictation", default: .init(.v, modifiers: pasteModifiers))
    /// Paste the last smart read result. Default: Shift-Control-Option-V. Not "pasteAnswer": an
    /// old build stored that name on Option-Minus, the push-to-talk key.
    static let pasteLastAnswer = Self("pasteLastAnswer", default: .init(.v, modifiers: pasteModifiers.union(.shift)))
}

/// One-time move of the dictation shortcuts to the key right of "." (DictationKey). Earlier
/// builds defaulted to kVK_ANSI_Minus ("ß" on German QWERTZ), and nightlies after 1.3.0 to the key
/// printed "-" (kVK_ANSI_Minus again on US). KeyboardShortcuts writes a Name's default to
/// UserDefaults the first time the Name is used, so existing installs keep the old default
/// until it is moved. Replaces a stored shortcut only when it is exactly an old default; one
/// the user recorded is never touched. Runs after LegacyMigration, which can copy old
/// bindings in, and before the hotkeys are registered.
@MainActor
enum ShortcutMigration {
    private static let markerKey = "migratedDictationToSlashKey"
    private static let log = Logger(subsystem: "one.floo.vibeflow", category: "migration")

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(true, forKey: markerKey)
        for (name, modifiers) in [(KeyboardShortcuts.Name.record, defaultModifiers), (.recordToggle, defaultModifiers.union(.shift))] {
            let newDefault = KeyboardShortcuts.Shortcut(.slash, modifiers: modifiers)
            guard let stored = KeyboardShortcuts.getShortcut(for: name),
                  DictationKey.shouldMigrate(
                    storedKeyCode: stored.carbonKeyCode,
                    storedModifiers: stored.carbonModifiers,
                    defaultModifiers: newDefault.carbonModifiers
                  )
            else { continue }
            KeyboardShortcuts.setShortcut(newDefault, for: name)
            log.notice("shortcut migration: moved \(name.rawValue, privacy: .public) to key code \(newDefault.carbonKeyCode, privacy: .public)")
        }
    }
}
