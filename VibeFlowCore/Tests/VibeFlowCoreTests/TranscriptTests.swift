import Foundation
import Testing
@testable import VibeFlowCore

private let date = Date(timeIntervalSince1970: 1_793_780_000)

private func call(_ segments: [(String?, Double, Double, String)], completion: Transcript.Completion = .complete) -> Transcript {
    Transcript.make(from: segments.map { SpeakerSegment(speaker: $0.0, start: $0.1, end: $0.2, text: $0.3) },
                    date: date, sourceFileName: "sales-call.m4a", duration: 2_530, engine: .scribe, completion: completion)
}

@Suite("Transcript")
struct TranscriptTests {
    let sample = call([
        ("speaker_0", 4, 5.5, "Hallo Frau Stürmer."),
        ("speaker_1", 6, 7, "Hallo."),
        ("speaker_0", 10, 12, "Hören Sie mich?"),
        ("speaker_0", 12.5, 14, "Passt alles?"),
        ("speaker_10", 15, 16, "Ich bin auch da."),
    ])

    @Test func engineSpeakersBecomeStableIdsInOrderOfFirstAppearance() {
        #expect(sample.speakers == [
            .init(id: "S1", name: "Speaker 1"), .init(id: "S2", name: "Speaker 2"), .init(id: "S3", name: "Speaker 3"),
        ])
        #expect(sample.segments.map(\.speakerID) == ["S1", "S2", "S1", "S1", "S3"])
    }

    @Test func multichannelBecomesMeAndOther() {
        let t = call([("channel_1", 1, 2, "Hallo?"), ("channel_0", 2, 3, "Ja, hallo.")])
        #expect(t.speakers == [.init(id: "OTHER", name: "Other"), .init(id: "ME", name: "Me")])
    }

    @Test func turnsJoinOneSpeakerAndSplitOnSpeakerOrPause() {
        #expect(sample.turns.map(\.text) == ["Hallo Frau Stürmer.", "Hallo.", "Hören Sie mich? Passt alles?", "Ich bin auch da."])
        #expect(sample.turns[2].segmentIDs == [2, 3])
        let paused = call([("speaker_0", 0, 2, "Erstens."), ("speaker_0", 5, 6, "Zweitens.")])
        #expect(paused.turns.count == 2, "a 3-second pause starts a new turn")
    }

    @Test func memosWithoutSpeakersBreakIntoParagraphs() {
        let memo = call((0..<30).map { (nil, Double($0) * 3, Double($0) * 3 + 2.9, "Satz \($0).") })
        let turns = memo.turns
        #expect(turns.count > 1)
        #expect(turns.allSatisfy { $0.end - $0.start <= Transcript.paragraphLength + 3 })
        #expect(turns.flatMap(\.segmentIDs) == Array(0..<30))
    }

    @Test func renameChangesEveryTurnAndTheSummaryButNoText() {
        var t = sample
        t.summary = Transcript.Summary(text: "{S1} and {S2} agree. {S3} listens.",
                                       actionItems: [.init(ownerID: "S1", text: "Send the timeline", segmentID: 2)])
        t.rename("S1", to: "  Florian ")
        #expect(t.name(of: "S1") == "Florian")
        #expect(t.rendered(t.summary!.text) == "Florian and Speaker 2 agree. Speaker 3 listens.")
        #expect(t.summary!.text == "{S1} and {S2} agree. {S3} listens.", "stored text keeps tokens")
        t.rename("S1", to: "   ")
        #expect(t.name(of: "S1") == "Florian", "an empty name is ignored")
    }

    @Test func renamingSpeakerOneNeverTouchesSpeakerTen() {
        // The string-replacement bug the review found: "Speaker 1" inside "Speaker 10".
        var t = call((1...10).map { ("speaker_\($0)", Double($0), Double($0) + 0.5, "Hi.") })
        t.summary = Transcript.Summary(text: "{S1} met {S10}.", actionItems: [])
        t.rename("S1", to: "Anna")
        #expect(t.rendered(t.summary!.text) == "Anna met Speaker 10.")
    }

    @Test func mergeMovesSegmentsItemsAndTokens() {
        var t = sample
        t.summary = Transcript.Summary(text: "{S3} said little.", actionItems: [.init(ownerID: "S3", text: "Call back", segmentID: 4)])
        t.merge("S3", into: "S1")
        #expect(t.speakers.map(\.id) == ["S1", "S2"])
        #expect(t.segments[4].speakerID == "S1")
        #expect(t.summary == Transcript.Summary(text: "{S1} said little.", actionItems: [.init(ownerID: "S1", text: "Call back", segmentID: 4)]))
        let before = t
        t.merge("S2", into: "nobody")
        #expect(t == before, "merging into an unknown speaker does nothing")
    }

    @Test func validationDropsWhatDoesNotExist() {
        let summary = Transcript.Summary(text: "{S1} asks {S9} about {budget}.", actionItems: [
            .init(ownerID: "S2", text: "Confirm the budget", segmentID: 1),
            .init(ownerID: "S7", text: "Invented owner", segmentID: 99),
            .init(ownerID: nil, text: "  ", segmentID: nil),
        ])
        let valid = sample.validated(summary)
        #expect(valid.text == "{S1} asks someone about someone.")
        #expect(valid.actionItems == [
            .init(ownerID: "S2", text: "Confirm the budget", segmentID: 1),
            .init(ownerID: nil, text: "Invented owner", segmentID: nil),
        ])
    }

    @Test func plainTextHasHeaderSummaryAndTurns() {
        var t = sample
        t.rename("S1", to: "Florian")
        t.summary = Transcript.Summary(text: "{S1} checks the line.", actionItems: [.init(ownerID: "S1", text: "Send the timeline", segmentID: 2)])
        #expect(t.plainText == """
        sales-call.m4a · 42:10 · ElevenLabs Scribe

        Summary
        Florian checks the line.

        Action items
        - Florian: Send the timeline [00:10]

        Transcript
        Florian [00:04]: Hallo Frau Stürmer.
        Speaker 2 [00:06]: Hallo.
        Florian [00:10]: Hören Sie mich? Passt alles?
        Speaker 3 [00:15]: Ich bin auch da.

        """)
    }

    @Test func partialTranscriptsSaySoEverywhere() {
        let stopped = call([(nil, 0, 1, "Hallo.")], completion: .stopped(at: 1_800, reason: "Groq hourly limit"))
        #expect(stopped.completion.note == "Stopped at 30:00: Groq hourly limit")
        #expect(stopped.plainText.contains("Stopped at 30:00: Groq hourly limit"))
        #expect(stopped.plainText.contains("[00:00] Hallo."), "turns without a speaker have no name")
        #expect(Transcript.Completion.cancelled(at: 3_725).note == "Cancelled at 1:02:05")
        #expect(Transcript.Completion.complete.note == nil)
    }

    @Test func talkShareAddsUpToOne() {
        let shares = sample.talkShare
        #expect(shares.map(\.speaker.id) == ["S1", "S2", "S3"])
        #expect(abs(shares.map(\.share).reduce(0, +) - 1) < 0.0001)
    }

    @Test func excerptIsAtMostTwoHundredCharacters() {
        let long = call([(nil, 0, 1, String(repeating: "Wort ", count: 100))])
        #expect(long.excerpt.count == HistoryEntry.excerptLength)
        #expect(sample.excerpt.hasPrefix("Hallo Frau Stürmer. Hallo."))
    }
}

@Suite("TranscriptStore")
struct TranscriptStoreTests {
    let store = TranscriptStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("vf-transcripts-\(UUID().uuidString)"))

    @Test func roundTripsEveryField() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var t = call([("speaker_0", 0, 1, "Hallo."), ("speaker_1", 1, 2, "Hi.")],
                     completion: .stopped(at: 30, reason: "Groq hourly limit"))
        t.sourceBookmark = Data([1, 2, 3])
        t.language = "de"
        t.summary = Transcript.Summary(text: "{S1} greets.", actionItems: [.init(ownerID: "S2", text: "Reply", segmentID: 1)])
        try store.save(t)
        #expect(try store.load(t.id) == t)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: t.id).path)
        #expect(attributes[.posixPermissions] as? Int == 0o600, "transcripts of calls are private")
    }

    @Test func listsAndDeletes() throws {
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let a = call([(nil, 0, 1, "A.")]), b = call([(nil, 0, 1, "B.")])
        try store.save(a)
        try store.save(b)
        try Data("junk".utf8).write(to: store.directory.appendingPathComponent("notes.txt"))
        #expect(Set(store.storedIDs()) == [a.id, b.id])
        try store.delete(a.id)
        try store.delete(a.id)   // already gone: not an error
        #expect(store.storedIDs() == [b.id])
    }

    @Test func aMissingTranscriptThrows() {
        #expect(throws: (any Error).self) { try store.load(UUID()) }
    }

    @Test func aMovedSourceIsFoundAndADeletedOneIsNot() throws {
        let folder = store.directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let file = folder.appendingPathComponent("call.m4a")
        try Data("audio".utf8).write(to: file)
        var t = call([(nil, 0, 1, "Hallo.")])
        t.sourceBookmark = Transcript.bookmark(for: file)
        let moved = folder.appendingPathComponent("renamed.m4a")
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(t.resolvedSource()?.lastPathComponent == "renamed.m4a")
        try FileManager.default.removeItem(at: moved)
        #expect(t.resolvedSource() == nil)
    }
}
