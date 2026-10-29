import Foundation
import Testing
@testable import VibeFlowCore

@Suite("ReadSession: read flow") @MainActor
struct ReadFlowTests {
    @Test func hotkeyCapturesSpeaksWithElevenLabsAndReturnsToIdle() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        #expect(h.session.state == .capturing)
        await h.settle()

        #expect(h.session.state == .buffering)
        let playback = try #require(h.elevenLabs.last)
        #expect(h.elevenLabs.requests.first?.text == "Hello there. This is a test. Goodbye.")
        #expect(h.apple.requests.isEmpty)

        playback.emit(.started)
        await h.settle()
        #expect(h.session.state == .speaking)
        #expect(h.session.iconState == .speaking)

        playback.finish()
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Done")
        #expect(h.session.lastError == nil)
    }

    @Test func secondPressWhileSpeakingCancelsAndNeverStartsANewSession() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        h.elevenLabs.last?.emit(.started)
        await h.settle()

        h.session.hotkey(.read)
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Stopped")
        #expect(h.elevenLabs.last?.cancelCount == 1)
        #expect(h.capture.calls.count == 1, "the cancelling press did not capture again")
    }

    @Test func pressDuringCapturingCancelsAndLateCaptureResultIsDropped() async throws {
        let h = SessionHarness { $0.capture.delay = .seconds(1) }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .capturing)

        h.session.hotkey(.smartRead)
        #expect(h.session.state == .idle)

        h.clock.advance(by: .seconds(1)) // the old capture completes now
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func lateEventAfterCancelIsDropped() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        let playback = try #require(h.elevenLabs.last)
        h.session.stop()
        playback.emit(.started)
        await h.settle()
        #expect(h.session.state == .idle)
    }

    @Test func withoutAccessibilityTrustNothingIsCaptured() async throws {
        let h = SessionHarness { $0.accessibility.isTrusted = false }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.iconState == .warning)
        #expect(h.session.lastError == nil, "warning is a display state over idle, not an error entry")
        #expect(h.session.status == "Grant Accessibility access to read selections")
        #expect(h.capture.calls.isEmpty)
    }

    /// The menu re-checks permissions as it opens (docs/designs/dev-prod-channels.md, P4).
    @Test func grantingAccessibilityInSettingsClearsTheWarningWithoutAShortcut() async throws {
        let h = SessionHarness { $0.accessibility.isTrusted = false }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.iconState == .warning)

        h.accessibility.isTrusted = true
        h.session.refreshAccessibility()
        #expect(h.session.accessibilityTrusted)
        #expect(h.session.iconState == .idle)
        #expect(h.session.status == "Ready")

        h.accessibility.isTrusted = false
        h.session.refreshAccessibility()
        #expect(h.session.iconState == .warning, "a grant taken away shows again too")
    }

    @Test func whitespaceOnlySelectionIsNoText() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: "  \n\t ") }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Nothing selected")
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func noElevenLabsKeyUsesAppleWithStatusLine() async throws {
        let h = SessionHarness { try? $0.secrets.delete(.elevenLabs) }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.apple.requests.count == 1)
        #expect(h.elevenLabs.requests.isEmpty)
        #expect(h.session.status == "Using Apple voice: no ElevenLabs key")
    }

    @Test func presetPinnedToAppleNeverCallsElevenLabs() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", provider: .apple)
        }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.apple.requests.count == 1)
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func frozenPresetSurvivesAnAppSwitchDuringTheConfirmWait() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", elevenLabsVoiceID: "safari-voice")
            $0.presets.byBundle["com.tinyspeck.slackmacgap"] = AppPreset(bundleID: "com.tinyspeck.slackmacgap", elevenLabsVoiceID: "slack-voice")
            $0.capture.result = CaptureResult(text: String(repeating: "a", count: 12_000))
        }
        h.session.hotkey(.read)
        await h.settle()
        guard case .awaitingConfirm = h.session.state else { Issue.record("expected awaitingConfirm"); return }

        h.accessibility.frontmost = FrontmostApp(pid: 200, bundleID: "com.tinyspeck.slackmacgap")
        h.session.hotkey(.read) // confirm
        await h.settle()
        #expect(h.elevenLabs.requests.first?.voiceID == "safari-voice")
        #expect(h.presets.lookups == ["com.apple.Safari"])
    }
}

