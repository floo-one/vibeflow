import Foundation
import Testing
@testable import MaagicalCore

@Suite("History with transcripts") @MainActor
struct HistoryTranscriptTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vf-history-\(UUID().uuidString)")
    var store: TranscriptStore { TranscriptStore(directory: directory.appendingPathComponent("Transcripts")) }
    var historyURL: URL { directory.appendingPathComponent("history.json") }
    let base = Date(timeIntervalSince1970: 1_793_780_000)

    func transcript(_ text: String, minutesAgo: Double = 0) -> Transcript {
        Transcript.make(from: [.init(speaker: "speaker_0", start: 0, end: 1, text: text)],
                        date: base.addingTimeInterval(-minutesAgo * 60), sourceFileName: "call.m4a", duration: 60, engine: .scribe)
    }

    func history(_ retention: HistoryRetention = .default, now: Date? = nil) -> HistoryStore {
        let now = now ?? base
        return HistoryStore(fileURL: historyURL, retention: retention, transcripts: store, now: { now })
    }

    @Test func retentionByCountNeverDropsTranscripts() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = history(.entries(2))
        h.upsertTranscript(transcript("Alter Anruf.", minutesAgo: 100))
        for i in 0..<5 { h.add(.read("Text \(i)", smart: false, from: nil, at: base.addingTimeInterval(Double(i)))) }
        #expect(h.entries.filter { $0.kind == .read }.map(\.text) == ["Text 4", "Text 3"])
        #expect(h.transcriptCount == 1, "the 101st read never deletes a meeting transcript")
    }

    @Test func retentionByDaysNeverDropsTranscripts() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = history(.days(7))
        h.upsertTranscript(transcript("Uralt.", minutesAgo: 60 * 24 * 30))
        h.add(.read("Alt", smart: false, from: nil, at: base.addingTimeInterval(-86_400 * 30)))
        h.add(.read("Neu", smart: false, from: nil, at: base))
        #expect(h.entries.map(\.text) == ["Neu", "Uralt."])
    }

    @Test func deletingAnEntryDeletesItsTranscript() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let t = transcript("Hallo.")
        try store.save(t)
        let h = history()
        h.upsertTranscript(t)
        h.delete(try #require(h.entries.first).id)
        #expect(store.storedIDs().isEmpty)
        #expect(h.entries.isEmpty)
    }

    @Test func clearKeepsTranscriptsUnlessAsked() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let t = transcript("Hallo.")
        try store.save(t)
        let h = history()
        h.upsertTranscript(t)
        h.add(.read("Gelesen", smart: false, from: nil, at: base))
        h.clear()
        #expect(h.entries.map(\.kind) == [.transcription])
        #expect(store.storedIDs() == [t.id])
        h.clear(includingTranscripts: true)
        #expect(h.entries.isEmpty)
        #expect(store.storedIDs().isEmpty)
    }

    @Test func savingTheSummaryUpdatesTheSameEntry() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = history()
        var t = transcript("Erste Fassung.")
        h.upsertTranscript(t)
        t.segments[0].text = "Zweite Fassung."
        h.upsertTranscript(t)
        #expect(h.entries.count == 1)
        #expect(h.entries[0].text == "Zweite Fassung.")
        #expect(h.entries[0].transcriptID == t.id)
        #expect(h.entries[0].sourceFileName == "call.m4a")
    }

    @Test func aTranscriptWithoutAnEntryIsAdoptedAtLaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = transcript("Gespeichert, dann beendet.", minutesAgo: 5)
        try store.save(saved)
        let h = history()
        h.add(.read("Neuer", smart: false, from: nil, at: base))
        h.adoptOrphanTranscripts()
        h.adoptOrphanTranscripts()   // twice: no duplicates
        #expect(h.entries.map(\.kind) == [.read, .transcription])
        #expect(h.entries[1].transcriptID == saved.id)
        #expect(history().entries.count == 2, "written to disk")
    }

    @Test func entriesFromANewerVersionAreSkippedNotFatal() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = try JSONEncoder().encode([HistoryEntry.read("Bleibt", smart: false, from: nil, at: base)])
        var list = try JSONSerialization.jsonObject(with: good) as! [[String: Any]]
        var future = list[0]
        future["id"] = UUID().uuidString
        future["kind"] = "hologram"
        list.append(future)
        try JSONSerialization.data(withJSONObject: list).write(to: historyURL)
        #expect(history().entries.map(\.text) == ["Bleibt"])
    }

    @Test func oldEntriesWithoutTheNewFieldsStillDecode() throws {
        let old = #"[{"id":"\#(UUID().uuidString)","kind":"read","date":0,"text":"Alt","smart":false}]"#
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(old.utf8))
        #expect(entries.first?.transcriptID == nil)
        #expect(entries.first?.sourceFileName == nil)
    }
}
