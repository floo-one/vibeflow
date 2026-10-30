/// Which physical key types "-" on the current keyboard layout, for the dictation defaults.
/// Hotkeys bind key codes, not characters: kVK_ANSI_Minus is "-" on a US layout but "ß" on
/// German QWERTZ, where "-" sits on kVK_ANSI_Slash next to "." and ",". The app supplies the
/// translator (Carbon UCKeyTranslate); this stays pure so fake layouts can test it.
public enum HyphenKey {
    /// kVK_ANSI_Minus: the US "-" key, the old default and the fallback.
    public static let ansiMinus = 0x1B
    /// kVK_ANSI_Slash: the "-" key on German and other QWERTZ layouts.
    public static let ansiSlash = 0x2C

    /// Character keys of the main block (kVK_ANSI_A 0x00 to kVK_ANSI_Period 0x2F, plus
    /// kVK_ANSI_Grave), minus first so a layout with two "-" keys keeps the US one. Return
    /// (0x24) is not a character key; the keypad is left out on purpose, since its "-" is
    /// the same on every layout and not where a laptop has it.
    public static let candidates: [Int] = [ansiMinus, ansiSlash]
        + (0x00...0x2F).filter { $0 != 0x24 && $0 != ansiMinus && $0 != ansiSlash } + [0x32]

    /// The first candidate whose unmodified keystroke types "-", or ansiMinus if none does
    /// (a layout without one, or no layout data at all).
    public static func keyCode(translate: (Int) -> String?) -> Int {
        candidates.first { translate($0) == "-" } ?? ansiMinus
    }

    /// True when a stored dictation shortcut is still the old built-in default (ANSI minus
    /// with the default modifiers) and the layout types "-" on another key. Anything else
    /// was recorded by the user and is kept.
    public static func shouldMigrate(storedKeyCode: Int, storedModifiers: Int, defaultModifiers: Int, layoutKeyCode: Int) -> Bool {
        storedKeyCode == ansiMinus && storedModifiers == defaultModifiers && layoutKeyCode != ansiMinus
    }
}