@Suite("ReadSession: size guard") @MainActor
struct SizeGuardTests {
    static let long = String(repeating: "word ", count: 2_500) // 12,500 chars

    @Test func overCapWaitsAndSameHotkeyProceedsWithCapturedText() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: Self.long) }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .awaitingConfirm(kind: .read, origin: .hotkey, characters: Self.long.trimmingCharacters(in: .whitespaces).count))
        #expect(h.session.iconState == .awaitingConfirm)
        #expect(h.session.status.contains("Press the shortcut again within 5 s"))

        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .buffering)
        #expect(h.capture.calls.count == 1, "confirm reuses the captured text")
        #expect(h.elevenLabs.requests.count == 1)
    }

    @Test func otherHotkeyCancelsTheConfirmation() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: Self.long) }
        h.session.hotkey(.read)
        await h.settle()
        h.session.hotkey(.smartRead)
        #expect(h.session.state == .idle)
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func confirmationExpiresAfterFiveSeconds() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: Self.long) }
        h.session.hotkey(.read)
        await h.settle()
        h.clock.advance(by: .seconds(4))
        await h.settle()
        guard case .awaitingConfirm = h.session.state else { Issue.record("still waiting at 4 s"); return }
        h.clock.advance(by: .seconds(1))
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func aboveTheModelLimitIsRefusedWithoutConfirmation() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: String(repeating: "x", count: 45_000)) }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.status.hasPrefix("Selection too long (45,000 characters, limit 40,000)"))
    }

    @Test func menuReadUsesDefaultPresetAndReadAnywayConfirms() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", elevenLabsVoiceID: "safari-voice")
            $0.presets.defaultPreset = AppPreset(elevenLabsVoiceID: "default-voice")
        }
        h.session.menuRead(.read, text: Self.long)
        #expect(h.session.state == .awaitingConfirm(kind: .read, origin: .menu, characters: Self.long.trimmingCharacters(in: .whitespaces).count))
        #expect(h.session.status.contains("Click Read anyway within 10 s"))

        h.session.readAnyway()
        await h.settle()
        #expect(h.elevenLabs.requests.first?.voiceID == "default-voice")
        #expect(h.capture.calls.isEmpty)
    }

    @Test func hotkeyCancelsAMenuConfirmation() async throws {
        let h = SessionHarness()
        h.session.menuRead(.read, text: Self.long)
        h.session.hotkey(.read)
        #expect(h.session.state == .idle)
        #expect(h.elevenLabs.requests.isEmpty)
    }
}

@Suite("ReadSession: provider fallback") @MainActor
struct FallbackTests {
    @Test func preFirstChunkFailureFallsToAppleFromTheStart() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        let el = try #require(h.elevenLabs.last)
        el.fail(.emptyResponse)
        await h.settle()

