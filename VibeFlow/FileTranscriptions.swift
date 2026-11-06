import AppKit
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "file-transcription")

/// The app side of file transcription (docs/designs/file-transcription.md): the open panel, the
/// options window, the running job, Keep Awake while it runs (eng review R3), the clipboard and
/// History. Engines are built from the current keys each time a file starts.
@MainActor
@Observable
final class FileTranscriptions {
    /// The file chosen in the open panel, waiting in the options window.
    struct Pending: Equatable {
        var url: URL
        var info: AudioFileInfo
    }

    let job: FileTranscriptionJob
    let store: TranscriptStore
    private(set) var pending: Pending?
    /// The transcript the Transcript window shows.
    var openTranscriptID: UUID?
    /// Goes up whenever the job saves a transcript, so an open window reloads (the summary
    /// arrives after the first save).
    private(set) var revision = 0
    /// "Couldn't read notes.m4a" from the open panel step, shown in the menu.
    private(set) var pickError: String?

    @ObservationIgnored private let secrets: any SecretsStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let awake: any PowerAssertion
    @ObservationIgnored private var copyWhenDone = true
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored var onFinished: ((FileTranscriptionJob.State) -> Void)?
    /// Asks for notification permission the first time a file starts (eng review D1).
    @ObservationIgnored var onStarted: (() -> Void)?

    init(secrets: any SecretsStore, preferences: Preferences, history: HistoryStore, store: TranscriptStore,
         http: any HTTPClient, awake: any PowerAssertion) {
        self.secrets = secrets
        self.preferences = preferences
        self.history = history
        self.store = store
        self.awake = awake
        job = FileTranscriptionJob(engines: {
            Self.engines(secrets: secrets, preferences: preferences, http: http)
        }, store: store)
        job.onSaved = { [weak self, history] in
            history.upsertTranscript($0)
            self?.revision += 1
        }
        job.onUpdated = { [weak self, history] in
            history.upsertTranscript($0)
            self?.revision += 1
        }
    }

    /// Built on the main actor when a file starts, so models are read from Preferences here and
    /// captured as values (the engines run off the main actor).
    static func engines(secrets: any SecretsStore, preferences: Preferences, http: any HTTPClient) -> FileTranscriptionJob.Engines {
        let groq = secrets.read(.groq) != nil
            ? OpenAITranscriber(http: http, model: preferences.transcriptionModel, timeout: OpenAITranscriber.fileTimeout,
                                apiKey: { secrets.read(.groq) })
            : nil
        let scribe = secrets.read(.elevenLabs) != nil
            ? ScribeTranscriber(http: http, apiKey: { secrets.read(.elevenLabs) })
            : nil
        let summaryModel = preferences.smartReadModel
        let summarizer = secrets.read(.anthropic) != nil
            ? ClaudeTranscriptSummarizer(client: AnthropicClient(http: http, secrets: secrets), model: { summaryModel },
                                         prompts: preferences.prompts)
            : nil
        return .init(pieces: groq, call: scribe, onDevice: AppleTranscriber.isAvailable ? AppleTranscriber() : nil,
                     summarizer: summarizer)
    }

    // MARK: Keys, for the options window

    var hasCallEngine: Bool { secrets.read(.elevenLabs) != nil }
    var hasMemoEngine: Bool { secrets.read(.groq) != nil || AppleTranscriber.isAvailable }
    var canSummarize: Bool { secrets.read(.anthropic) != nil }

    // MARK: Remembered choices (D1: one click the second time; O1: summary off by default)

