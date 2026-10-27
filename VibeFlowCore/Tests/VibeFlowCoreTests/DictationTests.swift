import Foundation
import Testing
@testable import VibeFlowCore

/// A DictationSession wired to fakes: Safari frontmost with a focused field, mic granted,
/// Groq primary with Apple fallback, cleanup on, one second of speech per recording.
@MainActor
final class DictationHarness {
    let accessibility = FakeAccessibility()
    let pasteboard = FakePasteboard(text: "my clipboard")
    let recorder = FakeAudioRecorder()
    let presets = FakePresets()
    let clock = FakeClock()
    let groq = FakeTranscriber()
    let apple = FakeTranscriber()
    let cleaner = FakeCleaner()
    var setup: DictationSetup
    private(set) var readStops = 0
    private(set) var recordingWhenReadStopped: Bool?
    private(set) var cues: [DictationCue] = []
    private(set) var session: DictationSession!

    init() {
        groq.clock = clock
        apple.clock = clock
        cleaner.clock = clock
        accessibility.pasteboard = pasteboard
        apple.result = .success(Transcription(text: "hello from apple"))
        setup = DictationSetup(
            transcriber: FallbackTranscriber(primary: groq, fallback: apple, primaryName: "Groq"),
            onDevice: apple,
            cleaner: cleaner,
            microphoneUID: "built-in"
        )
        session = DictationSession(
            recorder: recorder,
            accessibility: accessibility,
            presets: presets,
            pasteboard: pasteboard,
            clock: clock,
            setup: { [unowned self] in self.setup },
            stopReading: { [unowned self] in
                self.readStops += 1
                self.recordingWhenReadStopped = self.recorder.isRecording
            },
            cue: { [unowned self] in self.cues.append($0) }
        )
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<20 { await Task.yield() }
    }

    /// Push-to-talk: key down, a moment of talking, key up.
    func hold() async {
        session.recordKeyDown()
        await settle()
        session.recordKeyUp()
    }

    /// Advances time until the session is idle again (transcriber delays, the 750 ms restore).
    func finish() async {
        var steps = 0
        while session.state != .idle && steps < 300 {
            await settle()
            clock.advance(by: .milliseconds(50))
            steps += 1
        }
        await settle()
    }
}

@Suite("DictationSession: push-to-talk, toggle and cap") @MainActor
struct DictationFlowTests {
    @Test func holdRecordsTranscribesCleansAndPastes() async {
        let h = DictationHarness()
        h.presets.defaultPreset.languageOverride = "de-DE"
        await h.hold()
        #expect(h.session.state == .transcribing)
        await h.finish()

        #expect(h.recorder.startedDevices == ["built-in"])
        #expect(h.groq.lastLanguage == "de-DE")
        #expect(h.cleaner.calls == 1)
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(h.pasteboard.writes.first?.text == "Hello world. ", "space after the final dot")
        #expect(h.pasteboard.string() == "my clipboard", "clipboard restored")
        #expect(h.session.status == "Pasted")
        #expect(h.session.lastError == nil)
    }

