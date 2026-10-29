import Foundation
import Testing
@testable import VibeFlowCore

/// Follow-up questions (docs/designs/smart-read-follow-up.md): context resolution (D2, D11),
/// ownership (D12), the answer budget (D7) and spoken errors (D14).
@Suite("ReadSession: follow-up questions") @MainActor
struct QuestionTests {
    static let doc = "Hello there. This is a test. Goodbye."

    /// Smart reads the default selection and lets the brief finish.
    func briefed(_ h: SessionHarness) async {
        h.smartRead.result = .success(SmartReadResponse(text: "A short test.", stopReason: .endTurn))
        h.session.hotkey(.smartRead)
        await h.settle()
        h.elevenLabs.last?.finish()
        await h.settle()
    }

    func ask(_ h: SessionHarness, _ question: String) async {
        let id = h.session.beginQuestion()
        h.session.ask(question, for: try! #require(id))
        await h.settle()
    }

    @Test func questionAfterABriefSendsDocumentBriefAndSpeaksTheAnswer() async throws {
        let h = SessionHarness()
        await briefed(h)
        h.smartRead.askResult = .success(SmartReadResponse(text: "It says goodbye.", stopReason: .endTurn))
        await ask(h, "How does it end?")

        let request = try #require(h.smartRead.asks.first)
        #expect(request.document == Self.doc)
        #expect(request.brief == "A short test.")
        #expect(request.question == "How does it end?")
        #expect(request.maxTokens == 600)
        #expect(h.elevenLabs.requests.last?.text == "It says goodbye.")
        #expect(h.session.conversation?.turns == [ConversationTurn(question: "How does it end?", answer: "It says goodbye.")])
    }

    @Test func secondQuestionCarriesTheFirstTurn() async throws {
        let h = SessionHarness()
        await briefed(h)
        await ask(h, "First?")
        h.elevenLabs.last?.finish()
        await h.settle()
        await ask(h, "Second?")
        let second = try #require(h.smartRead.asks.last)
        #expect(second.turns == [ConversationTurn(question: "First?", answer: "answer")])
        #expect(second.question == "Second?")
    }

    @Test func newSelectionStartsANewConversationWithoutABrief() async throws {
        let h = SessionHarness()
        await briefed(h)
        h.capture.result = CaptureResult(text: "Another text entirely.")
        await ask(h, "What is this?")
        let request = try #require(h.smartRead.asks.first)
        #expect(request.document == "Another text entirely.")
        #expect(request.brief == nil)
        #expect(request.turns.isEmpty)
    }

    @Test func nothingSelectedContinuesTheConversation() async throws {
        let h = SessionHarness()
        await briefed(h)
        h.capture.result = .none
        await ask(h, "And?")
        #expect(h.smartRead.asks.first?.document == Self.doc)
    }

    @Test func failedCaptureNeverAsksAboutTheOldText() async throws {
        let h = SessionHarness()
        await briefed(h)
        h.capture.result = .failed
        await ask(h, "And?")
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.lastError?.message == "Couldn't read the selection. Select the text again")
        #expect(h.apple.requests.last?.text == "Couldn't read the selection.")
    }

    @Test func staleOrMissingContextAsksForASelection() async throws {
        let h = SessionHarness { $0.capture.result = .none }
        await ask(h, "What?")
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.status == "Select text to ask about")

