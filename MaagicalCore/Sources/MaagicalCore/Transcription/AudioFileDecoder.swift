import AVFoundation
import Foundation

/// Why a file cannot be transcribed, before any engine is involved (design D4). Kept apart from
/// `TranscriptionFailure` so dictation's exhaustive switches stay untouched.
public enum AudioFileError: Error, Equatable, Sendable {
    /// The file has no audio track ("No audio in interview.mov").
    case noAudio
    /// AVFoundation cannot read it: DRM, an iCloud placeholder, a damaged or unknown file.
    case unreadable(String)
    /// Longer than the 2-hour cap (design Q2).
    case tooLong(seconds: Double)
}

/// What the options window needs before anything is decoded or sent (eng review R6, D3).
public struct AudioFileInfo: Sendable, Equatable {
    public var duration: Double
    public var channels: Int
    public var hasVideo: Bool

    public init(duration: Double, channels: Int, hasVideo: Bool) {
        self.duration = duration
        self.channels = channels
        self.hasVideo = hasVideo
    }
}

/// A piece of a decoded file for the Groq memo engine (design D5): a range of 200 ms windows.
public struct AudioPiece: Sendable, Equatable {
    public var windows: Range<Int>
    /// Every 1-second stretch is below `NoSpeech.silenceRMS`: skipped without a request (D12).
    public var isSilent: Bool

    public init(windows: Range<Int>, isSilent: Bool) {
        self.windows = windows
        self.isSilent = isSilent
    }

    /// Start in seconds, for timestamps of the segments Whisper returns for this piece.
    public var start: Double { Double(windows.lowerBound) * AudioFileDecoder.windowSeconds }
}

/// A decoded file: 16 kHz mono 16-bit PCM in a temporary WAV, plus its loudness per 200 ms.
public struct DecodedAudio: Sendable {
    public let wavURL: URL
    public let sampleCount: Int
    /// Mean square (0 ... 1) of each 200 ms window; the last one may be shorter.
    public let envelope: [Double]

    public var duration: Double { Double(sampleCount) / Double(RecordedAudio.sampleRate) }

    /// The PCM of a range of windows, read from disk (one piece is at most 19.2 MB).
    public func audio(windows: Range<Int>) throws -> RecordedAudio {
        let bytesPerWindow = AudioFileDecoder.windowSamples * 2
        let startByte = windows.lowerBound * bytesPerWindow
        let endByte = min(windows.upperBound * bytesPerWindow, sampleCount * 2)
        guard endByte > startByte else { return .empty }
        let handle = try FileHandle(forReadingFrom: wavURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(44 + startByte))
        return RecordedAudio(pcm16: try handle.read(upToCount: endByte - startByte) ?? Data())
    }

    /// Deletes the temporary WAV. Safe to call more than once.
    public func remove() {
        try? FileManager.default.removeItem(at: wavURL)
    }
}

/// Reads any audio or video file AVFoundation understands into the format both transcribers take
/// (design D4). T1 confirmed on macOS 26 that the track output delivers 16 kHz mono 16-bit
/// directly, from stereo m4a, mono m4a and mp4 video alike.
public enum AudioFileDecoder {
    public static let windowSamples = 3_200 // 200 ms at 16 kHz
    public static let windowSeconds = 0.2
    /// Design Q2: two hours for every engine.
    public static let maxDuration: Double = 2 * 3600
    /// Groq pieces: at most 10 minutes (19.2 MB of WAV, under Groq's 25 MB upload cap)...
    public static let maxPieceWindows = 3_000
    /// ...cut at the quietest 200 ms in the last 30 seconds before the mark.
    public static let cutSearchWindows = 150
    /// Prefix of every temporary file, so a launch sweep can remove leftovers.
    public static let tempPrefix = "vibeflow-file-"

    static var pcmSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(RecordedAudio.sampleRate),
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    // MARK: Probe

