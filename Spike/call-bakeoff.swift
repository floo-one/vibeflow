// VibeFlow file transcription T1: call engine bake-off (docs/designs/file-transcription.md, D11).
//
// Sends one recorded call to ElevenLabs Scribe and Deepgram with speaker labels on, and writes
// both results side by side so you can judge who-said-what and text quality on a real call.
// Also records what the design needs to know: upload size, total time, speaker count, and
// whether the multichannel mode works on a stereo recording.
//
// Usage (Command Line Tools are enough):
//   swift Spike/call-bakeoff.swift <file> [--engines scribe,deepgram] [--language de]
//        [--speakers 2] [--multichannel] [--out build/bakeoff]
//        [--scribe-model scribe_v2] [--deepgram-model nova-3]
//
// Keys: ELEVENLABS_API_KEY and DEEPGRAM_API_KEY from the environment, or from ./.env
// (gitignored) as KEY=value lines. Never pass a key on the command line.
//
// Videos: the audio track is exported to a temporary m4a first and that is uploaded (eng review
// R6). Every upload streams from a file on disk, never from memory.
//
// Output in --out: <engine>.json (raw response), <engine>.md (turns "[mm:ss] Speaker: text"),
// summary.md (sizes, times, speakers, talk share). Nothing else is written or sent anywhere.

import AVFoundation
import Foundation

// MARK: - Options

struct Options {
    var file: URL
    var engines = ["scribe", "deepgram"]
    var language: String?
    var speakers: Int?
    var multichannel = false
    var out = URL(fileURLWithPath: "build/bakeoff")
    var scribeModel = "scribe_v2"
    var deepgramModel = "nova-3"

    init(_ args: [String]) throws {
        var positional: [String] = []
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw SpikeError.usage("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--engines": engines = try value().split(separator: ",").map { String($0) }
            case "--language": language = try value()
            case "--speakers":
                guard let n = Int(try value()), (1...32).contains(n) else { throw SpikeError.usage("--speakers takes 1 to 32") }
                speakers = n
            case "--multichannel": multichannel = true
            case "--out": out = URL(fileURLWithPath: try value())
            case "--scribe-model": scribeModel = try value()
            case "--deepgram-model": deepgramModel = try value()
            case "-h", "--help": throw SpikeError.usage("")
            default: positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 1 else { throw SpikeError.usage("give exactly one audio or video file") }
        file = URL(fileURLWithPath: positional[0])
        for e in engines where !["scribe", "deepgram"].contains(e) { throw SpikeError.usage("unknown engine \(e)") }
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case usage(String), noKey(String), http(Int, String), noAudio, export(String), shape(String)
    var description: String {
        switch self {
        case .usage(let m):
            return (m.isEmpty ? "" : m + "\n") +
                "usage: swift Spike/call-bakeoff.swift <file> [--engines scribe,deepgram] [--language de] [--speakers 2] [--multichannel] [--out build/bakeoff] [--scribe-model scribe_v2] [--deepgram-model nova-3]"
        case .noKey(let name): return "no API key: set \(name) or put \(name)=... in ./.env"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
        case .noAudio: return "the file has no audio track"
        case .export(let m): return "audio export failed: \(m)"
        case .shape(let m): return "unexpected response: \(m)"
        }
    }
}

func loadKey(_ name: String) throws -> String {
    if let k = ProcessInfo.processInfo.environment[name], !k.isEmpty { return k }
    if let env = try? String(contentsOfFile: ".env", encoding: .utf8) {
        for line in env.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(name + "=") else { continue }
            let v = t.dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !v.isEmpty { return v }
        }
    }
    throw SpikeError.noKey(name)
}

// MARK: - Probe and audio export

struct Probe {
    var duration: Double
    var channels: Int
    var hasVideo: Bool
    var bytes: Int64
}

func probe(_ url: URL) async throws -> Probe {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let audio = try await asset.loadTracks(withMediaType: .audio)
    guard let track = audio.first else { throw SpikeError.noAudio }
    var channels = 0
    for desc in try await track.load(.formatDescriptions) {
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            channels = max(channels, Int(asbd.mChannelsPerFrame))
        }
    }
    let video = try await asset.loadTracks(withMediaType: .video)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    return Probe(duration: duration, channels: channels, hasVideo: !video.isEmpty, bytes: bytes)
}

/// Videos only: the audio track as a temporary m4a (design R6).
func exportAudio(_ url: URL) async throws -> URL {
    let asset = AVURLAsset(url: url)
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw SpikeError.export("no export session for this file")
    }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("vibeflow-bakeoff-\(UUID().uuidString).m4a")
    try await session.export(to: target, as: .m4a)
    return target
}

func mimeType(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "m4a", "mp4", "m4v": return "audio/mp4"
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

// MARK: - HTTP (uploads stream from disk)

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 600     // idle time between bytes; long calls take a while
    c.timeoutIntervalForResource = 3600
    return URLSession(configuration: c)
}()

func upload(_ request: URLRequest, file: URL) async throws -> Data {
    let (data, response) = try await session.upload(for: request, fromFile: file)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw SpikeError.http(status, String(decoding: data, as: UTF8.self)) }
    return data
}

