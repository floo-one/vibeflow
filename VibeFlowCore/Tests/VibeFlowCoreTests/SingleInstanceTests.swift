import Foundation
import Testing
@testable import VibeFlowCore

/// One running copy per app (docs/designs/dev-prod-channels.md, P2).
@Suite("SingleInstance")
struct SingleInstanceTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func quitsEveryOlderCopyButNotItself() {
        let me = SingleInstance.Copy(pid: 30, launchDate: start)
        let running = [
            SingleInstance.Copy(pid: 10, launchDate: start.addingTimeInterval(-3600)),
            SingleInstance.Copy(pid: 20, launchDate: start.addingTimeInterval(-5)),
            me,
        ]
        #expect(SingleInstance.olderCopies(of: me, among: running) == [10, 20])
    }

    @Test func aNewerCopyStays() {
        let me = SingleInstance.Copy(pid: 10, launchDate: start)
        let newer = SingleInstance.Copy(pid: 11, launchDate: start.addingTimeInterval(0.2))
        #expect(SingleInstance.olderCopies(of: me, among: [me, newer]).isEmpty,
                "two copies starting together must not quit each other")
    }

    @Test func missingLaunchDatesCountAsOlderOthersAndNewestSelf() {
        let fromXcode = SingleInstance.Copy(pid: 40, launchDate: nil)
        let installed = SingleInstance.Copy(pid: 12, launchDate: start)
        let earlierDebugRun = SingleInstance.Copy(pid: 13, launchDate: nil)
        #expect(SingleInstance.olderCopies(of: fromXcode, among: [installed, earlierDebugRun, fromXcode]) == [12, 13])
        #expect(SingleInstance.olderCopies(of: installed, among: [installed, earlierDebugRun]) == [13])
    }

    @Test func aloneQuitsNothing() {
        let me = SingleInstance.Copy(pid: 1, launchDate: start)
        #expect(SingleInstance.olderCopies(of: me, among: [me]).isEmpty)
    }
}