    @Test func releasingThePushToTalkKeyTranscribesAtOnce() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        #expect(h.session.state == .recording(handsFree: false))
        h.session.recordKeyUp()
        #expect(h.session.state == .transcribing, "no hold threshold: release always stops")
        #expect(!h.recorder.isRecording)
        await h.finish()
        #expect(h.session.status == "Pasted")
    }

    @Test func toggleStartsHandsFreeAndTheNextPressStops() async {
        let h = DictationHarness()
        h.session.toggleRecording()
        #expect(h.session.state == .recording(handsFree: true))
        #expect(h.session.status == "Listening. Press the toggle shortcut again to stop")
        #expect(h.readStops == 1)

        h.clock.advance(by: .seconds(30))
        await h.settle()
        #expect(h.session.state == .recording(handsFree: true), "still listening")

        h.session.toggleRecording()
        #expect(h.session.state == .transcribing)
        await h.finish()
        #expect(h.session.status == "Pasted")
        #expect(h.recorder.startedDevices.count == 1)
    }

    @Test func pushToTalkKeyAlsoStopsAToggleRecording() async {
        let h = DictationHarness()
        h.session.toggleRecording()
        h.session.recordKeyDown()
        #expect(h.session.state == .transcribing)
        h.session.recordKeyUp() // that press's release changes nothing
        await h.finish()
        #expect(h.session.status == "Pasted")
    }

    @Test func toggleWhileHoldingPushToTalkIsIgnored() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.session.toggleRecording()
        #expect(h.session.state == .recording(handsFree: false))
        h.session.recordKeyUp()
        await h.finish()
        #expect(h.recorder.startedDevices.count == 1)
    }

    @Test func twoMinuteCapStopsAndTranscribes() async {
        let h = DictationHarness()
        h.session.toggleRecording()
        await h.settle()
        h.clock.advance(by: DictationSession.maximumDuration)
        await h.settle()
        #expect(h.session.state != .recording(handsFree: true))
        await h.finish()
        #expect(h.groq.callCount == 1)
        #expect(h.session.status == "Stopped at the 2-minute limit")
        #expect(h.accessibility.pastePresses.count == 1)
    }

    @Test func recordingsUnderThreeTenthsOfASecondAreDiscarded() async {
        let h = DictationHarness()
        h.recorder.nextAudio = RecordedAudio(pcm16: Data(repeating: 0x40, count: 6_400)) // 0.2 s
        await h.hold()
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Too short, nothing recorded")
        #expect(h.groq.callCount == 0)
        #expect(h.session.lastFailure == nil)
    }

    @Test func digitalSilenceIsAMicrophoneProblemNotSilence() async {
        let h = DictationHarness()
        h.recorder.nextAudio = RecordedAudio(pcm16: Data(count: 32_000)) // 1 s of zeros
        await h.hold()
        #expect(h.groq.callCount == 0)
        #expect(h.session.lastError == DictationError(message: "The microphone recorded no sound. Choose a microphone in Settings > Dictation", actions: [.openDictationSettings]))
    }

    @Test func keyDownWhileBusyIsIgnoredNotQueued() async {
        let h = DictationHarness()
        h.groq.delay = .seconds(1)
        await h.hold()
        await h.settle()
        #expect(h.session.state == .transcribing)
        h.session.recordKeyDown()
        h.session.recordKeyUp()
        #expect(h.session.state == .transcribing)
        await h.finish()
        #expect(h.recorder.startedDevices.count == 1)
        #expect(h.groq.callCount == 1)
    }

    @Test func recordStopsAnyReadBeforeTheMicrophoneOpens() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        #expect(h.readStops == 1)
        #expect(h.recordingWhenReadStopped == false)
        #expect(h.recorder.isRecording)
    }

    @Test func silenceSaysDidntCatchThatAndPastesNothing() async {
        let h = DictationHarness()
        h.groq.result = .success(Transcription(text: "  ", noSpeechProbabilities: [0.9]))
        await h.hold()
        await h.finish()
        #expect(h.session.status == "Didn't catch that")
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.cleaner.calls == 0)
        #expect(h.session.lastError == nil)
    }

    @Test func fallbackAndCleanupNotesShowInTheStatus() async {
        let h = DictationHarness()
        h.groq.result = .failure(.offline)
        h.cleaner.result = .failure(.rateLimited)
        await h.hold()
        await h.finish()
        #expect(h.apple.callCount == 1)
        #expect(h.pasteboard.writes.first?.text == "hello from apple")
        #expect(h.session.status == "Transcribed on device: Groq unavailable (offline). Pasted without cleanup (rate limited)")
    }

    @Test func setupNoticeIsShown() async {
        let h = DictationHarness()
        h.setup.notice = "Transcribed on device: no Groq key"
        await h.hold()
        await h.finish()
        #expect(h.session.status == "Transcribed on device: no Groq key")
    }
}

