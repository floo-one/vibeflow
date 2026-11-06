import Testing
@testable import MaagicalCore

/// Proves the test pipeline runs (swift test in MaagicalCore, and the Maagical scheme in Xcode).
/// Real suites per docs/designs/vibeflow-v1.md Section 3: CaptureTests, SessionTests,
/// ProvidersTests, SmartReadTests, PresetsTests.
@Suite struct SmokeTests {
    @Test func versionIsSet() {
        #expect(!MaagicalCoreInfo.version.isEmpty)
    }
}