/// Writes a multipart body to a temporary file, copying the audio in 1 MB blocks.
func multipartFile(fields: [(String, String)], fileField: String, audio: URL, boundary: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibeflow-bakeoff-\(UUID().uuidString).body")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let out = try FileHandle(forWritingTo: url)
    defer { try? out.close() }
    for (name, value) in fields {
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: \(mimeType(audio))\r\n\r\n".utf8))
    let input = try FileHandle(forReadingFrom: audio)
    defer { try? input.close() }
    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
    try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    return url
}

// MARK: - Turns

struct Turn {
    var start: Double
    var speaker: String
    var text: String
}

func clock(_ s: Double) -> String {
    let t = Int(s.rounded(.down))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
}

/// Scribe: words (with spacing entries) carry speaker_id and, in multichannel mode, channel_index.
func scribeTurns(_ json: Any, multichannel: Bool) throws -> [Turn] {
    guard let root = json as? [String: Any] else { throw SpikeError.shape("Scribe root is not an object") }
    // Multichannel responses may come as one transcript per channel.
    let transcripts: [[String: Any]] = (root["transcripts"] as? [[String: Any]]) ?? [root]
    var words: [(start: Double, speaker: String, text: String, type: String)] = []
    for (index, t) in transcripts.enumerated() {
        for w in (t["words"] as? [[String: Any]]) ?? [] {
            let channel = (w["channel_index"] as? Int) ?? (t["channel_index"] as? Int) ?? index
            let speaker = multichannel ? (channel == 0 ? "Me (ch 0)" : "Other (ch \(channel))") : ((w["speaker_id"] as? String) ?? "speaker_?")
            words.append(((w["start"] as? Double) ?? 0, speaker, (w["text"] as? String) ?? "", (w["type"] as? String) ?? "word"))
        }
    }
    words.sort { $0.start < $1.start }
    var turns: [Turn] = []
    for w in words {
        if w.type == "spacing" { if !turns.isEmpty { turns[turns.count - 1].text += w.text }; continue }
        if let last = turns.last, last.speaker == w.speaker {
            turns[turns.count - 1].text += (last.text.hasSuffix(" ") || w.text.hasPrefix(" ") ? "" : " ") + w.text
        } else {
            turns.append(Turn(start: w.start, speaker: w.speaker, text: w.text))
        }
    }
    return turns.map { Turn(start: $0.start, speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespaces)) }
}

/// Deepgram: utterances carry speaker and channel.
func deepgramTurns(_ json: Any, multichannel: Bool) throws -> [Turn] {
    guard let root = json as? [String: Any], let results = root["results"] as? [String: Any] else {
        throw SpikeError.shape("Deepgram response has no results")
    }
    var turns: [Turn] = []
    for u in (results["utterances"] as? [[String: Any]]) ?? [] {
        let channel = (u["channel"] as? Int) ?? 0
        let speaker = multichannel ? (channel == 0 ? "Me (ch 0)" : "Other (ch \(channel))") : "speaker_\((u["speaker"] as? Int) ?? -1)"
        let text = (u["transcript"] as? String) ?? ""
        let start = (u["start"] as? Double) ?? 0
        if let last = turns.last, last.speaker == speaker {
            turns[turns.count - 1].text += " " + text
        } else {
            turns.append(Turn(start: start, speaker: speaker, text: text))
        }
    }
    return turns.sorted { $0.start < $1.start }
}

// MARK: - Engines

struct Result {
    var engine: String
    var seconds: Double
    var uploadBytes: Int64
    var turns: [Turn]
    var raw: Data
}

func runScribe(_ o: Options, audio: URL, multichannel: Bool) async throws -> Result {
    let key = try loadKey("ELEVENLABS_API_KEY")
    let boundary = "vibeflow-\(UUID().uuidString)"
    var fields: [(String, String)] = [("model_id", o.scribeModel), ("diarize", "true"), ("timestamps_granularity", "word"), ("tag_audio_events", "false")]
    if let n = o.speakers { fields.append(("num_speakers", String(n))) }
    if let l = o.language { fields.append(("language_code", l)) }
    if multichannel { fields.append(("use_multi_channel", "true")) }
    let body = try multipartFile(fields: fields, fileField: "file", audio: audio, boundary: boundary)
    defer { try? FileManager.default.removeItem(at: body) }
    var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
    request.httpMethod = "POST"
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let size = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? Int64) ?? 0
    let t0 = Date()
    let data = try await upload(request, file: body)
    let seconds = Date().timeIntervalSince(t0)
    let turns = try scribeTurns(try JSONSerialization.jsonObject(with: data), multichannel: multichannel)
    return Result(engine: "scribe", seconds: seconds, uploadBytes: size, turns: turns, raw: data)
}

