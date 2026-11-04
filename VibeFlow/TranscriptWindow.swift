import AppKit
import AVFoundation
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "file-transcription")

/// The Transcript window (file transcription D9, canvas board 4). Brought to the front
/// explicitly like History, since VibeFlow has no Dock icon.
@MainActor
enum TranscriptWindow {
    static let id = "transcript"

    static func present(_ openWindow: OpenWindowAction, container: AppContainer, transcript id: UUID) {
        container.files.openTranscriptID = id
        NSApp.activate()
        openWindow(id: Self.id)
        DispatchQueue.main.async { TranscribeFileWindow.bringToFront(id: Self.id) }
    }
}

/// Plays the source file through its bookmark (D9, O3). nil player: the file is gone.
@MainActor
@Observable
final class TranscriptPlayer {
    private(set) var isPlaying = false
    private(set) var unavailable = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var loadedFor: UUID?

    func load(_ transcript: Transcript) {
        guard loadedFor != transcript.id else { return }
        stop()
        loadedFor = transcript.id
        player = transcript.resolvedSource().flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.prepareToPlay()
        unavailable = player == nil
    }

    var currentTime: Double { player?.currentTime ?? 0 }

    func play(from seconds: Double? = nil) {
        guard let player else { return }
        if let seconds { player.currentTime = max(0, seconds) }
        player.play()
        isPlaying = true
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}

struct TranscriptView: View {
    @Environment(AppContainer.self) private var container
    @State private var transcript: Transcript?
    @State private var loadError: String?
    @State private var search = ""
    @State private var player = TranscriptPlayer()
    @State private var saveError: String?