    public static func probe(_ url: URL) async throws -> AudioFileInfo {
        let asset = AVURLAsset(url: url)
        let audio: [AVAssetTrack]
        let duration: Double
        let video: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { throw AudioFileError.unreadable(url.lastPathComponent) }
            audio = try await asset.loadTracks(withMediaType: .audio)
            video = try await asset.loadTracks(withMediaType: .video)
            duration = try await asset.load(.duration).seconds
        } catch let error as AudioFileError {
            throw error
        } catch {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        guard let track = audio.first else { throw AudioFileError.noAudio }
        var channels = 0
        for description in (try? await track.load(.formatDescriptions)) ?? [] {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                channels = max(channels, Int(asbd.mChannelsPerFrame))
            }
        }
        return AudioFileInfo(duration: duration.isFinite ? duration : 0, channels: channels, hasVideo: !video.isEmpty)
    }

    // MARK: Decode

    /// Decodes `url` to a temporary WAV in `directory`. Throws `tooLong` before decoding anything
    /// when the file is over `maxDuration`. Cancellation deletes the partial file.
    public static func decode(_ url: URL, maxDuration: Double = maxDuration,
                              directory: URL = FileManager.default.temporaryDirectory) async throws -> DecodedAudio {
        let info = try await probe(url)
        guard info.duration <= maxDuration else { throw AudioFileError.tooLong(seconds: info.duration) }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw AudioFileError.noAudio }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioFileError.unreadable(url.lastPathComponent) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        guard reader.canAdd(output) else { throw AudioFileError.unreadable(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else { throw AudioFileError.unreadable(url.lastPathComponent) }

        let wavURL = directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: wavURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: RecordedAudio.wavHeader(pcmBytes: 0))

            var envelope = EnvelopeBuilder()
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 else { continue }
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw AudioFileError.unreadable(url.lastPathComponent) }
                envelope.add(pcm16: data)
                try handle.write(contentsOf: data)
            }
            if reader.status != .completed {
                reader.cancelReading()
                throw AudioFileError.unreadable(reader.error?.localizedDescription ?? url.lastPathComponent)
            }
            let result = envelope.finish()
            guard result.samples > 0 else { throw AudioFileError.noAudio }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: RecordedAudio.wavHeader(pcmBytes: result.samples * 2))
            return DecodedAudio(wavURL: wavURL, sampleCount: result.samples, envelope: result.windows)
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
    }

    // MARK: Leftovers

    /// Deletes temporary files a quit or crash left behind (a 2-hour memo leaves about 230 MB).
    /// Call at launch, when no job can be running. Returns how many were removed.
    @discardableResult
    public static func removeLeftovers(in directory: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(tempPrefix) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Audio only

    /// A video's audio track as a temporary m4a (about 1 MB per minute), so an upload never
    /// carries the picture (eng review R6). Audio files are returned as they are; the caller
    /// deletes the result only when it differs from `url`.
    public static func audioOnly(_ url: URL, info: AudioFileInfo,
                                 directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        guard info.hasVideo else { return url }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioFileError.unreadable(url.lastPathComponent)
        }
        let target = directory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).m4a")
        do {
            try await session.export(to: target, as: .m4a)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw AudioFileError.unreadable(error.localizedDescription)
        }
        return target
    }

    // MARK: Pieces

    /// Splits an envelope into pieces of at most `maxWindows`, each cut at the quietest window in
    /// the last `searchWindows` before the mark (the latest one on ties, so pieces stay long),
    /// with no overlap. A piece is silent only when every 1-second stretch (5 windows) is below
    /// `silenceRMS`, so a few seconds of quiet speech in a long pause still get sent (D12).
    public static func pieces(envelope: [Double], maxWindows: Int = maxPieceWindows,
                              searchWindows: Int = cutSearchWindows,
                              silenceRMS: Double = NoSpeech.silenceRMS) -> [AudioPiece] {
        precondition(maxWindows > 0 && searchWindows > 0 && searchWindows <= maxWindows)
        var result: [AudioPiece] = []
        var start = 0
        while start < envelope.count {
            var end = envelope.count
            if envelope.count - start > maxWindows {
                let mark = start + maxWindows
                var quietest = mark - 1
                for i in (mark - searchWindows)..<mark where envelope[i] <= envelope[quietest] {
                    quietest = i
                }
                end = quietest + 1
            }
            result.append(AudioPiece(windows: start..<end, isSilent: isSilent(envelope[start..<end], silenceRMS: silenceRMS)))
            start = end
        }
        return result
    }

    static func isSilent(_ windows: ArraySlice<Double>, silenceRMS: Double) -> Bool {
        let perSecond = Int((1 / windowSeconds).rounded())
        var i = windows.startIndex
        while i < windows.endIndex {
            let second = windows[i..<min(i + perSecond, windows.endIndex)]
            let meanSquare = second.reduce(0, +) / Double(second.count)
            if meanSquare.squareRoot() >= silenceRMS { return false }
            i += perSecond
        }
        return true
    }
}

/// Mean square per 200 ms window, built while the PCM streams past.
struct EnvelopeBuilder {
    private(set) var windows: [Double] = []
    private var sum = 0.0
    private var count = 0
    private var total = 0

    mutating func add(pcm16 data: Data) {
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let v = Double(Int16(littleEndian: sample)) / 32768
                sum += v * v
                count += 1
                if count == AudioFileDecoder.windowSamples { close() }
            }
        }
        total += data.count / 2
    }

    private mutating func close() {
        windows.append(sum / Double(count))
        sum = 0
        count = 0
    }

    mutating func finish() -> (samples: Int, windows: [Double]) {
        if count > 0 { close() }
        return (total, windows)
    }
}