    var lastKind: FileTranscriptionJob.Kind {
        get { FileTranscriptionJob.Kind(rawValue: UserDefaults.standard.string(forKey: "fileTranscription.kind") ?? "") ?? .call }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fileTranscription.kind") }
    }
    var lastSummarize: Bool {
        get { UserDefaults.standard.bool(forKey: "fileTranscription.summarize") }
        set { UserDefaults.standard.set(newValue, forKey: "fileTranscription.summarize") }
    }
    var lastCopy: Bool {
        get { UserDefaults.standard.object(forKey: "fileTranscription.copy") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fileTranscription.copy") }
    }

    // MARK: Flow

    /// Menu "Transcribe File…": the open panel, then the options window for the chosen file.
    func chooseFile(then openOptions: @escaping () -> Void) {
        guard !job.isRunning else { return }
        pickError = nil
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Transcribe File"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url, then: openOptions)
    }

    /// A file chosen in the open panel or dropped on the menu bar panel (D15): checked, then
    /// the options window opens for it.
    func use(_ url: URL, then openOptions: @escaping () -> Void) {
        guard !job.isRunning else { return }
        pickError = nil
        Task {
            do {
                let info = try await AudioFileDecoder.probe(url)
                guard info.duration <= AudioFileDecoder.maxDuration else {
                    throw AudioFileError.tooLong(seconds: info.duration)
                }
                pending = Pending(url: url, info: info)
                openOptions()
            } catch {
                pickError = FileTranscriptionJob.describe(error)
                log.notice("File refused: \(self.pickError ?? "", privacy: .public)")
            }
        }
    }

    func cancelPending() { pending = nil }

    /// The options window's Transcribe button.
    func start(kind: FileTranscriptionJob.Kind, speakers: Int?, multichannel: Bool, summarize: Bool, copy: Bool) {
        guard let pending else { return }
        lastKind = kind
        lastSummarize = summarize
        lastCopy = copy
        copyWhenDone = copy
        let request = FileTranscriptionJob.Request(
            file: pending.url, kind: kind,
            options: FileTranscriptionOptions(speakers: kind == .call ? speakers : nil, multichannel: kind == .call && multichannel),
            summarize: summarize && canSummarize)
        self.pending = nil
        guard job.start(request) else { return }
        onStarted?()
        if !awake.begin(keepsDisplayOn: false) { log.notice("Keep awake refused during file transcription") }
        watcher = Task { [weak self] in
            await self?.job.waitUntilDone()
            self?.ended()
        }
    }

    func stop() { job.cancel() }

    private func ended() {
        awake.end()
        if case .finished(let finished) = job.state, copyWhenDone {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finished.transcript.plainText, forType: .string)
        }
        onFinished?(job.state)
    }

    // MARK: Menu text

    /// The first menu row while a file runs or after it ended; nil when there is nothing to say.
    func statusLine(now: Date) -> String? {
        switch job.state {
        case .idle:
            return pickError
        case .running(let file, let phase, let startedAt, _):
            switch phase {
            case .preparing: return "Preparing \(file)…"
            case .transcribingWhole:
                return "Transcribing \(file) · \(Transcript.clock(now.timeIntervalSince(startedAt)))"
            case .transcribingPieces(let done, let total):
                return "Transcribing \(file) · \(Transcript.clock(done)) of \(Transcript.clock(total))"
            case .waitingForRateLimit(let seconds): return "Groq rate limit: waiting \(seconds) s"
            case .summarizing: return "Summarizing \(file)…"
            }
        case .finished(let f):
            let speakers = f.transcript.speakers.count
            var line = "Transcript ready: \(f.transcript.sourceFileName)"
            if speakers > 0 { line += " · \(speakers) speaker\(speakers == 1 ? "" : "s")" }
            return line
        case .failed(let file, let message):
            return "\(file): \(message)"
        }
    }

    /// Notes under the status line: fallback, partial, summary failure.
    var detailLines: [String] {
        switch job.state {
        case .running(_, _, _, let note): return note.map { [$0] } ?? []
        case .finished(let f):
            return [f.note, f.transcript.completion.note, f.summaryError].compactMap { $0 }
        default: return []
        }
    }

    /// "Stop Transcribing (keeps 18 min)" for Groq memos, which keep what is done (D6).
    var stopTitle: String {
        if case .running(_, .transcribingPieces(let done, _), _, _) = job.state, done >= 60 {
            return "Stop Transcribing (keeps \(Int(done / 60)) min)"
        }
        return "Stop Transcribing"
    }

    var finishedTranscriptID: UUID? {
        if case .finished(let f) = job.state { return f.transcript.id }
        return nil
    }
}

