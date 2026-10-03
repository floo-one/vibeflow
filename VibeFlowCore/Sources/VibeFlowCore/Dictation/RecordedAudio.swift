import Foundation

/// A finished recording: 16-bit little-endian mono PCM plus what the session needs to judge it.
public struct RecordedAudio: Sendable, Equatable {
    public static let sampleRate = 16_000

    public let pcm16: Data

    public init(pcm16: Data) {
        self.pcm16 = pcm16
    }

    public static let empty = RecordedAudio(pcm16: Data())

    public var duration: Duration {
        .milliseconds(pcm16.count / 2 * 1000 / Self.sampleRate)
    }

    /// Root mean square level, 0 ... 1. Used as silence evidence for the phrase rule (D11).
    public var rms: Double {
        guard pcm16.count >= 2 else { return 0 }
        var sum = 0.0
        pcm16.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let v = Double(Int16(littleEndian: sample)) / 32768
                sum += v * v
            }
        }
        return (sum / Double(pcm16.count / 2)).squareRoot()
    }

    /// A complete WAV file (RIFF header + data) for upload.
    public var wav: Data {
        var d = Data(capacity: 44 + pcm16.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(Self.sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm16.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm16.count)); d.append(pcm16)
        return d
    }
}
