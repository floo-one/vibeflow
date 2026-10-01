import Foundation

public struct TimeoutError: Error, Equatable, Sendable {
    public let duration: Duration
}

/// Runs `operation` and throws `TimeoutError` if it has not finished within `duration`
/// as measured by `clock`. The losing side is cancelled. Every timeout in VibeFlowCore
/// (first chunk 5 s, transform 20 s, pasteboard 200 ms, confirm windows) goes through here
/// so tests can drive it with a fake clock.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    clock: any SessionClock,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: duration)
            throw TimeoutError(duration: duration)
        }
        // First to finish wins; the other is cancelled by the group.
        guard let result = try await group.next() else { throw TimeoutError(duration: duration) }
        group.cancelAll()
        return result
    }
}