        #expect(h.apple.requests.count == 1)
        #expect(h.apple.requests.first?.startOffset == 0)
        #expect(h.session.status == "Using Apple voice: ElevenLabs unavailable (empty response)")
        #expect(h.session.state == .buffering)
        #expect(el.cancelCount >= 1)
    }

    @Test func lateElevenLabsEventsAfterHandoffAreDropped() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        let el = try #require(h.elevenLabs.last)
        el.fail(.offline)
        await h.settle()
        let apple = try #require(h.apple.last)

        // A stale .started from ElevenLabs must not flip state; Apple's does.
        el.emit(.started)
        await h.settle()
        #expect(h.session.state == .buffering)
        apple.emit(.started)
        await h.settle()
        #expect(h.session.state == .speaking)
    }

    @Test func firstChunkTimeoutFallsToApple() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.session.state == .buffering)
        h.clock.advance(by: .seconds(5))
        await h.settle()
        #expect(h.apple.requests.count == 1)
        #expect(h.session.status == "Using Apple voice: ElevenLabs unavailable (no audio within the timeout)")
    }

    @Test func connectionLostResumesWithAppleFromTheSentenceStart() async throws {
        let text = "First sentence here. Second sentence here. Third one."
        let h = SessionHarness { $0.capture.result = CaptureResult(text: text) }
        h.session.hotkey(.read)
        await h.settle()
        let el = try #require(h.elevenLabs.last)
        el.emit(.started)
        await h.settle()
        el.fail(.connectionLost(lastPlayedOffset: 30)) // inside "Second sentence here."
        await h.settle()

        let resume = try #require(h.apple.requests.first)
        #expect(resume.startOffset == 21)
        #expect(resume.text == text)
        #expect(h.session.status == "Continued with Apple voice: connection lost")
    }

    @Test func unauthorizedStopsWithTheKeysAction() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        h.elevenLabs.last?.fail(.unauthorized)
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.iconState == .error)
        #expect(h.session.lastError == LastError(message: "ElevenLabs key rejected", actions: [.openKeys]))
        #expect(h.apple.requests.isEmpty)
    }

    @Test func appleFailureIsAnErrorNotAnotherFallback() async throws {
        let h = SessionHarness { try? $0.secrets.delete(.elevenLabs) }
        h.session.hotkey(.read)
        await h.settle()
        h.apple.last?.fail(.other("no voice"))
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.lastError?.message == "Speech failed: no voice")
        #expect(h.apple.requests.count == 1)
    }

    @Test func nextSuccessfulReadClearsLastError() async throws {
        let h = SessionHarness()
        h.session.hotkey(.read)
        await h.settle()
        h.elevenLabs.last?.fail(.unauthorized)
        await h.settle()
        #expect(h.session.lastError != nil)
        h.session.hotkey(.read)
        #expect(h.session.lastError == nil)
    }
}

