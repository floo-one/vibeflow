import Foundation
import Testing
@testable import VibeFlowCore

@Suite("RecordedAudio")
struct RecordedAudioTests {
    @Test func wavHeaderDescribes16kMono16Bit() {
        let audio = RecordedAudio(pcm16: Data(repeating: 0, count: 32_000))
        let wav = audio.wav
        #expect(wav.count == 44 + 32_000)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(UInt16(littleEndian: channels) == 1)
        #expect(audio.duration == .seconds(1))
    }

    @Test func rmsIsZeroForSilenceAndHalfScaleForAConstantHalfSignal() {
        #expect(RecordedAudio(pcm16: Data(repeating: 0, count: 3_200)).rms == 0)
        var half = Data()
        for _ in 0..<1_600 { withUnsafeBytes(of: Int16(16_384).littleEndian) { half.append(contentsOf: $0) } }
        #expect(abs(RecordedAudio(pcm16: half).rms - 0.5) < 0.001)
        #expect(RecordedAudio.empty.rms == 0)
    }
}
