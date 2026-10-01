// VibeFlow T1: ElevenLabs PCM streaming spike.
//
// Measures, over N runs, the two numbers the whole app depends on:
//   first audio  = request start -> first PCM buffer playing   (target <= 1.5 s)
//   stop latency = stop() call -> player silent                 (target <= 100 ms)
// Run 1 is cold (engine start included); later runs are warm.
//
// Usage (no Xcode needed, Command Line Tools are enough):
//   swift Spike/elevenlabs-spike.swift [--runs 10] [--speed 1.0] [--voice JBFqnCBsd6RMkjVDRZzb]
//                                      [--stop-after 2.0] [--text-file path] [--quiet]
//
// The API key is read from ELEVENLABS_API_KEY, or from a .env file in the
// current directory containing ELEVENLABS_API_KEY=... (.env is gitignored).
// Never pass the key on the command line.

import AVFoundation
import Foundation

// MARK: - Arguments

struct Options {
    var runs = 10
    var speed = 1.0
    var voiceID = "JBFqnCBsd6RMkjVDRZzb" // George
    var stopAfter = 2.0                   // seconds of playback before measuring stop()
    var text = Options.sampleText
    var quiet = false

    static let sampleText = """
    VibeFlow reads whatever you select, in a voice you actually want to listen to. \
    This paragraph is about five hundred characters long, which is a typical email or a \
    couple of paragraphs from an article. It mixes short sentences with longer ones, a number \
    like 1,250, a date such as 3 October 2026, and an abbreviation like e.g. so that we can \
    hear how the model handles normalisation. If the first word arrives within a second and \
    a half and stops instantly when asked, the rest of the app is worth building.
    """

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() throws -> String {
                i += 1
                guard i < args.count else { throw SpikeError.usage("missing value for \(a)") }
                return args[i]
            }
            switch a {
            case "--runs": runs = try Int(value()) ?? { throw SpikeError.usage("--runs needs an integer") }()
            case "--speed": speed = try Double(value()) ?? { throw SpikeError.usage("--speed needs a number") }()
            case "--voice": voiceID = try value()
            case "--stop-after": stopAfter = try Double(value()) ?? { throw SpikeError.usage("--stop-after needs a number") }()
            case "--text-file": text = try String(contentsOfFile: value(), encoding: .utf8)
            case "--quiet": quiet = true
            default: throw SpikeError.usage("unknown argument \(a)")
            }
            i += 1
        }
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case noKey
    case http(Int, String)
    case badLine(String)

    var description: String {
        switch self {
        case .usage(let s): return "usage: \(s)"
        case .noKey: return "no API key: set ELEVENLABS_API_KEY or put ELEVENLABS_API_KEY=... in ./.env"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .badLine(let s): return "unparseable NDJSON line: \(s.prefix(120))"
        }
    }
}

func loadAPIKey() throws -> String {
    if let k = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !k.isEmpty { return k }
    if let env = try? String(contentsOfFile: ".env", encoding: .utf8) {
        for line in env.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ELEVENLABS_API_KEY=") {
                let v = t.dropFirst("ELEVENLABS_API_KEY=".count).trimmingCharacters(in: .whitespaces)
                let unquoted = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !unquoted.isEmpty { return unquoted }
            }
        }
    }
    throw SpikeError.noKey
}

// MARK: - NDJSON line shape

struct Alignment: Decodable {
    let characters: [String]
    let character_start_times_seconds: [Double]
    let character_end_times_seconds: [Double]
}

struct StreamLine: Decodable {
    let audio_base64: String?
    let alignment: Alignment?
    let normalized_alignment: Alignment?
}

// MARK: - Player (what PCMStreamPlayer will become)

final class Player {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private(set) var framesScheduled: AVAudioFrameCount = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Converts 16-bit little-endian mono PCM at 24 kHz to a Float32 buffer and schedules it.
    func schedule(pcm16: Data) {
        let frameCount = AVAudioFrameCount(pcm16.count / 2)
        guard frameCount > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        let out = buf.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
            }
        }
        framesScheduled += frameCount
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in }
        if !node.isPlaying { node.play() }
    }

    func reset() {
        node.stop()
        node.reset()
        framesScheduled = 0
    }

    var playedSeconds: Double {
        guard let nodeTime = node.lastRenderTime, let t = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(t.sampleTime) / t.sampleRate
    }
}

// MARK: - One run

struct RunResult {
    var firstAudioMs: Double = .nan
    var requestDoneMs: Double = .nan
    var stopMs: Double = .nan
    var lines = 0
    var audioBytes = 0
    var alignedChars = 0
    var lastAlignedEnd: Double = 0
    var error: String?
}