    private static let palette: [Color] = [
        Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xD2 / 255), Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255),
        Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE0 / 255), Color(red: 0x0F / 255, green: 0x7B / 255, blue: 0x5F / 255),
        Color(red: 0xC0 / 255, green: 0x26 / 255, blue: 0x6D / 255), Color(red: 0x5A / 255, green: 0x64 / 255, blue: 0x78 / 255),
    ]

    var body: some View {
        Group {
            if let transcript {
                content(transcript)
            } else if let loadError {
                ContentUnavailableView("Transcript Not Found", systemImage: "doc.questionmark", description: Text(loadError))
            } else {
                ContentUnavailableView("No Transcript", systemImage: "waveform",
                                       description: Text("Open one from History or after a file is transcribed."))
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .task(id: LoadKey(id: container.files.openTranscriptID, revision: container.files.revision)) { load() }
        .onDisappear { player.stop() }
    }

    private func load() {
        guard let id = container.files.openTranscriptID else { return }
        do {
            let loaded = try container.files.store.load(id)
            transcript = loaded
            loadError = nil
            player.load(loaded)
        } catch {
            transcript = nil
            loadError = "It may have been deleted."
        }
    }

    // MARK: Layout

    private func content(_ t: Transcript) -> some View {
        VStack(spacing: 0) {
            if let note = t.completion.note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.15))
            }
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
            HStack(spacing: 0) {
                // Always shown: search is useful for memos too, speakers only appear for calls.
                sidebar(t)
                    .frame(width: 220)
                Divider()
                turns(t)
                if let summary = t.summary {
                    Divider()
                    summaryPanel(t, summary)
                        .frame(width: 280)
                }
            }
            Divider()
            timeline(t)
        }
        .navigationTitle(t.sourceFileName)
        .navigationSubtitle("\(t.date.formatted(date: .abbreviated, time: .shortened)) · \(Transcript.clock(t.duration)) · \(t.engine.displayName)")
        .toolbar {
            ToolbarItemGroup {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.toggle()
                }
                .disabled(player.unavailable)
                .help(player.unavailable ? "Source file not found" : "Play the recording")
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.plainText, forType: .string)
                }
                Button("Save as Text…", systemImage: "square.and.arrow.down") { saveAsText(t) }
            }
        }
    }

    private func sidebar(_ t: Transcript) -> some View {
        Form {
            if !t.speakers.isEmpty {
                Section("Speakers") {
                    ForEach(Array(t.talkShare.enumerated()), id: \.element.speaker.id) { index, item in
                        SpeakerRow(speaker: item.speaker, share: item.share, color: color(for: item.speaker.id, in: t),
                                   others: t.speakers.filter { $0.id != item.speaker.id },
                                   rename: { name in edit { $0.rename(item.speaker.id, to: name) } },
                                   merge: { target in edit { $0.merge(item.speaker.id, into: target) } })
                    }
                }
            }
            Section("Find") {
                TextField("Search transcript", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            if player.unavailable {
                Section {
                    Label("Source file not found", systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func turns(_ t: Transcript) -> some View {
        let all = t.turns
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(shown) { turn in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button(Transcript.clock(turn.start)) { player.play(from: turn.start) }
                            .buttonStyle(.plain)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                            .disabled(player.unavailable)
                            .help("Play from here")
                        VStack(alignment: .leading, spacing: 3) {
                            if let name = t.name(of: turn.speakerID) {
                                Text(name).font(.caption.weight(.semibold)).foregroundStyle(color(for: turn.speakerID, in: t))
                            }
                            Text(turn.text).textSelection(.enabled).lineSpacing(2)
                        }
                    }
                }
                if shown.isEmpty {
                    Text(query.isEmpty ? "Nothing was said in this file." : "No line contains “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryPanel(_ t: Transcript, _ summary: Transcript.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Summary").font(.headline)
                Text(t.rendered(summary.text)).textSelection(.enabled)
                if !summary.actionItems.isEmpty {
                    Divider()
                    Text("Action items").font(.headline)
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((t.name(of: item.ownerID).map { "\($0): " } ?? "") + t.rendered(item.text))
                                .textSelection(.enabled)
                            if let at = t.start(of: item.segmentID) {
                                Button(Transcript.clock(at)) { player.play(from: at) }
                                    .buttonStyle(.link)
                                    .font(.caption.monospacedDigit())
                                    .disabled(player.unavailable)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    private func timeline(_ t: Transcript) -> some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(Transcript.clock(player.currentTime)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                let duration = max(t.duration, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    ForEach(t.turns) { turn in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: turn.speakerID, in: t).opacity(0.85))
                            .frame(width: max(2, (turn.end - turn.start) / duration * geo.size.width))
                            .offset(x: turn.start / duration * geo.size.width)
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Rectangle().fill(.primary).frame(width: 2)
                            .offset(x: player.currentTime / duration * geo.size.width)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard !player.unavailable else { return }
                    player.play(from: location.x / geo.size.width * duration)
                }
            }
            .frame(height: 20)
            Text(Transcript.clock(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func color(for speakerID: String?, in t: Transcript) -> Color {
        guard let speakerID, let index = t.speakers.firstIndex(where: { $0.id == speakerID }) else { return .secondary }
        return Self.palette[index % Self.palette.count]
    }

    /// Renames and merges are saved at once (D9); History's row follows. The change goes onto
    /// the stored copy, so a summary saved since this window loaded is never overwritten.
    private func edit(_ change: (inout Transcript) -> Void) {
        guard let current = transcript else { return }
        var t = (try? container.files.store.load(current.id)) ?? current
        change(&t)
        do {
            try container.files.store.save(t)
            container.history.upsertTranscript(t)
            transcript = t
            saveError = nil
        } catch {
            saveError = "Not saved: \(error.localizedDescription)"
            log.notice("Transcript edit not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveAsText(_ t: Transcript) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (t.sourceFileName as NSString).deletingPathExtension + ".txt"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try t.plainText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveError = "Not saved: \(error.localizedDescription)"
        }
    }
}

private struct LoadKey: Equatable {
    var id: UUID?
    var revision: Int
}

private struct SpeakerRow: View {
    let speaker: Transcript.Speaker
    let share: Double
    let color: Color
    let others: [Transcript.Speaker]
    let rename: (String) -> Void
    let merge: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rename(name) }
                Menu {
                    ForEach(others) { other in
                        Button("Merge into \(other.name)") { merge(other.id) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(others.isEmpty)
                .help("Merge this speaker into another when one voice was split in two")
            }
            ProgressView(value: share) {
                Text("\(Int((share * 100).rounded())) % of the talking").font(.caption).foregroundStyle(.secondary)
            }
            .tint(color)
        }
        .onAppear { name = speaker.name }
        .onChange(of: speaker.name) { _, new in name = new }
    }
}
