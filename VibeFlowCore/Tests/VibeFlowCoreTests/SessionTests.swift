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
        let h = SessionHarness { $0.accessibility.frontmost = FrontmostApp(pid: 300, bundleID: "com.openai.chat") }
        h.session.clipboardHotkey(.smartRead, text: "I'd keep the cron job. Want nightly or hourly?")
        await h.settle()
        #expect(h.smartRead.requests.first?.aiReply == true, "a reply copied with the Copy button is still the assistant")

        let menu = SessionHarness { $0.accessibility.frontmost = FrontmostApp(pid: 300, bundleID: "com.openai.chat") }
        menu.session.menuRead(.smartRead, text: "I'd keep the cron job. Want nightly or hourly?")
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