@Suite("ReadSession: smart read") @MainActor
struct SmartReadTests {
    @Test func transformsThenSpeaksTheBriefInTheSourceLanguage() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: "Das ist ein deutscher Vertragstext mit einigen Klauseln.") }
        h.smartRead.result = .success(SmartReadResponse(text: "Kurzfassung.", stopReason: .endTurn))
        h.session.hotkey(.smartRead)
        await h.settle()

        #expect(h.session.state == .buffering)
        let request = try #require(h.smartRead.requests.first)
        #expect(request.mode == .brief)
        #expect(request.language == "de")
        #expect(request.maxTokens == 800)
        #expect(h.elevenLabs.requests.first?.text == "Kurzfassung.")
        #expect(h.session.lastAnswer == "Kurzfassung.", "kept for Paste last smart read")
    }

    @Test func presetInstructionsReachTheRequest() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", smartReadInstructions: "Only deadlines.")
        }
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.smartRead.requests.first?.instructions == "Only deadlines.")
    }

    @Test func aiAssistantAppMarksTheRequestAsAnAIReply() async throws {
        let h = SessionHarness { $0.accessibility.frontmost = FrontmostApp(pid: 300, bundleID: "com.anthropic.claudefordesktop") }
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.smartRead.requests.first?.aiReply == true)

        let browser = SessionHarness()
        browser.session.hotkey(.smartRead)
        await browser.settle()
        #expect(browser.smartRead.requests.first?.aiReply == false, "a browser page can be anything")
    }

    @Test func clipboardSmartReadInAnAIAppIsAnAIReply() async throws {
        let chatGPT = FrontmostApp(pid: 300, bundleID: "com.openai.chat")
        let reply = "I'd keep the cron job. Want nightly or hourly?"

        let copiedThere = SessionHarness {
            $0.accessibility.frontmost = chatGPT
            $0.clipboardSource.sourceBundleID = "com.openai.chat"
        }
        copiedThere.session.clipboardHotkey(.smartRead, text: reply)
        await copiedThere.settle()
        #expect(copiedThere.smartRead.requests.first?.aiReply == true, "a reply copied with the Copy button is still the assistant")
        // Extended by /ship coverage audit.
        // Value: protects=a clipboard smart read in the assistant's voice offers the AI's brief, not the copied
        // reply, for "Paste last smart read"; fails_when=lastAnswer is taken from the clipboard text or skipped on
        // the clipboard/aiReply path; why_new=lastAnswer was only asserted on the selection hotkey path; seam=none;
        // no_claim=the real model's wording (FakeSmartReadClient returns "brief"; unit only)
        #expect(copiedThere.session.lastAnswer == "brief")

        let copiedInMail = SessionHarness {
            $0.accessibility.frontmost = chatGPT
            $0.clipboardSource.sourceBundleID = "com.apple.mail"
        }
        copiedInMail.session.clipboardHotkey(.smartRead, text: "Reset your password at the link below.")
        await copiedInMail.settle()
        #expect(copiedInMail.smartRead.requests.first?.aiReply == false, "text copied elsewhere is not the assistant's advice")

        let unknown = SessionHarness { $0.accessibility.frontmost = chatGPT }
        unknown.session.clipboardHotkey(.smartRead, text: reply)
        await unknown.settle()
        #expect(unknown.smartRead.requests.first?.aiReply == false, "an unknown source gets the neutral brief")

        let switchedAway = SessionHarness { $0.clipboardSource.sourceBundleID = "com.openai.chat" }
        switchedAway.session.clipboardHotkey(.smartRead, text: reply)
        await switchedAway.settle()
        #expect(switchedAway.smartRead.requests.first?.aiReply == false, "the AI app must still be in front")
        #expect(switchedAway.presets.lookups == [nil], "clipboard reads stay on the default preset")

        let menu = SessionHarness {
            $0.accessibility.frontmost = chatGPT
            $0.clipboardSource.sourceBundleID = "com.openai.chat"
        }
        menu.session.menuRead(.smartRead, text: reply)
        await menu.settle()
        #expect(menu.smartRead.requests.first?.aiReply == false, "menu reads do not guess the source app")
    }

    @Test func disabledInPresetFallsBackToPlainRead() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", smartReadEnabled: false)
        }
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.smartRead.requests.isEmpty)
        #expect(h.elevenLabs.requests.count == 1)
        #expect(h.session.status == "Smart read disabled for com.apple.Safari")
        // Extended by /ship coverage audit.
        // Value: protects=only an AI result becomes the "last smart read", never the original text read plainly;
        // fails_when=lastAnswer is set in speak() or before the smartReadEnabled guard;
        // why_new=lastAnswer was only asserted on smart-read success and incomplete; seam=none;
        // no_claim=none beyond protects (fake providers; unit only)
        #expect(h.session.lastAnswer == nil)
    }

    @Test func missingAnthropicKeyOffersKeysAndReadOriginal() async throws {
        let h = SessionHarness { try? $0.secrets.delete(.anthropic) }
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.lastError?.actions == [.openKeys, .readOriginal])
        #expect(h.smartRead.requests.isEmpty)
    }

    @Test func timeoutAfterTwentySecondsFails() async throws {
        let h = SessionHarness()
        h.smartRead.delay = .seconds(60)
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.state == .transforming)
        #expect(h.session.iconState == .transforming)
        h.clock.advance(by: .seconds(20))
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.lastError == LastError(message: "Smart read failed: timed out", actions: [.readOriginal]))
    }

    @Test func truncatedOutputIsIncomplete() async throws {
        let h = SessionHarness()
        h.smartRead.result = .success(SmartReadResponse(text: "half a brief", stopReason: .maxTokens))
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.lastError?.message == "Smart read incomplete")
        #expect(h.elevenLabs.requests.isEmpty)
        #expect(h.session.lastAnswer == nil, "an incomplete brief is never offered for pasting")
    }

    @Test func rateLimitedIsReportedWithReadOriginal() async throws {
        let h = SessionHarness()
        h.smartRead.result = .failure(.rateLimited)
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.lastError == LastError(message: "Smart read failed: rate limited", actions: [.readOriginal]))
    }

    @Test func hotkeyDuringTransformCancels() async throws {
        let h = SessionHarness()
        h.smartRead.delay = .seconds(10)
        h.session.hotkey(.smartRead)
        await h.settle()
        h.session.hotkey(.smartRead)
        #expect(h.session.state == .idle)
        h.clock.advance(by: .seconds(10))
        await h.settle()
        #expect(h.elevenLabs.requests.isEmpty)
    }

    // Generated by /ship coverage audit (replaces a pass-1 lastAnswer assertion in hotkeyDuringTransformCancels
    // that could not fail: there cancellation wins inside withTimeout, so the success path never runs).
    // Value: protects=a smart read answer that arrives after the user stopped it and started a newer read is
    // dropped: no "last smart read", no speech; fails_when=the isCurrent(token) guard after withTimeout is removed
    // or inverted, or lastAnswer is set before it; why_new=no test lets a stale success reach the main actor;
    // seam=none; no_claim=real URLSession cancellation timing (held FakeSmartReadClient, FakeClock; unit only)
    @Test func aStaleAnswerAfterTheUserMovedOnIsDropped() async throws {
        let h = SessionHarness()
        h.smartRead.holdsResponses = true
        h.smartRead.result = .success(SmartReadResponse(text: "Stale brief.", stopReason: .endTurn))
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.state == .transforming)
        #expect(h.smartRead.heldCount == 1)
        #expect(h.clock.sleeperCount == 1, "the transform timeout is armed")

        // The answer arrives. Block the main actor so the session only sees it after the user moved on;
        // the timeout sleeper disappears once withTimeout has taken the answer and cancelled the timer.
        h.smartRead.releaseHeld()
        let deadline = Date().addingTimeInterval(5)
        while h.clock.sleeperCount > 0 && Date() < deadline { usleep(1_000) }
        try #require(h.clock.sleeperCount == 0, "withTimeout returned the answer before the user moved on")

        h.session.hotkey(.smartRead)
        #expect(h.session.state == .idle)
        h.session.hotkey(.smartRead)
        await h.settle()

        #expect(h.smartRead.requests.count == 2)
        #expect(h.session.state == .transforming, "the newer smart read is still waiting for its own answer")
        #expect(h.session.lastAnswer == nil)
        #expect(h.elevenLabs.requests.isEmpty)

        h.session.stop()
        h.smartRead.releaseHeld()
        await h.settle()
    }

    // Generated by /ship coverage audit.
    // Value: protects=the last smart read survives later plain reads and failed smart reads, so "Paste last smart
    // read" still offers it; fails_when=start()/startClipboardRead() or fail() resets lastAnswer alongside
    // lastError; why_new=no test runs a second read after a smart read succeeded; seam=none;
    // no_claim=menu enablement in MenuBarView (app target, untested; fake providers; unit only)
    @Test func theLastAnswerSurvivesLaterReadsThatProduceNone() async throws {
        let h = SessionHarness()
        h.smartRead.result = .success(SmartReadResponse(text: "First brief.", stopReason: .endTurn))
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.lastAnswer == "First brief.")
        h.session.stop()

        h.session.hotkey(.read)
        await h.settle()
        #expect(h.elevenLabs.requests.count == 2)
        h.session.stop()
        #expect(h.session.lastAnswer == "First brief.", "a plain read is not a smart read")

        h.smartRead.result = .failure(.rateLimited)
        h.session.clipboardHotkey(.smartRead, text: "Something else.")
        await h.settle()
        #expect(h.session.lastError?.message == "Smart read failed: rate limited")
        #expect(h.session.lastAnswer == "First brief.", "a failed smart read keeps the earlier answer")
    }

    @Test func readOriginalReplaysStoredTextWithThePlainProvider() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: "Original text.") }
        h.smartRead.result = .failure(.overloaded)
        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.session.lastError?.actions == [.readOriginal])

        h.session.readOriginal()
        await h.settle()
        #expect(h.session.lastError == nil)
        #expect(h.elevenLabs.requests.first?.text == "Original text.")
        #expect(h.capture.calls.count == 1, "replay never re-captures")
    }

    @Test func cleanupTokenBudgetFollowsInputSize() {
        let config = SessionConfiguration()
        #expect(config.maxTokens(for: .cleanup, inputCharacters: 3_000) == 1_200)
        #expect(config.maxTokens(for: .cleanup, inputCharacters: 39_000) == 13_200)
        #expect(config.maxTokens(for: .cleanup, inputCharacters: 40_000) == 13_333)
        #expect(config.maxTokens(for: .brief, inputCharacters: 40_000) == 800)
    }
}