@Suite("DictationSession: start and stop sounds") @MainActor
struct DictationCueTests {
    @Test func pushToTalkCuesOnKeyDownAndKeyUp() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        #expect(h.cues == [.recordingStarted])
        h.session.recordKeyUp()
        #expect(h.cues == [.recordingStarted, .recordingStopped])
        await h.finish()
        #expect(h.cues == [.recordingStarted, .recordingStopped], "nothing after the mic closes")
    }

    @Test func toggleAndTheCapBothCueTheStop() async {
        let h = DictationHarness()
        h.session.toggleRecording()
        h.session.toggleRecording()
        #expect(h.cues == [.recordingStarted, .recordingStopped])
        await h.finish()

        h.session.toggleRecording()
        await h.settle()
        h.clock.advance(by: DictationSession.maximumDuration)
        await h.settle()
        #expect(h.cues == [.recordingStarted, .recordingStopped, .recordingStarted, .recordingStopped])
    }

    @Test func tooShortStillCuesTheStop() {
        let h = DictationHarness()
        h.recorder.nextAudio = RecordedAudio(pcm16: Data(repeating: 0x40, count: 3_200)) // 0.1 s
        h.session.recordKeyDown()
        h.session.recordKeyUp()
        #expect(h.cues == [.recordingStarted, .recordingStopped])
    }

    @Test func cancelAndFailedStartsAreSilent() {
        let h = DictationHarness()
        h.session.recordKeyDown()
        #expect(h.session.cancel())
        #expect(h.cues == [.recordingStarted], "a read follows a cancel, so no stop sound")

        h.recorder.startError = .noInputDevice
        h.session.recordKeyDown()
        h.recorder.startError = nil
        h.recorder.permission = .denied
        h.session.toggleRecording()
        #expect(h.cues == [.recordingStarted])
    }
}

@Suite("DictationSession: cancel (read shortcut)") @MainActor
struct DictationCancelTests {
    @Test func cancelWhileRecordingDropsTheAudio() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        #expect(h.session.cancel())
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Dictation cancelled")
        #expect(h.recorder.cancelCount == 1)
        #expect(!h.recorder.isRecording)
        h.session.recordKeyUp()
        await h.finish()
        #expect(h.groq.callCount == 0)
        #expect(h.session.lastFailure == nil)
    }

    @Test func cancelWhileTranscribingDropsTheLateResult() async {
        let h = DictationHarness()
        h.groq.delay = .seconds(1)
        await h.hold()
        await h.settle()
        #expect(h.session.cancel())
        h.clock.advance(by: .seconds(2))
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.cleaner.calls == 0)
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func cancelWhileCleaningPastesNothing() async {
        let h = DictationHarness()
        h.cleaner.delay = .seconds(1)
        await h.hold()
        await h.settle()
        #expect(h.session.state == .cleaning)
        #expect(h.session.cancel())
        h.clock.advance(by: .seconds(2))
        await h.settle()
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.accessibility.pastePresses.isEmpty)
    }

    @Test func cancelWhenIdleReportsNothingCancelled() {
        let h = DictationHarness()
        #expect(!h.session.cancel())
        #expect(h.session.status == "Ready")
    }
}

@Suite("DictationSession: local-only apps (D5)") @MainActor
struct DictationLocalOnlyTests {
    @Test func localOnlyAppUsesOnDeviceAndSkipsCloudCleanup() async {
        let h = DictationHarness()
        h.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", dictationLocalOnly: true)
        h.setup.notice = "Transcribed on device: no Groq key"
        await h.hold()
        await h.finish()
        #expect(h.groq.callCount == 0)
        #expect(h.apple.callCount == 1)
        #expect(h.cleaner.calls == 0)
        #expect(h.pasteboard.writes.first?.text == "hello from apple")
        #expect(h.session.status == "Pasted", "the cloud notice does not apply")
    }

    @Test func localOnlyAppDoesNotFallBackToTheCloudWhenOnDeviceFails() async {
        let h = DictationHarness()
        h.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", dictationLocalOnly: true)
        h.apple.result = .failure(.assetsMissing(language: "de_DE"))
        await h.hold()
        await h.finish()
        #expect(h.groq.callCount == 0)
        #expect(h.session.lastError?.message == "Download the on-device model for de_DE in Settings > Dictation")
        #expect(h.session.lastFailure != nil)
    }

