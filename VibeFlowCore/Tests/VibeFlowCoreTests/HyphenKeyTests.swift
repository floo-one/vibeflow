import Testing
@testable import VibeFlowCore

/// The dictation default follows the key printed "-", whatever the layout.
@Suite("HyphenKey")
struct HyphenKeyTests {
    /// Unmodified output of the keys that matter, per layout.
    static let us: [Int: String] = [0x1B: "-", 0x2C: "/", 0x2F: ".", 0x2B: ",", 0x18: "="]
    static let german: [Int: String] = [0x1B: "ß", 0x2C: "-", 0x2F: ".", 0x2B: ",", 0x18: "´", 0x4E: "-"]

    @Test func usLayoutKeepsAnsiMinus() {
        #expect(HyphenKey.keyCode { Self.us[$0] } == HyphenKey.ansiMinus)
    }

    @Test func germanLayoutPicksTheKeyNextToPeriod() {
        #expect(HyphenKey.keyCode { Self.german[$0] } == HyphenKey.ansiSlash)
    }

    @Test func noHyphenOrNoLayoutFallsBackToAnsiMinus() {
        #expect(HyphenKey.keyCode { _ in nil } == HyphenKey.ansiMinus)
        #expect(HyphenKey.keyCode { $0 == 0x4E ? "-" : "x" } == HyphenKey.ansiMinus, "the keypad minus never counts")
    }

    @Test func layoutWithTwoHyphenKeysPrefersAnsiMinus() {
        #expect(HyphenKey.keyCode { $0 == 0x1B || $0 == 0x00 ? "-" : nil } == HyphenKey.ansiMinus)
    }

    @Test func candidatesAreUniqueCharacterKeys() {
        #expect(Set(HyphenKey.candidates).count == HyphenKey.candidates.count)
        #expect(!HyphenKey.candidates.contains(0x24), "Return")
        #expect(!HyphenKey.candidates.contains(0x4E), "keypad minus")
    }

    @Test func migratesOnlyTheOldDefault() {
        let option = 2048, shiftOption = 2560
        #expect(HyphenKey.shouldMigrate(storedKeyCode: 0x1B, storedModifiers: option, defaultModifiers: option, layoutKeyCode: 0x2C))
        #expect(!HyphenKey.shouldMigrate(storedKeyCode: 0x1B, storedModifiers: option, defaultModifiers: option, layoutKeyCode: 0x1B), "US layout: nothing to move")
        #expect(!HyphenKey.shouldMigrate(storedKeyCode: 0x1B, storedModifiers: shiftOption, defaultModifiers: option, layoutKeyCode: 0x2C), "other modifiers were recorded by the user")
        #expect(!HyphenKey.shouldMigrate(storedKeyCode: 0x0F, storedModifiers: option, defaultModifiers: option, layoutKeyCode: 0x2C), "another key was recorded by the user")
    }
}
