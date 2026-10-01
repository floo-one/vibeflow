import Testing
@testable import VibeFlowCore

/// Proves the test pipeline runs (swift test in VibeFlowCore, and the VibeFlow scheme in Xcode).
/// Real suites per docs/designs/vibeflow-v1.md Section 3: CaptureTests, SessionTests,
/// ProvidersTests, SmartReadTests, PresetsTests.
@Suite struct SmokeTests {
    @Test func versionIsSet() {
        #expect(!VibeFlowCoreInfo.version.isEmpty)
    }
}
