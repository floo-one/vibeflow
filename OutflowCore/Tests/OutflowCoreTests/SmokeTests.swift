import Testing
@testable import OutflowCore

/// Proves the test pipeline runs (swift test in OutflowCore, and the Outflow scheme in Xcode).
/// Real suites per docs/designs/outflow-v1.md Section 3: CaptureTests, SessionTests,
/// ProvidersTests, SmartReadTests, PresetsTests.
@Suite struct SmokeTests {
    @Test func versionIsSet() {
        #expect(!OutflowCoreInfo.version.isEmpty)
    }
}