@MainActor
func runOnce(_ opts: Options, key: String, player: Player, cold: Bool) async -> RunResult {
    var r = RunResult()
    let t0 = Date()
    func ms() -> Double { Date().timeIntervalSince(t0) * 1000 }

    do {
        try player.startEngineIfNeeded()

        var url = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(opts.voiceID)/stream/with-timestamps")!
        url.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: url.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let body: [String: Any] = [
            "text": opts.text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": ["speed": opts.speed, "stability": 0.5, "similarity_boost": 0.75],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpikeError.http(-1, "no HTTP response") }
        if http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw SpikeError.http(http.statusCode, text)
        }

        let decoder = JSONDecoder()
        var stopTask: Task<Void, Never>?
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8), let parsed = try? decoder.decode(StreamLine.self, from: data) else {
                throw SpikeError.badLine(line)
            }
            r.lines += 1
            if let b64 = parsed.audio_base64, let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                r.audioBytes += pcm.count
                player.schedule(pcm16: pcm)
                if r.firstAudioMs.isNaN {
                    r.firstAudioMs = ms()
                    // Arm the stop test once audio is flowing.
                    let stopAfter = opts.stopAfter
                    stopTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(stopAfter * 1_000_000_000))
                        let s0 = Date()
                        player.reset()
                        r.stopMs = Date().timeIntervalSince(s0) * 1000
                    }
                }
            }
            if let a = parsed.alignment {
                r.alignedChars += a.characters.count
                if let last = a.character_end_times_seconds.last { r.lastAlignedEnd = max(r.lastAlignedEnd, last) }
            }
        }
        r.requestDoneMs = ms()
        // Let the stop test fire if the stream finished before stopAfter elapsed.
        if let st = stopTask { await st.value }
        if r.stopMs.isNaN {
            let s0 = Date()
            player.reset()
            r.stopMs = Date().timeIntervalSince(s0) * 1000
        }
    } catch {
        r.error = "\(error)"
        player.reset()
    }
    return r
}

// MARK: - Main

@MainActor
func main() async -> Int32 {
    let opts: Options
    do { opts = try Options(Array(CommandLine.arguments.dropFirst())) } catch { print(error); return 2 }
    let key: String
    do { key = try loadAPIKey() } catch { print(error); return 2 }

    print("VibeFlow T1 spike: \(opts.runs) runs, speed \(opts.speed), voice \(opts.voiceID), \(opts.text.count) chars, stop after \(opts.stopAfter) s")
    print(String(repeating: "-", count: 78))
    print(String(format: "%-5@ %-6@ %12@ %13@ %9@ %7@ %10@ %8@", "run", "state", "first audio", "request done", "stop", "lines", "audio KB", "chars"))

    let player = Player()
    var results: [RunResult] = []
    for i in 1...opts.runs {
        let r = await runOnce(opts, key: key, player: player, cold: i == 1)
        results.append(r)
        if let e = r.error {
            print(String(format: "%-5d %-6@ ERROR %@", i, i == 1 ? "cold" : "warm", e))
            if e.contains("HTTP 400") || e.contains("HTTP 401") || e.contains("HTTP 422") { break }
        } else {
            print(String(format: "%-5d %-6@ %9.0f ms %10.0f ms %6.1f ms %7d %10.1f %8d",
                         i, i == 1 ? "cold" : "warm", r.firstAudioMs, r.requestDoneMs, r.stopMs, r.lines,
                         Double(r.audioBytes) / 1024, r.alignedChars))
        }
        // Small gap so runs do not overlap on the audio device.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    let ok = results.filter { $0.error == nil }
    guard !ok.isEmpty else { print("\nNo successful runs."); return 1 }
    let warm = ok.dropFirst()
    func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
    let firstCold = ok.first!.firstAudioMs
    let firstWarm = median(warm.map(\.firstAudioMs))
    let stopMed = median(ok.map(\.stopMs))
    let audioSeconds = ok.first!.lastAlignedEnd

    print(String(repeating: "-", count: 78))
    print(String(format: "first audio: cold %.0f ms, warm median %.0f ms   (target <= 1500 ms)", firstCold, firstWarm))
    print(String(format: "stop latency: median %.1f ms                      (target <= 100 ms)", stopMed))
    print(String(format: "audio length from alignment: %.1f s for %d chars", audioSeconds, opts.text.count))
    let pass = firstWarm <= 1500 && stopMed <= 100
    print(pass ? "PASS" : "FAIL")
    return pass ? 0 : 1
}

exit(await main())
