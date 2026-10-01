import Foundation
import Testing
@testable import OutflowCore

/// The fakes are the foundation of every later suite, so their own behaviour is pinned here.
@Suite struct FakeClockTests {
    @Test func sleeperResumesOnlyWhenTimeAdvancesPastDeadline() async throws {
        let clock = FakeClock()
        let task = Task { try await clock.sleep(for: .seconds(5)); return true }
        try await waitUntil { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(4))
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.sleeperCount == 1, "4 s is before a 5 s deadline")

        clock.advance(by: .seconds(1))
        #expect(try await task.value == true)
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellationWakesTheSleeperWithCancellationError() async throws {
        let clock = FakeClock()
        let task = Task { try await clock.sleep(for: .seconds(60)) }
        try await waitUntil { clock.sleeperCount == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
    }
}

@Suite struct TimeoutTests {
    @Test func operationThatFinishesInTimeReturnsItsValue() async throws {
        let clock = FakeClock()
        let value = try await withTimeout(.seconds(5), clock: clock) { 42 }
        #expect(value == 42)
    }

    @Test func slowOperationThrowsTimeoutErrorWhenTheClockPasses() async throws {
        let clock = FakeClock()
        let task = Task {
            try await withTimeout(.seconds(5), clock: clock) {
                try await clock.sleep(for: .seconds(30))
                return "late"
            }
        }
        // Both the operation and the timeout are sleeping on the fake clock.
        try await waitUntil { clock.sleeperCount == 2 }
        clock.advance(by: .seconds(5))
        await #expect(throws: TimeoutError.self) { try await task.value }
    }
}

@Suite struct FakePasteboardTests {
    @Test func externalWriteBumpsChangeCountAndReplacesText() {
        let pb = FakePasteboard(text: "before")
        #expect(pb.changeCount == 0)
        pb.externalWrite("after")
        #expect(pb.changeCount == 1)
        #expect(pb.string() == "after")
    }

    @Test func setStringRecordsTransientFlag() {
        let pb = FakePasteboard()
        pb.setString("restored", transient: true)
        #expect(pb.writes.count == 1)
        #expect(pb.writes[0].transient == true)
        #expect(pb.changeCount == 1)
    }
}

@Suite struct FakeSpeechProviderTests {
    @MainActor
    @Test func playbackDeliversScriptedEventsThenFinishes() async throws {
        let provider = FakeSpeechProvider()
        let playback = provider.speak(SpeechRequest(text: "Hello world.", voiceID: "v"))
        let fake = try #require(provider.last)
        fake.emit(.started)
        fake.emit(.progress(characterOffset: 5))
        fake.finish()

        var received: [SpeechEvent] = []
        for try await e in playback.events { received.append(e) }
        #expect(received == [.started, .progress(characterOffset: 5), .finished])
        #expect(provider.requests.first?.text == "Hello world.")
    }

    @MainActor
    @Test func playbackFailureSurfacesAsSpeechFailure() async {
        let provider = FakeSpeechProvider()
        let playback = provider.speak(SpeechRequest(text: "x", voiceID: "v"))
        provider.last?.fail(.connectionLost(lastPlayedOffset: 3))
        await #expect(throws: SpeechFailure.connectionLost(lastPlayedOffset: 3)) {
            for try await _ in playback.events {}
        }
    }
}

@Suite struct FakeSecretsTests {
    @Test func readWriteDeleteRoundTrip() throws {
        let s = FakeSecrets()
        #expect(s.read(.elevenLabs) == nil)
        try s.write("k1", for: .elevenLabs)
        #expect(s.read(.elevenLabs) == "k1")
        try s.delete(.elevenLabs)
        #expect(s.read(.elevenLabs) == nil)
    }
}

// MARK: - Helpers

/// Polls a condition on a real clock so tests can wait for a task to reach a suspension point.
func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition() {
        if ContinuousClock.now - start > timeout { throw TimeoutError(duration: timeout) }
        try await Task.sleep(for: .milliseconds(5))
    }
}
