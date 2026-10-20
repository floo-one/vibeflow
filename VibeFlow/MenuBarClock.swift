import Foundation
import Observation
import VibeFlowCore

/// Ticks on each minute boundary for the clocks label. The continuous clock keeps
/// counting through sleep, so the label catches up right after wake.
@MainActor
@Observable
final class MenuBarClock {
    private(set) var now = Date()

    init() {
        Task { [weak self] in
            while true {
                let wait = ClockFormat.nextMinute(after: Date()).timeIntervalSinceNow
                try? await Task.sleep(for: .seconds(max(wait, 0.05)))
                guard let self else { return }
                now = Date()
            }
        }
    }
}
