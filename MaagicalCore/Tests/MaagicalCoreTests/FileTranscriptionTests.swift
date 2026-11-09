import AVFoundation
import Foundation
import Testing
@testable import MaagicalCore

/// Loud speech-like windows (RMS 0.046, like T1's real speech) and true silence, as mean squares.
private let loud = 0.046 * 0.046
private let quiet = 0.0

@Suite("Audio file pieces")
struct AudioPieceTests {
    @Test func underTenMinutesIsOnePiece() {
        let pieces = AudioFileDecoder.pieces(envelope: Array(repeating: loud, count: 2_999))
        #expect(pieces == [AudioPiece(windows: 0..<2_999, isSilent: false)])
    }

    @Test func noPauseCutsExactlyAtTenMinutes() {
        // 25 minutes of unbroken speech: cuts at 10:00 and 20:00, rest in a third piece.
        let pieces = AudioFileDecoder.pieces(envelope: Array(repeating: loud, count: 7_500))
        #expect(pieces.map(\.windows) == [0..<3_000, 3_000..<6_000, 6_000..<7_500])
        #expect(pieces[1].start == 600)
    }

    @Test func cutsAtTheQuietestMomentInTheLastThirtySeconds() {
        var envelope = Array(repeating: loud, count: 4_000)
        envelope[2_925] = quiet          // a pause at 9:45
        envelope[2_700] = quiet          // 9:00 is outside the 30-second search window
        let pieces = AudioFileDecoder.pieces(envelope: envelope)
        #expect(pieces.map(\.windows) == [0..<2_926, 2_926..<4_000])
    }

    @Test func piecesCoverEveryWindowWithoutOverlap() {
        var envelope = (0..<36_000).map { _ in loud }   // two hours
        for i in stride(from: 1_234, to: 36_000, by: 2_777) { envelope[i] = quiet }
        let pieces = AudioFileDecoder.pieces(envelope: envelope)
        #expect(pieces.first?.windows.lowerBound == 0)
        #expect(pieces.last?.windows.upperBound == 36_000)
        for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(a.windows.upperBound == b.windows.lowerBound) }
        #expect(pieces.allSatisfy { $0.windows.count <= 3_000 })
    }

    @Test func aFullySilentPieceIsSkipped() {
        #expect(AudioFileDecoder.pieces(envelope: Array(repeating: quiet, count: 3_000)) == [AudioPiece(windows: 0..<3_000, isSilent: true)])
    }

    @Test func tenSecondsOfQuietSpeechInTenMinutesOfSilenceIsSent() {
        // The outside voice's case: averaged over the whole piece this is below 0.005 RMS
        // (about 0.0039), but each of those 10 seconds is well above it (D12).
        var envelope = Array(repeating: quiet, count: 3_000)
        for i in 1_000..<1_050 { envelope[i] = 0.03 * 0.03 }
        let wholePieceRMS = (envelope.reduce(0, +) / 3_000).squareRoot()
        #expect(wholePieceRMS < NoSpeech.silenceRMS)
        #expect(AudioFileDecoder.pieces(envelope: envelope).first?.isSilent == false)
    }

    @Test func oneLoudWindowInASecondKeepsThePiece() {
        var envelope = Array(repeating: quiet, count: 600)
        envelope[302] = loud
        #expect(AudioFileDecoder.pieces(envelope: envelope).first?.isSilent == false)
    }
}

@Suite("Silent segments")
struct KeptSegmentsTests {
    func segment(_ text: String, _ prob: Double) -> WhisperSegment {
        WhisperSegment(start: 0, end: 1, text: text, noSpeechProbability: prob)
    }

    @Test func dropsSilenceAndCorroboratedHallucinationsOnly() {
        let cases: [(WhisperSegment, Bool)] = [
            (segment("Wir schicken den Zeitplan bis Freitag.", 0.05), true),
            (segment("Wir schicken den Zeitplan bis Freitag.", 0.7), false),   // above 0.6: silence
            (segment("Untertitel im Auftrag des ZDF, 2017", 0.4), false),      // hallucination, prob above 0.3
            (segment("Vielen Dank.", 0.1), true),                               // spoken thanks survives
            (segment("Thank you.", 0.35), false),
            (segment("   ", 0.01), false),                                      // empty
        ]
        for (input, kept) in cases {
            #expect(NoSpeech.keptSegments([input]) == (kept ? [input] : []), "\(input.text) at \(input.noSpeechProbability)")
        }
    }
}

