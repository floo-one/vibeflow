import Foundation
import Testing
@testable import VibeFlowCore

@Suite("HistoryStore") @MainActor
struct HistoryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "vibeflow-history-\(UUID().uuidString)")
    var file: URL { folder.appending(path: "history.json") }
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func entry(_ text: String, minutesAgo: Double = 0) -> HistoryEntry {
        .read(text, smart: false, from: "com.apple.Safari", at: start.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func savesAndReloadsNewestFirst() throws {
        let store = HistoryStore(fileURL: file, now: { start })
        store.add(entry("older", minutesAgo: 5))
        store.add(.question("Which option?", answer: "Option B.", about: "Long AI answer", from: "com.openai.chat", at: start))
        let reloaded = HistoryStore(fileURL: file, now: { start })
        #expect(reloaded.entries.map(\.text) == ["Option B.", "older"])
        #expect(reloaded.entries[0].question == "Which option?")
        #expect(reloaded.entries[0].documentExcerpt == "Long AI answer")
        #expect(reloaded.entries == store.entries)
    }

    @Test func fileIsReadableByTheUserOnly() throws {
        let store = HistoryStore(fileURL: file, now: { start })
        store.add(entry("private"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func deleteAndClear() {
        let store = HistoryStore(fileURL: file, now: { start })
        store.add(entry("a"))
        store.add(entry("b"))
        store.delete(store.entries[0].id)
        #expect(store.entries.map(\.text) == ["a"])
        #expect(HistoryStore(fileURL: file, now: { start }).entries.map(\.text) == ["a"])
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(HistoryStore(fileURL: file, now: { start }).entries.isEmpty)
    }

    @Test func entryLimitDropsTheOldest() {
        let store = HistoryStore(fileURL: file, retention: .entries(3), now: { start })
        for i in 0..<5 { store.add(entry("e\(i)", minutesAgo: Double(5 - i))) }
        #expect(store.entries.map(\.text) == ["e4", "e3", "e2"])
    }

    @Test func dayLimitDropsOldEntriesIncludingOnLoadAndWhenTightened() {
        let store = HistoryStore(fileURL: file, retention: .days(30), now: { start })
        store.add(entry("today"))
        store.add(entry("ten days", minutesAgo: 10 * 24 * 60))
        store.add(entry("forty days", minutesAgo: 40 * 24 * 60))
        #expect(store.entries.map(\.text) == ["today", "ten days"])

        store.retention = .days(7)
        #expect(store.entries.map(\.text) == ["today"])

        let later = HistoryStore(fileURL: file, retention: .days(7), now: { start.addingTimeInterval(8 * 86_400) })
        #expect(later.entries.isEmpty, "pruned when loaded a week later")
    }

    @Test func unreadableFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = HistoryStore(fileURL: file, now: { start })
        #expect(store.entries.isEmpty)
        store.add(entry("fresh"))
        #expect(HistoryStore(fileURL: file, now: { start }).entries.map(\.text) == ["fresh"])
    }

    @Test func retentionRoundTripsThroughDefaults() {
        for choice in HistoryRetention.choices {
            #expect(HistoryRetention(storageValue: choice.storageValue) == choice)
        }
        #expect(HistoryRetention(storageValue: "weeks:2") == nil)
        #expect(HistoryRetention(storageValue: "days:0") == nil)
    }
}