    @Test func localOnlyWithoutOnDeviceSupportFailsAndKeepsTheRecording() async {
        let h = DictationHarness()
        h.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", dictationLocalOnly: true)
        h.setup.onDevice = nil
        await h.hold()
        await h.finish()
        #expect(h.groq.callCount == 0)
        #expect(h.session.lastError?.message == "This app dictates on this Mac only, which needs macOS 26")
        #expect(h.session.lastFailure?.audio == h.recorder.nextAudio)
    }

    @Test func oldPresetsDecodeAsNotLocalOnly() throws {
        let old = #"{"provider":"apple","elevenLabsVoiceID":"x","appleVoiceByLanguage":{},"speed":1.1,"smartReadEnabled":false,"smartReadMode":"brief","bundleID":"com.apple.Notes"}"#
        let preset = try JSONDecoder().decode(AppPreset.self, from: Data(old.utf8))
        #expect(preset.dictationLocalOnly == false)
        #expect(preset.speed == 1.1)
        let roundTrip = try JSONDecoder().decode(AppPreset.self, from: JSONEncoder().encode(AppPreset(bundleID: "a", dictationLocalOnly: true)))
        #expect(roundTrip.dictationLocalOnly)
    }
}

@Suite("DictationSession: failed dictations (D13)") @MainActor
struct DictationRecoveryTests {
    @Test func rejectedKeyKeepsTheRecordingAndRetryWorksAfterTheFix() async {
        let h = DictationHarness()
        h.groq.result = .failure(.unauthorized)
        await h.hold()
        await h.finish()
        #expect(h.apple.callCount == 0, "a bad key never silently uses Apple")
        #expect(h.session.lastError == DictationError(message: "Groq key rejected or missing", actions: [.openKeys, .retry, .discard]))
        #expect(h.session.lastFailure?.audio == h.recorder.nextAudio)
        #expect(h.session.lastFailure?.text == nil)

        h.groq.result = .success(Transcription(text: "hello world", noSpeechProbabilities: [0.01]))
        h.session.retry()
        #expect(h.session.lastError == nil)
        await h.finish()
        #expect(h.groq.callCount == 2)
        #expect(h.session.status == "Pasted")
        #expect(h.session.lastFailure == nil)
        #expect(h.recorder.startedDevices.count == 1, "retry does not record again")
    }

    @Test func retryUsesTheCurrentSettings() async {
        let h = DictationHarness()
        h.groq.result = .failure(.rejected(status: 404, message: "model not found"))
        await h.hold()
        await h.finish()
        #expect(h.session.lastError?.message == "Groq error 404: model not found")

        let other = FakeTranscriber()
        other.result = .success(Transcription(text: "fixed endpoint"))
        h.setup = DictationSetup(transcriber: FallbackTranscriber(primary: other, fallback: nil, primaryName: "Custom"))
        h.session.retry()
        await h.finish()
        #expect(other.callCount == 1)
        #expect(h.pasteboard.writes.first?.text == "fixed endpoint")
    }

    @Test func focusChangeWhileDictatingPastesWhereTheCursorIsNow() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        // The user switches to another app and clicks into a field while talking.
        let notes = FrontmostApp(pid: 200, bundleID: "com.apple.Notes")
        h.accessibility.frontmost = notes
        h.accessibility.focused = FocusedElement("notes-body")
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()

