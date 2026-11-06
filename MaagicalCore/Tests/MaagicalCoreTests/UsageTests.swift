import Foundation
import Testing
@testable import MaagicalCore

@Suite("Usage meter")
struct UsageMeterTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func request(_ url: String, json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        if let json { request.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        return request
    }

    @Test func anthropicMessageReportsTokensAndModel() {
        let body = Data(#"{"model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":1200,"output_tokens":300}}"#.utf8)
        let event = UsageMeter.event(request: request("https://api.anthropic.com/v1/messages"), status: 200, body: body, date: now)
        #expect(event == UsageEvent(provider: .anthropic, kind: .languageModel, model: "claude-haiku-5-5", date: now,
                                    inputTokens: 1200, outputTokens: 300))
    }

    @Test func failedRequestsAndOtherHostsAreNotMetered() {
        let body = Data(#"{"model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        #expect(UsageMeter.event(request: request("https://api.anthropic.com/v1/messages"), status: 429, body: body, date: now) == nil)
        #expect(UsageMeter.event(request: request("http://localhost:8000/v1/chat/completions"), status: 200, body: body, date: now) == nil)
        #expect(UsageMeter.event(request: request("https://www.googleapis.com/calendar/v3/x"), status: 200, body: body, date: now) == nil)
    }

    @Test func groqChatReportsPromptAndCompletionTokens() {
        let body = Data(#"{"model":"openai/gpt-oss-20b","choices":[],"usage":{"prompt_tokens":400,"completion_tokens":90}}"#.utf8)
        let event = UsageMeter.event(request: request("https://api.groq.com/openai/v1/chat/completions"), status: 200, body: body, date: now)
        #expect(event?.provider == .groq)
        #expect(event?.kind == .languageModel)
        #expect(event?.inputTokens == 400)
        #expect(event?.outputTokens == 90)
    }

    @Test func whisperReportsDurationAndTheModelFromTheMultipartBody() {
        let audio = RecordedAudio(pcm16: Data(repeating: 0, count: 64))
        let urlRequest = OpenAITranscriber.buildRequest(audio: audio, language: "de-DE", model: "whisper-large-v3-turbo",
                                                        baseURL: OpenAITranscriber.groqBaseURL, apiKey: "k")
        let body = Data(#"{"text":"hallo","duration":4.5,"segments":[]}"#.utf8)
        let event = UsageMeter.event(request: urlRequest, status: 200, body: body, date: now)
        #expect(event?.model == "whisper-large-v3-turbo")
        #expect(event?.audioSeconds == 4.5)
        #expect(event?.kind == .speechToText)
    }

    @Test func scribeUsesTheLastWordEnd() {
        let body = Data(#"{"transcripts":[{"words":[{"end":12.5}]},{"words":[{"end":30.25},{"end":3}]}]}"#.utf8)
        let event = UsageMeter.event(request: request("https://api.elevenlabs.io/v1/speech-to-text"), status: 200, body: body, date: now)
        #expect(event?.provider == .elevenLabs)
        #expect(event?.audioSeconds == 30.25)
        #expect(event?.model == ScribeTranscriber.defaultModel)
    }

    @Test @MainActor func speechBillsTheTextSent() throws {
        let speech = SpeechRequest(text: "Hello there.", voiceID: "v1")
        let urlRequest = ElevenLabsProvider.buildRequest(speech, apiKey: "k", baseURL: URL(string: "https://api.elevenlabs.io")!,
                                                         model: "eleven_flash_v2_5")
        let event = try #require(UsageMeter.speechEvent(request: urlRequest, date: now))
        #expect(event.characters == 12)
        #expect(event.model == "eleven_flash_v2_5")
    }

    @Test func speechSocketCountsOnlySpokenText() {
        #expect(UsageMeter.speechSocketCharacters(#"{"text":" ","voice_settings":{}}"#) == 0)
        #expect(UsageMeter.speechSocketCharacters(#"{"text":"Fine. "}"#) == 6)
        #expect(UsageMeter.speechSocketCharacters(#"{"text":""}"#) == 0)
        var request = URLRequest(url: URL(string: "wss://api.elevenlabs.io/v1/text-to-speech/v/stream-input?model_id=eleven_turbo_v2_5")!)
        request.httpMethod = "GET"
        #expect(UsageMeter.speechSocketModel(request) == "eleven_turbo_v2_5")
    }

    @Test func streamTallyAddsUpAStreamedAnswer() {
        var tally = AnthropicStreamTally()
        tally.read(#"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":900,"output_tokens":1}}}"#)
        tally.read(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#)
        tally.read(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#)
        let event = tally.event(date: now)
        #expect(event?.model == "claude-sonnet-5-5")
        #expect(event?.inputTokens == 900)
        #expect(event?.outputTokens == 42)
        #expect(AnthropicStreamTally().event(date: now) == nil)
    }
}

@Suite("Usage pricing")
struct UsagePricingTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func pricesPerUnit() throws {
        let haiku = UsageEvent(provider: .anthropic, kind: .languageModel, model: "claude-haiku-5-5", date: now,
                               inputTokens: 100_000, outputTokens: 1_000_000)
        #expect(try #require(UsagePricing.cost(haiku)).isApproximately(0.51))
        let flash = UsageEvent(provider: .elevenLabs, kind: .textToSpeech, model: "eleven_flash_v2_5", date: now, characters: 10_000)
        #expect(try #require(UsagePricing.cost(flash)).isApproximately(0.50))
        let v3 = UsageEvent(provider: .elevenLabs, kind: .textToSpeech, model: "eleven_v3", date: now, characters: 10_000)
        #expect(try #require(UsagePricing.cost(v3)).isApproximately(1.00))
        let scribe = UsageEvent(provider: .elevenLabs, kind: .speechToText, model: "scribe_v2", date: now, audioSeconds: 3_600)
        #expect(try #require(UsagePricing.cost(scribe)).isApproximately(0.22))
    }

    @Test func whisperBillsAtLeastTenSeconds() throws {
        let short = UsageEvent(provider: .groq, kind: .speechToText, model: "whisper-large-v3", date: now, audioSeconds: 2)
        #expect(try #require(UsagePricing.cost(short)).isApproximately(10 / 3_600 * 0.111))
        let turbo = UsageEvent(provider: .groq, kind: .speechToText, model: "whisper-large-v3-turbo", date: now, audioSeconds: 3_600)
        #expect(try #require(UsagePricing.cost(turbo)).isApproximately(0.04))
    }

    @Test func haikuDoublesPastAHundredThousandInputTokens() throws {
        let long = UsageEvent(provider: .anthropic, kind: .languageModel, model: "claude-haiku-5-5", date: now,
                              inputTokens: 200_000, outputTokens: 0)
        #expect(try #require(UsagePricing.cost(long)).isApproximately(0.10))
    }

    @Test func unknownModelsAreNotPriced() {
        let event = UsageEvent(provider: .anthropic, kind: .languageModel, model: "claude-future-9", date: now, inputTokens: 10)
        #expect(UsagePricing.cost(event) == nil)
    }

    @Test func everyCuratedModelHasAPrice() {
        func priced(_ provider: UsageProvider, _ kind: UsageKind, _ model: String) -> Bool {
            UsagePricing.cost(UsageEvent(provider: provider, kind: kind, model: model, date: now, characters: 1, audioSeconds: 1,
                                         inputTokens: 1, outputTokens: 1)) != nil
        }
        for option in ModelOptions.voice { #expect(priced(.elevenLabs, .textToSpeech, option.id), "\(option.id)") }
        for option in ModelOptions.smartRead { #expect(priced(.anthropic, .languageModel, option.id), "\(option.id)") }
        for option in ModelOptions.transcription { #expect(priced(.groq, .speechToText, option.id), "\(option.id)") }
        for option in ModelOptions.cleanup where !option.id.isEmpty { #expect(priced(.groq, .languageModel, option.id), "\(option.id)") }
        #expect(priced(.elevenLabs, .speechToText, ScribeTranscriber.defaultModel))
    }
}

@Suite("UsageLog") @MainActor
struct UsageLogTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "vibeflow-usage-\(UUID().uuidString)")
    var file: URL { folder.appending(path: "usage.json") }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }
    /// 2026-11-05 12:00 in Berlin.
    var start: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))! }

    func speech(_ characters: Int, daysAgo: Int = 0, model: String = "eleven_flash_v2_5") -> UsageEvent {
        UsageEvent(provider: .elevenLabs, kind: .textToSpeech, model: model,
                   date: start.addingTimeInterval(-Double(daysAgo) * 86_400), characters: characters)
    }

    @Test func aggregatesPerDayAndModelAndReloads() {
        let start = self.start
        let log = UsageLog(fileURL: file, now: { start }, calendar: calendar)
        log.record(speech(1_000))
        log.record(speech(3_000))
        log.record(speech(2_000, model: "eleven_v3"))
        log.record(speech(500, daysAgo: 1))
        #expect(log.records.count == 3)
        let reloaded = UsageLog(fileURL: file, now: { start }, calendar: calendar)
        #expect(reloaded.records == log.records)
        let lines = reloaded.lines(in: reloaded.range(.month))
        // Most expensive first: 4,500 Flash characters ($0.225) before 2,000 v3 ($0.20).
        #expect(lines.map(\.model) == ["eleven_flash_v2_5", "eleven_v3"])
        #expect(lines[0].characters == 4_500)
        #expect(lines[0].requests == 3)
        #expect(reloaded.total(in: reloaded.range(.month)).isApproximately(0.425))
        #expect(reloaded.total(in: reloaded.range(.day)).isApproximately(0.40))
        #expect(reloaded.total(in: reloaded.range(.day, offset: -1)).isApproximately(0.025))
    }

    @Test func rangesFollowTheCalendar() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        let berlin = calendar
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { berlin.date(from: DateComponents(year: y, month: m, day: d))! }
        // Thursday 5 November 2026; weeks start on Monday here.
        #expect(log.range(.day).start == day(2026, 11, 5))
        #expect(log.range(.day, offset: -1).end == day(2026, 11, 5))
        #expect(log.range(.week).start == day(2026, 11, 2))
        #expect(log.range(.week).end == day(2026, 11, 9))
        #expect(log.range(.month, offset: -1).start == day(2026, 10, 1))
        #expect(log.range(.year).end == day(2027, 1, 1))
    }

    @Test func aClickedBarIsItsOwnRange() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        let yesterday = start.addingTimeInterval(-86_400)
        #expect(log.range(.day, containing: yesterday) == log.range(.day, offset: -1))
        #expect(log.range(.month, containing: start) == log.range(.month))
    }

    @Test func averageCountsOnlyTheBarsSoFar() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        log.record(speech(8_000)) // $0.40 on Thursday, the 4th day of a Monday week
        #expect(log.average(in: log.range(.week)).isApproximately(0.10))
        #expect(log.average(in: log.range(.week, offset: -1)) == 0)
        #expect(log.average(in: log.range(.year)).isApproximately(0.40 / 11))
    }

    @Test func goingBackStopsAtTheFirstUse() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        #expect(!log.hasUse(before: log.range(.month)))
        log.record(speech(10, daysAgo: 40))
        #expect(log.hasUse(before: log.range(.month)))
        #expect(!log.hasUse(before: log.range(.month, offset: -2)))
    }

    @Test func breakdownAndSeriesGroupTheRange() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        log.record(speech(4_000))                              // $0.20 read aloud, Flash, today
        log.record(speech(1_000, daysAgo: 1, model: "eleven_v3")) // $0.10 read aloud, v3, yesterday
        log.record(UsageEvent(provider: .anthropic, kind: .languageModel, model: "claude-sonnet-5-5", date: start,
                              inputTokens: 10_000, outputTokens: 1_000)) // $0.03
        let week = log.range(.week)
        #expect(log.groups(in: week, by: .feature).map(\.group) == ["Read aloud", "Smart Read, answers and summaries"])
        #expect(log.groups(in: week, by: .provider).map(\.group) == ["ElevenLabs", "Anthropic"])
        #expect(log.groups(in: week, by: .model).map(\.group) == ["Flash v2.5", "v3", "Claude Sonnet 5.5"])
        let series = log.series(in: week, by: .provider)
        #expect(series.count == 3)
        #expect(Set(series.map(\.date)).count == 2)
        #expect(log.groups(in: week, by: .feature)[0].lines.map(\.model) == ["eleven_flash_v2_5", "eleven_v3"])
        let yearly = log.series(in: log.range(.year), by: .provider)
        #expect(yearly.count == 2) // one November bucket per provider
    }

    @Test func unpricedRequestsAreCountedButCostNothing() {
        let start = self.start
        let log = UsageLog(fileURL: nil, now: { start }, calendar: calendar)
        log.record(speech(1_000, model: "eleven_future"))
        #expect(log.records[0].unpricedRequests == 1)
        #expect(log.total(in: log.range(.month)) == 0)
    }

    @Test func dropsDaysPastTheKeepWindow() {
        let start = self.start
        let log = UsageLog(fileURL: file, now: { start }, calendar: calendar)
        log.record(speech(10, daysAgo: UsageLog.keepDays + 5))
        log.record(speech(10))
        let later = UsageLog(fileURL: file, now: { start }, calendar: calendar)
        #expect(later.records.count == 1)
    }

    @Test func fileIsReadableByTheUserOnly() throws {
        let start = self.start
        let log = UsageLog(fileURL: file, now: { start }, calendar: calendar)
        log.record(speech(10))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite("Metered clients")
struct MeteredClientTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [UsageEvent] = []
        var events: [UsageEvent] { lock.withLock { _events } }
        var sink: @Sendable (UsageEvent) -> Void { { [self] e in lock.withLock { _events.append(e) } } }
    }

    @Test func httpClientRecordsAnthropicCalls() async throws {
        let fake = FakeHTTPClient()
        fake.body = Data(#"{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}"#.utf8)
        let recorder = Recorder()
        let client = AnthropicClient(http: MeteredHTTPClient(fake, record: recorder.sink), secrets: FakeSecrets([.anthropic: "k"]))
        _ = try await client.complete(system: "s", user: "u", model: "claude-opus-5-5", maxTokens: 10)
        #expect(recorder.events.map(\.outputTokens) == [5])
    }

    @Test func streamClientRecordsAStreamedAnswerAtTheEnd() async throws {
        let fake = FakeByteStreamClient()
        fake.lines = [
            #"data: {"type":"message_start","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":50,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Yes."}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
        ]
        let recorder = Recorder()
        let client = MeteredByteStreamClient(fake, record: recorder.sink)
        let response = try await client.stream(URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!))
        var count = 0
        for try await _ in response.lines { count += 1 }
        #expect(count == 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.events.map(\.inputTokens) == [50])
        #expect(recorder.events.map(\.outputTokens) == [7])
    }
}

extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 1e-9 }
}
