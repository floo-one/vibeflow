import Foundation

/// ElevenLabs Scribe for calls and meetings (file transcription D3, chosen in the T1 bake-off):
/// one upload of the file's audio, speaker labels and word times back.
///
/// The multipart body is written to a temporary file and uploaded from disk, and videos send
/// only their audio track, so a two-hour recording never sits in memory (eng review R6).
public final class ScribeTranscriber: FileTranscriber {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public static let defaultModel = "scribe_v2"
    /// Idle time between bytes. T1: 36 minutes took 25 s in total; long files take longer to
    /// process before the first response byte.
    public static let timeout: TimeInterval = 600
    /// Shown when the key exists but is scoped without Speech to Text (seen in T1).
    public static let missingPermissionMessage = "Your ElevenLabs key lacks the Speech to Text permission. Turn it on for this key at elevenlabs.io, or use a new key."

    private let http: any HTTPClient
    private let model: String
    private let apiKey: @Sendable () -> String?
    private let temporaryDirectory: URL

    public init(http: any HTTPClient, model: String = ScribeTranscriber.defaultModel,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                apiKey: @escaping @Sendable () -> String?) {
        self.http = http
        self.model = model
        self.temporaryDirectory = temporaryDirectory
        self.apiKey = apiKey
    }

    public func transcribe(file: URL, options: FileTranscriptionOptions) async throws -> [SpeakerSegment] {
        guard let key = apiKey() else { throw TranscriptionFailure.unauthorized }
        let info = try await AudioFileDecoder.probe(file)
        guard info.duration <= AudioFileDecoder.maxDuration else { throw AudioFileError.tooLong(seconds: info.duration) }

        let audio = try await AudioFileDecoder.audioOnly(file, info: info, directory: temporaryDirectory)
        defer { if audio != file { try? FileManager.default.removeItem(at: audio) } }

        let boundary = "vibeflow-\(UUID().uuidString)"
        let body = try Self.writeMultipart(fields: Self.fields(model: model, options: options, channels: info.channels),
                                           audio: audio, boundary: boundary, directory: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let response: HTTPResponse
        do {
            response = try await http.upload(request, fromFile: body)
        } catch let error as URLError {
            throw error.code == .timedOut ? TranscriptionFailure.timeout : TranscriptionFailure.offline
        }
        switch response.status {
        case 200:
            return try Self.segments(from: response.body, multichannel: options.multichannel && info.channels >= 2)
        case 401, 403:
            if Self.isMissingPermission(response.body) {
                throw TranscriptionFailure.rejected(status: response.status, message: Self.missingPermissionMessage)
            }
            throw TranscriptionFailure.unauthorized
        case 429:
            throw TranscriptionFailure.rateLimited
        case 500...599:
            throw TranscriptionFailure.serverError(response.status)
        default:
            throw TranscriptionFailure.rejected(status: response.status, message: Self.message(from: response.body))
        }
    }

    // MARK: Request

    static func fields(model: String, options: FileTranscriptionOptions, channels: Int) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model_id", model), ("diarize", "true"), ("timestamps_granularity", "word"), ("tag_audio_events", "false"),
        ]
        if let speakers = options.speakers { fields.append(("num_speakers", String(speakers))) }
        if let language = options.language.flatMap(OpenAITranscriber.isoLanguage) { fields.append(("language_code", language)) }
        if options.multichannel && channels >= 2 { fields.append(("use_multi_channel", "true")) }
        return fields
    }

    /// Writes the multipart body to a temporary file, copying the audio in 1 MB blocks.
    static func writeMultipart(fields: [(String, String)], audio: URL, boundary: String, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(AudioFileDecoder.tempPrefix)\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            for (name, value) in fields {
                try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: \(mimeType(audio))\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: audio)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AudioFileError.unreadable(audio.lastPathComponent)
        }
        return url
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "m4v", "mov": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "ogg", "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    // MARK: Response

    /// Words (and the spacing between them) in time order, grouped into one segment per run of
    /// the same speaker. Multichannel responses may come as one transcript per channel; their
    /// speakers are "channel_<n>".
    static func segments(from body: Data, multichannel: Bool) throws -> [SpeakerSegment] {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body) else { throw TranscriptionFailure.malformed }
        let transcripts = decoded.transcripts ?? [Response.Transcript(words: decoded.words, channel_index: decoded.channel_index)]

        struct Word { var start: Double; var end: Double; var speaker: String?; var text: String; var spacing: Bool }
        var words: [Word] = []
        for (index, transcript) in transcripts.enumerated() {
            for w in transcript.words ?? [] {
                let channel = w.channel_index ?? transcript.channel_index ?? index
                let speaker = multichannel ? "channel_\(channel)" : w.speaker_id
                words.append(Word(start: w.start ?? 0, end: w.end ?? w.start ?? 0, speaker: speaker,
                                  text: w.text ?? "", spacing: w.type == "spacing"))
            }
        }
        // Stable sort keeps a channel's spacing right after its word when times tie.
        words = words.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)

        var segments: [SpeakerSegment] = []
        for word in words {
            if word.spacing {
                if !segments.isEmpty { segments[segments.count - 1].text += word.text }
                continue
            }
            if let last = segments.last, last.speaker == word.speaker {
                let joiner = last.text.hasSuffix(" ") || word.text.hasPrefix(" ") ? "" : " "
                segments[segments.count - 1].text += joiner + word.text
                segments[segments.count - 1].end = word.end
            } else {
                segments.append(SpeakerSegment(speaker: word.speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return segments.compactMap { segment in
            var s = segment
            s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.text.isEmpty ? nil : s
        }
    }

    static func isMissingPermission(_ body: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(ErrorBody.self, from: body) else { return false }
        return error.detail?.status == "missing_permissions" || (error.detail?.message ?? "").contains("speech_to_text")
    }

    static func message(from body: Data) -> String {
        if let error = try? JSONDecoder().decode(ErrorBody.self, from: body), let m = error.detail?.message { return m }
        return String(decoding: body.prefix(200), as: UTF8.self)
    }

    private struct Response: Decodable {
        struct Word: Decodable {
            let text: String?
            let start: Double?
            let end: Double?
            let type: String?
            let speaker_id: String?
            let channel_index: Int?
        }
        struct Transcript: Decodable {
            let words: [Word]?
            let channel_index: Int?
        }
        let words: [Word]?
        let channel_index: Int?
        let transcripts: [Transcript]?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let status: String?; let message: String? }
        let detail: Detail?
    }
}
