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
    /// What the session sees as "a read is copying the selection right now".
    var readCapturing = false
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
            readIsCapturing: { [unowned self] in self.readCapturing },
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
        for _ in 0..<100 where h.accessibility.pastePresses.count < 2 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        h.clock.advance(by: .seconds(1))
        await paste.value
        #expect(h.accessibility.pastePresses.count == 2)
        #expect(h.pasteboard.writes.filter { $0.text == "Hello world. " }.count == 2)
        #expect(h.session.status == "Pasted")
        #expect(h.pasteboard.string() == "my clipboard", "clipboard restored")
    }

    @Test func aSecondPasteWhileTheFirstRunsIsIgnored() async {
        let h = DictationHarness()
        let first = Task { await h.session.pasteAgain("first") }
        await h.settle()
        let second = Task { await h.session.pasteAgain("second") }
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await first.value
        await second.value
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(!h.pasteboard.writes.contains { $0.text == "second" })
        #expect(h.pasteboard.string() == "my clipboard", "clipboard restored")
    }

    // Generated by /ship coverage audit.
    // Value: protects=paste again pressed while a dictation is pasting is ignored: one Cmd-V, the old text is never
    // written, the user's clipboard comes back; fails_when=pasteAgain's idle guard is dropped or lets .pasting through;
    // why_new=only paste-again-during-paste-again and recording were covered; seam=none;
    // no_claim=real NSPasteboard and Cmd-V timing (FakePasteboard, FakeAccessibility, FakeClock; unit only)
    @Test func pasteAgainWhileADictationPastesIsIgnored() async {
        let h = DictationHarness()
        await h.hold()
        for _ in 0..<300 where h.session.state != .pasting { await h.settle(); h.clock.advance(by: .milliseconds(10)) }
        #expect(h.session.state == .pasting)
        let paste = Task { await h.session.pasteAgain("old text") }
        await h.finish()
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(!h.pasteboard.writes.contains { $0.text.hasPrefix("old text") })
        #expect(h.pasteboard.string() == "my clipboard", "clipboard restored")
        #expect(h.session.status == "Pasted")
        #expect(h.session.lastText == "Hello world.")
    }

    @Test func pasteAgainIsIgnoredWhileRecording() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        await h.settle()
        await h.session.pasteAgain("old text")
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.session.state == .recording(handsFree: false))
    }

    // Generated by /ship coverage audit.
    // Value: protects=paste again with no app in focus pastes nothing, leaves the user's clipboard alone and says so;
    // fails_when=the no-focus branch writes the text to the clipboard, pastes anyway or reports "Pasted";
    // why_new=the other paste-again tests always have Safari and a field in focus; seam=none;
    // no_claim=real NSPasteboard and AX focus (FakeAccessibility, FakePasteboard; unit only)
    @Test func withNoAppInFocusNothingIsPastedAndTheClipboardIsUntouched() async {
        let h = DictationHarness()
        h.accessibility.frontmost = nil
        await h.session.pasteAgain("Hello again")
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.accessibility.pasteKeystrokes == 0)
        #expect(h.pasteboard.writes.isEmpty, "the text is still kept, so the clipboard is not used")
        #expect(h.pasteboard.string() == "my clipboard")
        #expect(h.session.status == "Not pasted: no app had focus")
        #expect(h.session.state == .idle)
    }

    // Generated by /ship coverage audit.
    // Value: protects=paste again into a password field pastes nothing and leaves the user's clipboard alone;
    // fails_when=the refusal writes the text to the clipboard, is reported as pasted, or loses its reason;
    // why_new=no paste-again test reaches the target refusal branch; seam=none;
    // no_claim=real secure input detection (FakeAccessibility.isSecureInputActive; unit only)
    @Test func aPasswordFieldGetsNothingAndTheClipboardIsUntouched() async {
        let h = DictationHarness()
        h.accessibility.isSecureInputActive = true
        await h.session.pasteAgain("Hello again")
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.pasteboard.string() == "my clipboard")
        #expect(h.session.status == "Not pasted: a password field has focus")
    }

    // Generated by /ship coverage audit.
    // Value: protects=a dictation copied instead of pasted is still offered for paste again, and a later
    // paste again clears the old error; fails_when=lastText is set only on .pasted, or pasteAgain stops
    // clearing lastError; why_new=lastText is only asserted after a clean paste; seam=none;
    // no_claim=menu enablement in MenuBarView (app target, untested; unit only)
    @Test func aDictationCopiedInsteadCanBePastedAgainOnceTheFieldIsFixed() async throws {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()
        #expect(h.session.lastError?.message == "Copied instead of pasted: a password field has focus")
        let text = try #require(h.session.lastText)
        #expect(text == "Hello world.")

        h.accessibility.isSecureInputActive = false
        let paste = Task { await h.session.pasteAgain(text) }
        for _ in 0..<100 where h.accessibility.pastePresses.isEmpty { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        h.clock.advance(by: .seconds(1))
        await paste.value
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(h.session.lastError == nil, "the stale error leaves the menu")
        #expect(h.session.status == "Pasted")
    }

    // Generated by /ship coverage audit.
    // Value: protects=lastText is replaced only by a dictation that reached pasting; silence and cancel keep
    // the earlier text; fails_when=start() or an early exit resets lastText alongside lastFailure;
    // why_new=no test runs a second dictation after one was kept; seam=none;
    // no_claim=none beyond protects (fake transcriber and recorder; unit only)
    @Test func aDictationThatPastesNothingKeepsTheEarlierText() async {
        let h = DictationHarness()
        await h.hold()
        await h.finish()
        #expect(h.session.lastText == "Hello world.")

        h.groq.result = .success(Transcription(text: "  ", noSpeechProbabilities: [0.9]))
        await h.hold()
        await h.finish()
        #expect(h.session.status == "Didn't catch that")
        h.session.recordKeyDown()
        #expect(h.session.cancel())
        #expect(h.session.lastText == "Hello world.")
    }

    // Regression (/ship review: QA ISSUE-001).
    // Value: protects=a dictation cannot start while paste again owns the clipboard, so the user's clipboard survives;
    // fails_when=pasteAgain leaves the session idle during its restore window;
    // why_new=only paste-vs-paste was covered; seam=none;
    // no_claim=live NSPasteboard timing (FakeClock, FakePasteboard; unit only)
    @Test func aDictationStartedDuringPasteAgainIsIgnoredAndTheClipboardSurvives() async {
        let h = DictationHarness()
        let paste = Task { await h.session.pasteAgain("again") }
        await h.settle()
        #expect(h.session.state == .pasting)
        h.session.toggleRecording()
        h.session.recordKeyDown()
        #expect(h.recorder.startedDevices.isEmpty, "no dictation starts while paste again owns the clipboard")
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Pasted")
        #expect(h.pasteboard.string() == "my clipboard")
    }

    // Regression (/ship review: state-machines wrong row, retry).
    // Value: protects=Retry cannot re-transcribe and paste while paste again owns the clipboard;
    // fails_when=retry's idle guard passes during paste again;
    // why_new=retry was never combined with paste again; seam=none;
    // no_claim=none beyond protects (fake transcriber and clock; unit only)
    @Test func retryDuringPasteAgainIsIgnored() async {
        let h = DictationHarness()
        h.groq.result = .failure(.unauthorized)
        h.apple.result = .failure(.unauthorized)
        await h.hold()
        await h.finish()
        #expect(h.session.lastFailure != nil)
        let calls = h.groq.callCount
        let paste = Task { await h.session.pasteAgain("again") }
        await h.settle()
        h.session.retry()
        await h.settle()
        #expect(h.groq.callCount == calls, "retry waits until paste again is done")
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.pasteboard.string() == "my clipboard")
    }

    // Regression (/ship review: state-machines, lastError).
    // Value: protects=pasting something else (the last smart read) keeps a failed dictation's error and actions;
    // fails_when=pasteAgain clears lastError for any text;
    // why_new=only re-pasting the failed text itself was covered; seam=none;
    // no_claim=menu rendering of the actions (app target; unit only)
    @Test func pastingSomethingElseKeepsAFailedDictationsActions() async throws {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()
        let error = try #require(h.session.lastError)
        h.accessibility.isSecureInputActive = false
        let paste = Task { await h.session.pasteAgain("the last smart read") }
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.session.status == "Pasted")
        #expect(h.session.lastError == error)
        #expect(h.session.lastFailure != nil)
        // Extended by /ship coverage audit (pass 2).
        // Value: protects=pasting the last smart read does not replace the last dictation offered by
        // "Paste last dictation"; fails_when=pasteAgain records its text in lastText;
        // why_new=no test checks lastText after pasting other text; seam=none;
        // no_claim=none beyond protects (fakes; unit only)
        #expect(h.session.lastText == "Hello world.")
    }

    // Regression (/ship review: red team, discard).
    // Value: protects=Discard forgets a failed dictation's text, so paste again cannot paste it;
    // fails_when=discard() leaves lastText set to the discarded text;
    // why_new=discard was only tested for the kept recording; seam=none;
    // no_claim=none beyond protects (fakes; unit only)
    @Test func discardForgetsTheDiscardedText() async {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()
        #expect(h.session.lastText == "Hello world.")
        h.session.discard()
        #expect(h.session.lastText == nil)
    }

    // Generated by /ship coverage audit (pass 2).
    // Value: protects=paste again whose clipboard write times out pastes nothing, says "Not pasted"
    // with the reason, and keeps a failed dictation's error; fails_when=the .copiedInstead result is
    // reported as pasted, presses Cmd-V, or clears lastFailure/lastError;
    // why_new=only the pre-checked refusals (no focus, password field) reach a not-pasted branch;
    // seam=none (FakePasteboard.writeGate is a test-only fake knob);
    // no_claim=real lazy NSPasteboard providers (FakePasteboard with a blocking write; unit only)
    @Test func aClipboardThatDoesNotRespondIsReportedAsNotPasted() async throws {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()
        let error = try #require(h.session.lastError)
        h.accessibility.isSecureInputActive = false
        let gate = DispatchSemaphore(value: 0)
        h.pasteboard.writeGate = gate
        let writes = h.pasteboard.writes.count

        let paste = Task { await h.session.pasteAgain("Hello world.") }
        for _ in 0..<20 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.session.status == "Not pasted: the clipboard did not respond")
        #expect(h.session.state == .idle)
        #expect(h.accessibility.pastePresses.isEmpty, "nothing is pasted when the text never reached the clipboard")
        #expect(h.session.lastError == error, "the failed dictation keeps its Copy and Discard actions")
        #expect(h.session.lastFailure != nil)
        gate.signal() // the blocked write lands late, after the paste gave up
        for _ in 0..<200 where h.pasteboard.writes.count == writes { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.pasteboard.writes.count == writes + 1)
    }

    // Generated by /ship coverage audit (pass 2).
    // Value: protects=paste again tells the user when their clipboard could not be put back;
    // fails_when=pasteAgain shows "Pasted" and drops the insertion's restore note;
    // why_new=every paste-again test restores the clipboard cleanly; seam=none;
    // no_claim=real clipboard managers writing the pasteboard (FakePasteboard.externalWrite; unit only)
    @Test func aClipboardThatChangedDuringPasteAgainIsReported() async {
        let h = DictationHarness()
        let paste = Task { await h.session.pasteAgain("again") }
        for _ in 0..<100 where h.accessibility.pastePresses.isEmpty { await h.settle(); h.clock.advance(by: .milliseconds(10)) }
        h.pasteboard.externalWrite("user copied this")
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(h.session.status == ClipboardSnapshot.notRestoredNote)
        #expect(h.pasteboard.string() == "user copied this", "never overwrite what the user copied")
    }

    // Generated by /ship coverage audit (pass 2).
    // Value: protects=a read shortcut cannot cancel paste again: cancel() reports nothing cancelled and
    // the paste completes and restores the clipboard; fails_when=cancel() treats paste again's .pasting
    // as cancellable (no current dictation) and resets state mid-paste; why_new=cancel is only tested
    // while recording, transcribing, cleaning and idle; seam=none; no_claim=AppContainer's own .pasting
    // guard for reads (app target, untested; unit only)
    @Test func cancelDuringPasteAgainCancelsNothing() async {
        let h = DictationHarness()
        let paste = Task { await h.session.pasteAgain("again") }
        await h.settle()
        #expect(h.session.state == .pasting)
        #expect(!h.session.cancel())
        #expect(h.session.state == .pasting)
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.session.status == "Pasted")
        #expect(h.accessibility.pastePresses.count == 1)
        #expect(h.pasteboard.string() == "my clipboard")
    }

    // Generated by /ship coverage audit (pass 2).
    // Value: protects=discarding a failure that has no text keeps the earlier dictation for
    // "Paste last dictation"; fails_when=discard() clears lastText unconditionally;
    // why_new=the discard test only covers a failure whose text equals lastText; seam=none;
    // no_claim=none beyond protects (fake transcribers; unit only)
    @Test func discardingAFailedTranscriptionKeepsTheEarlierDictation() async {
        let h = DictationHarness()
        await h.hold()
        await h.finish()
        #expect(h.session.lastText == "Hello world.")
        h.groq.result = .failure(.unauthorized)
        h.apple.result = .failure(.unauthorized)
        await h.hold()
        await h.finish()
        #expect(h.session.lastFailure?.text == nil)
        h.session.discard()
        #expect(h.session.lastFailure == nil)
        #expect(h.session.lastText == "Hello world.")
    }

    // Regression (/ship adversarial review: Claude + Codex + Codex structured).
    // Value: protects=paste again waits while a read copies the selection, so the user's clipboard is not
    // replaced by the copied selection; fails_when=pasteAgain ignores readIsCapturing;
    // why_new=paste again was only guarded against dictation, not against a read's Copy; seam=none
    // (readIsCapturing is wired by AppContainer to ReadSession.state); no_claim=the live ReadSession
    // capture timing (flag stands in for ReadSession.state == .capturing; unit only)
    // Regression (/ship run 3 adversarial: Claude + Codex adversarial + Codex structured).
    // Value: protects=Copy dictated text waits while paste again owns the clipboard, so the paste lands and the
    // user's clipboard comes back; fails_when=copyText writes the clipboard regardless of state;
    // why_new=copyText was only tested while idle; seam=none;
    // no_claim=menu greying of the failure actions (app target; unit only)
    @Test func copyDictatedTextDuringPasteAgainWaits() async throws {
        let h = DictationHarness()
        h.session.recordKeyDown()
        h.accessibility.isSecureInputActive = true
        await h.settle()
        h.session.recordKeyUp()
        await h.finish()
        _ = try #require(h.session.lastFailure?.text)
        h.accessibility.isSecureInputActive = false
        let writes = h.pasteboard.writes.count
        let clipboardBefore = h.pasteboard.string() // the failed dictation was copied there

        let paste = Task { await h.session.pasteAgain("the last smart read") }
        await h.settle()
        #expect(h.session.state == .pasting)
        let copy = Task { await h.session.copyText() }
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        await copy.value
        #expect(!h.pasteboard.writes.dropFirst(writes).contains { $0.text == "Hello world." && !$0.transient },
                "Copy does not write while the paste owns the clipboard")
        #expect(h.pasteboard.string() == clipboardBefore, "the clipboard from before the paste comes back")
        #expect(h.session.status == "Pasted")
    }

    @Test func pasteAgainWhileAReadCopiesTheSelectionIsRefused() async {
        let h = DictationHarness()
        h.readCapturing = true
        let paste = Task { await h.session.pasteAgain("again") }
        for _ in 0..<40 { await h.settle(); h.clock.advance(by: .milliseconds(50)) }
        await paste.value
        #expect(h.session.state == .idle)
        #expect(h.accessibility.pastePresses.isEmpty)
        #expect(h.pasteboard.writes.isEmpty, "the read owns the clipboard until its Copy is done")
        #expect(h.pasteboard.string() == "my clipboard")
        #expect(h.session.status == "Not pasted: a read is copying the selection")
    }
}