// MARK: - Options window

@MainActor
enum TranscribeFileWindow {
    static let id = "transcribe-file"

    static func present(_ openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
        DispatchQueue.main.async { bringToFront(id: id) }
    }

    static func bringToFront(id: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true }) else { return }
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// "Transcribe File": what the file is, speakers, channels, summary, clipboard, and which engine
/// will run (canvas board 2). Per file, not Settings; remembers the last choices.
struct TranscribeFileView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    @State private var kind: FileTranscriptionJob.Kind = .call
    @State private var speakers: Int = 0          // 0 = detect automatically
    @State private var multichannel = true
    @State private var summarize = false
    @State private var copy = true

    private var files: FileTranscriptions { container.files }

    var body: some View {
        Group {
            if let pending = files.pending {
                form(pending)
            } else {
                ContentUnavailableView("No File Chosen", systemImage: "waveform",
                                       description: Text("Use Transcribe File… in the Maagical menu."))
            }
        }
        // A grouped Form has no height of its own, so the window (sized to content) came out
        // small and scrolled; give it the height each layout needs.
        .frame(width: 480, height: height)
        .animation(.default, value: kind)
        .onAppear {
            kind = files.lastKind
            summarize = files.lastSummarize && files.canSummarize
            copy = files.lastCopy
        }
    }

    private func form(_ pending: FileTranscriptions.Pending) -> some View {
        Form {
            Section {
                LabeledContent {
                    Text("\(Transcript.clock(pending.info.duration))\(pending.info.hasVideo ? " · video" : "") · \(pending.info.channels == 2 ? "stereo" : "mono")")
                        .foregroundStyle(.secondary)
                } label: {
                    Label(pending.url.lastPathComponent, systemImage: pending.info.hasVideo ? "film" : "waveform")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Section {
                Picker("What is it?", selection: $kind) {
                    Text("Call or meeting").tag(FileTranscriptionJob.Kind.call)
                    Text("Voice memo or talk").tag(FileTranscriptionJob.Kind.memo)
                }
                .pickerStyle(.segmented)
                if kind == .call {
                    Picker("Speakers", selection: $speakers) {
                        Text("Detect automatically").tag(0)
                        ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                    if pending.info.channels == 2 {
                        Toggle(isOn: $multichannel) {
                            Text("Channels are speakers")
                            Text("Left is me, right is the other side.")
                        }
                    }
                }
            } footer: {
                Text(kind == .call ? "Labels who said what, with timestamps." : "One text with timestamps, no speaker labels.")
                    .foregroundStyle(.secondary)
            }
            Section("After transcribing") {
                Toggle(isOn: $summarize) {
                    Text("Summary and action items")
                    Text(files.canSummarize ? "Claude, with the Smart Read model" : "Needs an Anthropic key")
                }
                .disabled(!files.canSummarize)
                Toggle("Copy the transcript to the clipboard", isOn: $copy)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(engineLine(pending)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { close(cancel: true) }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe") {
                    files.start(kind: kind, speakers: speakers == 0 ? nil : speakers, multichannel: multichannel,
                                summarize: summarize, copy: copy)
                    close(cancel: false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!files.hasMemoEngine && !(kind == .call && files.hasCallEngine))
            }
            .padding()
        }
    }

    private var height: CGFloat {
        guard let pending = files.pending else { return 300 }
        switch kind {
        case .memo: return 430
        case .call: return pending.info.channels == 2 ? 560 : 500
        }
    }

    private func engineLine(_ pending: FileTranscriptions.Pending) -> String {
        if kind == .call {
            guard files.hasCallEngine else { return "No ElevenLabs key: no speaker labels" }
            return multichannel && pending.info.channels == 2 ? "ElevenLabs Scribe · Me and Other" : "ElevenLabs Scribe · speaker labels"
        }
        return files.hasMemoEngine ? "Groq Whisper, on device if offline" : "Add a Groq key in Settings > Accounts"
    }

    private func close(cancel: Bool) {
        if cancel { files.cancelPending() }
        dismissWindow(id: TranscribeFileWindow.id)
    }
}