@Suite("OpenAITranscriber segments")
struct TranscribeSegmentsTests {
    let http = FakeHTTPClient()
    let audio = RecordedAudio(pcm16: Data(repeating: 1, count: 3_200))

    @Test func returnsTimesTextAndProbabilities() async throws {
        http.body = try JSONSerialization.data(withJSONObject: [
            "text": " Hallo. Wie geht's? ",
            "segments": [
                ["start": 0.0, "end": 1.4, "text": " Hallo.", "no_speech_prob": 0.02],
                ["start": 1.4, "end": 3.0, "text": " Wie geht's?", "no_speech_prob": 0.1],
            ],
        ])
        let segments = try await OpenAITranscriber(http: http, apiKey: { "gsk-test" }).transcribeSegments(audio, language: nil)
        #expect(segments == [
            WhisperSegment(start: 0, end: 1.4, text: "Hallo.", noSpeechProbability: 0.02),
            WhisperSegment(start: 1.4, end: 3.0, text: "Wie geht's?", noSpeechProbability: 0.1),
        ])
    }

    @Test func failuresMapLikeDictation() async {
        http.status = 429
        await #expect(throws: TranscriptionFailure.rateLimited) {
            try await OpenAITranscriber(http: http, apiKey: { "gsk-test" }).transcribeSegments(audio, language: nil)
        }
    }

    @Test func dictationResultIsUnchanged() async throws {
        // Regression: segments with times and text must not change what dictation gets back.
        http.body = try JSONSerialization.data(withJSONObject: [
            "text": " Hallo. ", "segments": [["start": 0.0, "end": 1.0, "text": " Hallo.", "no_speech_prob": 0.04]],
        ])
        let result = try await OpenAITranscriber(http: http, apiKey: { "gsk-test" }).transcribe(audio, language: nil)
        #expect(result == Transcription(text: "Hallo.", noSpeechProbabilities: [0.04]))
    }
}

@Suite("Audio file decoder")
struct AudioFileDecoderTests {
    /// A short stereo 44.1 kHz AAC file: a 440 Hz tone on the left, silence on the right.
    static func makeStereoFile(seconds: Double, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        ])
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 44_100)
            buffer.floatChannelData![1][i] = 0
        }
        try file.write(from: buffer)
        return url
    }

    let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vf-decoder-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func probeReportsDurationAndChannels() async throws {
        let file = try Self.makeStereoFile(seconds: 2, in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try await AudioFileDecoder.probe(file)
        #expect(abs(info.duration - 2) < 0.1)
        #expect(info.channels == 2)
        #expect(info.hasVideo == false)
    }

    @Test func decodesToSixteenKilohertzMonoWithEnvelope() async throws {
        let file = try Self.makeStereoFile(seconds: 2, in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoded = try await AudioFileDecoder.decode(file, directory: directory)
        defer { decoded.remove() }

        #expect(abs(decoded.duration - 2) < 0.1)
        #expect(decoded.envelope.count == Int((Double(decoded.sampleCount) / 3_200).rounded(.up)))
        // A tone is not silence anywhere in the middle of the file.
        #expect(decoded.envelope[3...6].allSatisfy { $0.squareRoot() > NoSpeech.silenceRMS })

        let header = try Data(contentsOf: decoded.wavURL).prefix(44)
        #expect(header == RecordedAudio.wavHeader(pcmBytes: decoded.sampleCount * 2))
        let firstSecond = try decoded.audio(windows: 0..<5)
        #expect(firstSecond.pcm16.count == 32_000)
        #expect(firstSecond.duration == .seconds(1))

        decoded.remove()
        #expect(!FileManager.default.fileExists(atPath: decoded.wavURL.path))
    }

    @Test func refusesFilesOverTheCapBeforeDecoding() async throws {
        let file = try Self.makeStereoFile(seconds: 2, in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AudioFileError.self) { try await AudioFileDecoder.decode(file, maxDuration: 1, directory: self.directory) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(AudioFileDecoder.tempPrefix) }
        #expect(leftovers.isEmpty)
    }

    @Test func aTextFileIsNotAudio() async throws {
        let file = directory.appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AudioFileError.self) { try await AudioFileDecoder.probe(file) }
    }
}
