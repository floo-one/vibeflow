import Foundation

/// Summary and action items through Claude with the Smart Read model (file transcription D7).
/// One non-streaming request; the reply is JSON that names speakers and lines by id. The job
/// validates it against the transcript, so anything invented is dropped there.
public struct ClaudeTranscriptSummarizer: TranscriptSummarizer {
    /// A non-streaming reply to a 1 to 2 hour call (20 to 40k input tokens) sends no byte until
    /// it is complete, which can take well over smart read's 25 s.
    public static let timeout: TimeInterval = 120

    private let client: AnthropicClient
    private let model: @Sendable () -> String

    public init(client: AnthropicClient, model: @escaping @Sendable () -> String) {
        self.client = client
        self.model = model
    }

    public func summarize(_ transcript: Transcript) async throws -> Transcript.Summary {
        let response = try await client.complete(
            system: SmartReadPrompts.callSummarySystem(),
            user: SmartReadPrompts.callSummaryUser(transcript),
            model: model(), maxTokens: SmartReadPrompts.callSummaryMaxTokens, timeout: Self.timeout)
        guard response.stopReason != .maxTokens else { throw SmartReadFailure.other("the summary was cut off") }
        return try Self.parse(response.text)
    }

    /// Reads the JSON reply, tolerating a code fence or text around it. Owners may come back as
    /// "S1" or "{S1}"; both mean the same speaker.
    static func parse(_ text: String) throws -> Transcript.Summary {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(text[open...close].utf8)) else {
            throw SmartReadFailure.other("unreadable summary")
        }
        let items = (reply.action_items ?? []).map { item in
            Transcript.ActionItem(
                ownerID: item.owner.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")) }.flatMap { $0.isEmpty ? nil : $0 },
                text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                segmentID: item.line)
        }
        return Transcript.Summary(text: reply.summary.trimmingCharacters(in: .whitespacesAndNewlines), actionItems: items)
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let owner: String?
            let text: String
            let line: Int?
        }
        let summary: String
        let action_items: [Item]?
    }
}