        let later = SessionHarness()
        await briefed(later)
        let start = Date()
        later.session.now = { start.addingTimeInterval(Conversation.staleAfter + 1) }
        later.capture.result = .none
        await ask(later, "Still there?")
        #expect(later.smartRead.asks.isEmpty, "a 31-minute-old text needs a fresh selection")
    }

    @Test func selectThenAskWorksWithoutAnyRead() async throws {
        let h = SessionHarness()
        await ask(h, "What is this?")
        let request = try #require(h.smartRead.asks.first)
        #expect(request.document == Self.doc)
        #expect(request.brief == nil)
    }

    @Test func transcriptBeforeCaptureWaitsForTheCapture() async throws {
        let h = SessionHarness { $0.capture.delay = .seconds(1) }
        let id = try #require(h.session.beginQuestion())
        h.session.ask("Early?", for: id)
        await h.settle()
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.state == .capturing)
        h.clock.advance(by: .seconds(1))
        await h.settle()
        #expect(h.smartRead.asks.first?.question == "Early?")
    }

    @Test func stopBetweenReleaseAndTranscriptMeansNoClaudeCall() async throws {
        let h = SessionHarness()
        let id = try #require(h.session.beginQuestion())
        await h.settle()
        #expect(h.session.state == .capturing, "Stop stays available while transcribing")
        h.session.stop()
        h.session.ask("Too late?", for: id)
        await h.settle()
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.state == .idle)
    }

    @Test func aNewReadDropsTheOldQuestion() async throws {
        let h = SessionHarness()
        let id = try #require(h.session.beginQuestion())
        await h.settle()
        h.session.stop()
        h.session.hotkey(.read)
        h.session.ask("Old?", for: id)
        await h.settle()
        #expect(h.smartRead.asks.isEmpty)
    }

    @Test func cutOffAnswerIsSpokenToTheLastFullSentence() async throws {
        let h = SessionHarness()
        h.smartRead.askResult = .success(SmartReadResponse(text: "First step is this. Second step is", stopReason: .maxTokens))
        await ask(h, "Steps?")
        #expect(h.elevenLabs.requests.last?.text == "First step is this.")
        #expect(h.session.status == "Answer cut short")
    }

    @Test func claudeFailuresAreShownAndSpoken() async throws {
        let h = SessionHarness()
        h.smartRead.askResult = .failure(.offline)
        await ask(h, "Anything?")
        #expect(h.session.lastError == LastError(message: "Questions need a connection"))
        #expect(h.apple.requests.last?.text == "No connection.")

        h.session.hotkey(.read)
        #expect(h.apple.last?.cancelCount == 1, "the next action silences the spoken error")
    }

    @Test func transcriptionFailureNeverCallsClaude() async throws {
        let h = SessionHarness()
        let id = try #require(h.session.beginQuestion())
        h.session.questionFailed("Didn't catch that", spoken: "Didn't catch that.", for: id)
        await h.settle()
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.lastError?.message == "Didn't catch that")
        #expect(h.apple.requests.last?.text == "Didn't catch that.")
    }

    @Test func missingKeyOffersKeys() async throws {
        let h = SessionHarness()
        try h.secrets.delete(.anthropic)
        await ask(h, "Anything?")
        #expect(h.smartRead.asks.isEmpty)
        #expect(h.session.lastError?.actions == [.openKeys])
    }

    @Test func conversationKeepsTheLastTenTurns() {
        var c = Conversation(document: "d", preset: .default, createdAt: Date())
        for i in 0..<12 { c.append(ConversationTurn(question: "q\(i)", answer: "a\(i)")) }
        #expect(c.turns.count == 10)
        #expect(c.turns.first?.question == "q2")
    }

    // MARK: Streaming answers (latency follow-up)

    @Test func streamedAnswerGoesToTheVoiceASentenceAtATime() async throws {
        let h = SessionHarness(streamingAnswers: true)
        h.smartRead.askChunks = [.text("It says good"), .text("bye. Then it"), .text(" ends."), .done(.endTurn)]
        await ask(h, "How does it end?")

        let stream = try #require(h.answerVoice.last)
        #expect(stream.pieces == ["It says goodbye.", " Then it ends."])
        #expect(stream.finishedText)
        #expect(h.elevenLabs.requests.isEmpty, "no second, non-streamed request")
        #expect(h.session.state == .transforming, "thinking until the first audio")
        stream.emit(.started)
        await h.settle()
        #expect(h.session.state == .speaking)
        stream.finish()
        await h.settle()
        #expect(h.session.state == .idle)
        #expect(h.session.lastExchange == ConversationTurn(question: "How does it end?", answer: "It says goodbye. Then it ends."))
    }

    @Test func streamedCutOffAnswerNeverSendsTheUnfinishedSentence() async throws {
        let h = SessionHarness(streamingAnswers: true)
        h.smartRead.askChunks = [.text("Step one is this. Step two is"), .done(.maxTokens)]
        await ask(h, "Steps?")
        let stream = try #require(h.answerVoice.last)
        #expect(stream.pieces == ["Step one is this."])
        #expect(stream.finishedText)
        #expect(h.session.status == "Answer cut short")
        #expect(h.session.lastExchange?.answer == "Step one is this.")
    }

    @Test func voiceFailureMidAnswerContinuesWithAppleOnceTheAnswerIsDone() async throws {
        let h = SessionHarness(streamingAnswers: true)
        h.smartRead.askChunks = [.text("First part. Second part.")]
        await ask(h, "Q?")
        let stream = try #require(h.answerVoice.last)
        stream.fail(.connectionLost(lastPlayedOffset: 14))
        await h.settle()
        #expect(h.apple.requests.isEmpty, "Apple waits for the whole answer")
        #expect(h.session.state == .transforming)
        #expect(h.session.status == "Continued with Apple voice: connection lost")
    }

    @Test func smartReadSpeedAppliesToBriefsAndAnswersButNotReads() async throws {
        var config = SessionConfiguration()
        config.smartReadSpeed = 0.8
        let h = SessionHarness(streamingAnswers: true, configuration: config)
        h.presets.defaultPreset.speed = 1.6
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.elevenLabs.requests.last?.speed == 1.6)
        h.elevenLabs.last?.finish()
        await h.settle()

        h.session.hotkey(.smartRead)
        await h.settle()
        #expect(h.elevenLabs.requests.last?.speed == 0.8, "the brief")
        h.elevenLabs.last?.finish()
        await h.settle()

        await ask(h, "Q?")
        #expect(h.answerVoice.requests.last?.speed == 0.8, "the answer")
    }

    @Test func noStreamingVoiceStillSpeaksTheFinishedAnswer() async throws {
        let h = SessionHarness(streamingAnswers: true) { $0.presets.defaultPreset.provider = .apple }
        h.smartRead.askChunks = [.text("Apple says this."), .done(.endTurn)]
        await ask(h, "Q?")
        #expect(h.answerVoice.requests.isEmpty)
        #expect(h.apple.requests.last?.text == "Apple says this.")
    }

    // MARK: History

    @Test func readsAndAnswersAreRecordedButReplaysAreNot() async throws {
        let h = SessionHarness()
        var recorded: [HistoryEntry] = []
        h.session.onRecord = { recorded.append($0) }
        await briefed(h)
        h.smartRead.askResult = .success(SmartReadResponse(text: "It ends with goodbye.", stopReason: .endTurn))
        await ask(h, "How does it end?")
        h.elevenLabs.last?.finish()
        await h.settle()

        #expect(recorded.map(\.kind) == [.read, .question])
        #expect(recorded[0].text == Self.doc)
        #expect(recorded[0].smart)
        #expect(recorded[0].sourceBundleID == "com.apple.Safari")
        #expect(recorded[1].question == "How does it end?")
        #expect(recorded[1].text == "It ends with goodbye.")
        #expect(recorded[1].documentExcerpt == Self.doc)

        h.session.readAgain(Self.doc)
        await h.settle()
        #expect(h.elevenLabs.requests.last?.text == Self.doc)
        #expect(recorded.count == 2, "a replay from History adds nothing")
    }

    @Test func refusedReadsAreNotRecorded() async throws {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: String(repeating: "x", count: 45_000)) }
        var recorded: [HistoryEntry] = []
        h.session.onRecord = { recorded.append($0) }
        h.session.hotkey(.read)
        await h.settle()
        #expect(recorded.isEmpty)
    }
}