@Suite struct SentencesTests {
    @Test func startOffsetFindsTheContainingSentence() {
        let text = "First sentence here. Second sentence here. Third one."
        #expect(Sentences.startOffset(containing: 0, in: text) == 0)
        #expect(Sentences.startOffset(containing: 10, in: text) == 0)
        #expect(Sentences.startOffset(containing: 21, in: text) == 21)
        #expect(Sentences.startOffset(containing: 30, in: text) == 21)
        #expect(Sentences.startOffset(containing: 45, in: text) == 43)
        #expect(Sentences.startOffset(containing: 999, in: text) == 43)
        #expect(Sentences.startOffset(containing: 5, in: "") == 0)
    }

    @Test func suffixFromOffset() {
        #expect(Sentences.suffix(of: "abc def", from: 4) == "def")
        #expect(Sentences.suffix(of: "abc", from: 0) == "abc")
        #expect(Sentences.suffix(of: "abc", from: 9) == "")
    }
}

@Suite struct LanguageDetectorTests {
    @Test func detectsGermanAndEnglish() {
        #expect(LanguageDetector.detect("Dies ist ein längerer deutscher Satz über Verträge und Fristen.") == "de")
        #expect(LanguageDetector.detect("This is a longer English sentence about contracts and deadlines.") == "en")
        #expect(LanguageDetector.detect("   ") == nil)
    }
}