        #expect(h.accessibility.pastePresses == [notes])
        #expect(h.session.lastError == nil)
        #expect(h.session.status == "Pasted")
        // The preset still comes from the app that had focus at key down.
        #expect(h.presets.lookups == ["com.apple.Safari"])
    }

    @Test func pasteFailureKeepsTheTextForCopy() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true // the user clicked into a password field
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()

        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.session.lastError == DictationError(message: "Copied instead of pasted: a password field has focus", actions: [.copyText, .discard]))
        #expect(h.session.lastFailure?.text == "Hello world.")

        h.pasteboard.externalWrite("something else")
        await h.session.copyText()
        #expect(h.pasteboard.string() == "Hello world.")
        #expect(h.session.status == "Copied to clipboard")
    }

    @Test func noFrontmostAppCopiesTheText() async {
        let h = DictationHarness()
        h.accessibility.frontmost = nil
        await h.hold()
        await h.finish()
        #expect(h.session.lastError?.message == "Copied instead of pasted: no app had focus")
        #expect(h.pasteboard.string() == "Hello world.")
    }

    @Test func discardForgetsTheFailure() async {
        let h = DictationHarness()
        h.groq.result = .failure(.timeout)
        h.setup = DictationSetup(transcriber: FallbackTranscriber(primary: h.groq, fallback: nil, primaryName: "Groq"))
        await h.hold()
        await h.finish()
        #expect(h.session.lastFailure != nil)
        h.session.discard()
        #expect(h.session.lastFailure == nil)
        #expect(h.session.lastError == nil)
        h.session.retry()
        #expect(h.session.state == .idle, "nothing left to retry")
    }

    @Test func theNextDictationReplacesTheFailure() async {
        let h = DictationHarness()
        h.groq.result = .failure(.serverError(503))
        h.setup = DictationSetup(transcriber: FallbackTranscriber(primary: h.groq, fallback: nil, primaryName: "Groq"))
        await h.hold()
        await h.finish()
        #expect(h.session.lastError?.message == "Groq unavailable (HTTP 503)")
        h.session.recordKeyDown()
        #expect(h.session.lastFailure == nil)
        #expect(h.session.lastError == nil)
    }
}

@Suite("DictationSession: microphone") @MainActor
struct DictationMicrophoneTests {
    @Test func firstPressAsksForAccessAndDoesNotRecord() async {
        let h = DictationHarness()
        h.recorder.permission = .undetermined
        h.session.recordKeyDown()
        await h.settle()
        #expect(h.recorder.permissionRequests == 1)
        #expect(h.recorder.startedDevices.isEmpty)
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Microphone ready. Press the record shortcut to dictate")
        h.session.recordKeyUp()

        h.session.recordKeyDown()
        #expect(h.recorder.isRecording)
    }

    @Test func deniedAccessPointsToSystemSettings() async {
        let h = DictationHarness()
        h.recorder.permission = .undetermined
        h.recorder.grantOnRequest = false
        h.session.recordKeyDown()
        await h.settle()
        #expect(h.session.lastError?.actions == [.openMicrophoneSettings])

        h.session.recordKeyDown()
        #expect(h.recorder.permissionRequests == 1, "denied is not asked again")
        #expect(h.session.lastError?.actions == [.openMicrophoneSettings])
    }

    @Test func missingInputDeviceFails() {
        let h = DictationHarness()
        h.recorder.startError = .noInputDevice
        h.session.recordKeyDown()
        #expect(h.session.state == .idle)
        #expect(h.session.lastError == DictationError(message: "No microphone found", actions: [.openDictationSettings]))
    }
}

@Suite("DictationSession: paste again") @MainActor
struct DictationPasteAgainTests {
    @Test func aPastedDictationIsKeptAndPastesAgain() async {
        let h = DictationHarness()
        #expect(h.session.lastText == nil)
        await h.hold()
        await h.finish()
        #expect(h.session.lastText == "Hello world.", "the space after the dot is added at paste time")

        let paste = Task { await h.session.pasteAgain("Hello world.") }
        await h.finish()
        while h.accessibility.pastePresses.count < 2 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        h.clock.advance(by: .seconds(1))
        await paste.value
        #expect(h.accessibility.pastePresses.count == 2)
        #expect(h.pasteboard.writes.filter { $0.text == "Hello world. " }.count == 2)
        #expect(h.session.status == "Pasted")
        #expect(h.pasteboard.string() == "my clipboard", "clipboard restored")
    }

    @Test func pasteAgainIsIgnoredWhileRecording() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        await h.settle()
        await h.session.pasteAgain("old text")
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.session.state == .recording(handsFree: false))
    }
}