func runDeepgram(_ o: Options, audio: URL, multichannel: Bool) async throws -> Result {
    let key = try loadKey("DEEPGRAM_API_KEY")
    var c = URLComponents(string: "https://api.deepgram.com/v1/listen")!
    var q = [URLQueryItem(name: "model", value: o.deepgramModel), URLQueryItem(name: "diarize", value: "true"),
             URLQueryItem(name: "utterances", value: "true"), URLQueryItem(name: "smart_format", value: "true"),
             URLQueryItem(name: "punctuate", value: "true")]
    q.append(o.language.map { URLQueryItem(name: "language", value: $0) } ?? URLQueryItem(name: "detect_language", value: "true"))
    if multichannel { q.append(URLQueryItem(name: "multichannel", value: "true")) }
    c.queryItems = q
    var request = URLRequest(url: c.url!)
    request.httpMethod = "POST"
    request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    request.setValue(mimeType(audio), forHTTPHeaderField: "Content-Type")
    let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int64) ?? 0
    let t0 = Date()
    let data = try await upload(request, file: audio)
    let seconds = Date().timeIntervalSince(t0)
    let turns = try deepgramTurns(try JSONSerialization.jsonObject(with: data), multichannel: multichannel)
    return Result(engine: "deepgram", seconds: seconds, uploadBytes: size, turns: turns, raw: data)
}

// MARK: - Report

func markdown(_ r: Result, file: String) -> String {
    var s = "# \(r.engine): \(file)\n\n"
    for t in r.turns { s += "[\(clock(t.start))] **\(t.speaker)**: \(t.text)\n\n" }
    return s
}

func shares(_ turns: [Turn], duration: Double) -> [(String, Double)] {
    var talk: [String: Double] = [:]
    for (i, t) in turns.enumerated() {
        let end = i + 1 < turns.count ? turns[i + 1].start : duration
        talk[t.speaker, default: 0] += max(0, end - t.start)
    }
    let total = max(1, talk.values.reduce(0, +))
    return talk.map { ($0.key, $0.value / total) }.sorted { $0.1 > $1.1 }
}

func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

// MARK: - Main

do {
    let o = try Options(Array(CommandLine.arguments.dropFirst()))
    let p = try await probe(o.file)
    print("File: \(o.file.lastPathComponent) · \(clock(p.duration)) · \(p.channels) channel(s) · \(mb(p.bytes))\(p.hasVideo ? " · video" : "")")
    if p.duration > 2 * 3600 { print("Note: over the design's 2-hour cap; continuing for the spike.") }
    let multichannel = o.multichannel && p.channels >= 2
    if o.multichannel && !multichannel { print("Note: --multichannel ignored, the file has \(p.channels) channel(s).") }

    var audio = o.file
    var exported: URL?
    if p.hasVideo {
        let t0 = Date()
        let url = try await exportAudio(o.file)
        exported = url
        audio = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        print("Video: audio exported to m4a in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(mb(size)) (was \(mb(p.bytes)))")
    }
    defer { if let exported { try? FileManager.default.removeItem(at: exported) } }

    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    var summary = "# Bake-off: \(o.file.lastPathComponent)\n\n"
    summary += "Duration \(clock(p.duration)), \(p.channels) channel(s), \(mb(p.bytes))\(p.hasVideo ? ", video" : ""). "
    summary += "Language \(o.language ?? "auto"), speakers \(o.speakers.map(String.init) ?? "auto"), multichannel \(multichannel).\n\n"
    summary += "| Engine | Model | Upload | Time | Speakers | Turns | Talk share |\n|---|---|---|---|---|---|---|\n"

    for engine in o.engines {
        print("\n\(engine): uploading and transcribing…")
        do {
            let r = engine == "scribe" ? try await runScribe(o, audio: audio, multichannel: multichannel)
                                       : try await runDeepgram(o, audio: audio, multichannel: multichannel)
            try r.raw.write(to: o.out.appendingPathComponent("\(engine).json"))
            try markdown(r, file: o.file.lastPathComponent).write(to: o.out.appendingPathComponent("\(engine).md"), atomically: true, encoding: .utf8)
            let share = shares(r.turns, duration: p.duration)
            let shareText = share.map { "\($0.0) \(Int(($0.1 * 100).rounded()))%" }.joined(separator: ", ")
            let model = engine == "scribe" ? o.scribeModel : o.deepgramModel
            print("\(engine): \(String(format: "%.1f", r.seconds)) s, \(share.count) speaker(s), \(r.turns.count) turns, upload \(mb(r.uploadBytes))")
            summary += "| \(engine) | \(model) | \(mb(r.uploadBytes)) | \(String(format: "%.1f", r.seconds)) s | \(share.count) | \(r.turns.count) | \(shareText) |\n"
        } catch {
            print("\(engine): FAILED: \(error)")
            summary += "| \(engine) | | | failed | | | \(String(describing: error).prefix(120)) |\n"
        }
    }
    summary += "\nJudge in \(engine_files(o.engines)): are speakers right, is German text right, are turns split at the right places?\n"
    try summary.write(to: o.out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    print("\nWrote \(o.out.path)/summary.md")
} catch let e as SpikeError {
    FileHandle.standardError.write(Data("\(e)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

func engine_files(_ engines: [String]) -> String { engines.map { "\($0).md" }.joined(separator: " and ") }