@Suite("ReadSession: clipboard shortcuts") @MainActor
struct ClipboardHotkeyTests {
    static let long = String(repeating: "word ", count: 2_500)

    @Test func shiftShortcutSpeaksTheClipboardWithTheDefaultPreset() async throws {
        let h = SessionHarness {
            $0.presets.byBundle["com.apple.Safari"] = AppPreset(bundleID: "com.apple.Safari", elevenLabsVoiceID: "safari-voice")
            $0.presets.defaultPreset = AppPreset(elevenLabsVoiceID: "default-voice")
        }
        h.session.clipboardHotkey(.read, text: "From the clipboard.")
        await h.settle()
        #expect(h.elevenLabs.requests.first?.text == "From the clipboard.")
        #expect(h.elevenLabs.requests.first?.voiceID == "default-voice")
        #expect(h.capture.calls.isEmpty, "never captures the selection")
    }

    @Test func pressingItAgainConfirmsALongClipboard() async throws {
        let h = SessionHarness()
        h.session.clipboardHotkey(.read, text: Self.long)
        guard case .awaitingConfirm(.read, .clipboardHotkey, _) = h.session.state else { Issue.record("expected confirm"); return }
        #expect(h.session.status.contains("Press the shortcut again within 5 s"))
        h.session.clipboardHotkey(.read, text: Self.long)
        await h.settle()
        #expect(h.elevenLabs.requests.count == 1)
    }

    @Test func pressingItWhileSpeakingStops() async throws {
        let h = SessionHarness()
        h.session.clipboardHotkey(.read, text: "Short.")
        await h.settle()
        h.session.clipboardHotkey(.read, text: "Short.")
        #expect(h.session.state == .idle)
        #expect(h.session.status == "Stopped")
    }

    @Test func theSelectionShortcutCancelsAClipboardConfirmation() async throws {
        let h = SessionHarness()
        h.session.clipboardHotkey(.read, text: Self.long)
        h.session.hotkey(.read)
        #expect(h.session.state == .idle)
        #expect(h.elevenLabs.requests.isEmpty)
    }

    @Test func smartReadClipboardRunsTheTransform() async throws {
        let h = SessionHarness()
        h.session.clipboardHotkey(.smartRead, text: "A paragraph to explain.")
        await h.settle()
        #expect(h.smartRead.requests.first?.text == "A paragraph to explain.")
    }
}
