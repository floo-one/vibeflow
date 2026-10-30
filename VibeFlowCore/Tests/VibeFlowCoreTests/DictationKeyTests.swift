import Testing
@testable import VibeFlowCore

/// Dictation defaults to the key right of "." on every layout; only old defaults move there.
@Suite("DictationKey")
struct DictationKeyTests {
    let option = 2048, shiftOption = 2560

    @Test func migratesTheOldAnsiMinusDefault() {
        #expect(DictationKey.shouldMigrate(storedKeyCode: DictationKey.ansiMinus, storedModifiers: option, defaultModifiers: option))
        #expect(DictationKey.shouldMigrate(storedKeyCode: DictationKey.ansiMinus, storedModifiers: shiftOption, defaultModifiers: shiftOption))
    }

    @Test func keepsTheNewDefault() {
        #expect(!DictationKey.shouldMigrate(storedKeyCode: DictationKey.ansiSlash, storedModifiers: option, defaultModifiers: option))
    }

    @Test func keepsRecordedShortcuts() {
        #expect(!DictationKey.shouldMigrate(storedKeyCode: DictationKey.ansiMinus, storedModifiers: shiftOption, defaultModifiers: option), "other modifiers were recorded by the user")
        #expect(!DictationKey.shouldMigrate(storedKeyCode: 0x0F, storedModifiers: option, defaultModifiers: option), "another key was recorded by the user")
    }
}
