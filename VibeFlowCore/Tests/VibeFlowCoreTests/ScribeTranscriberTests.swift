import Foundation
import Testing
@testable import VibeFlowCore

/// A synthetic Scribe response in the shape the T1 bake-off returned: words and spacing entries,
/// each word with a speaker id.
private func scribeBody(_ words: [(String, Double, Double, String?, String)]) -> Data {
    let list: [[String: Any]] = words.map { text, start, end, speaker, type in
        var w: [String: Any] = ["text": text, "start": start, "end": end, "type": type]
        if let speaker { w["speaker_id"] = speaker }
        return w
    }
    return try! JSONSerialization.data(withJSONObject: ["language_code": "deu", "text": "", "words": list])
}

@Suite("ScribeTranscriber")
struct ScribeTranscriberTests {
    let http = FakeHTTPClient()
    let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vf-scribe-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func scribe(key: String? = "sk-test") -> ScribeTranscriber {
        ScribeTranscriber(http: http, temporaryDirectory: directory, apiKey: { key })
    }

    func audioFile() throws -> URL { try AudioFileDecoderTests.makeStereoFile(seconds: 1, in: directory) }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(AudioFileDecoder.tempPrefix) }
    }

    @Test func uploadsTheFileFromDiskWithDiarizationOn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try audioFile()
        http.body = scribeBody([("Hallo.", 0.1, 0.5, "speaker_0", "word")])
        _ = try await scribe().transcribe(file: file, options: FileTranscriptionOptions(speakers: 2, language: "de-DE"))

        #expect(http.uploads.count == 1, "a file transcription must go through upload(fromFile:), never send")
        let fileBytes = try Data(contentsOf: file).count
        #expect(http.uploads[0].bytes > fileBytes)
        let request = http.requests[0]
        #expect(request.url == ScribeTranscriber.endpoint)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk-test")
        #expect(request.timeoutInterval == ScribeTranscriber.timeout)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        #expect(body.contains("name=\"diarize\"\r\n\r\ntrue\r\n"))
        #expect(body.contains("name=\"num_speakers\"\r\n\r\n2\r\n"))
        #expect(body.contains("name=\"language_code\"\r\n\r\nde\r\n"))
        #expect(!body.contains("use_multi_channel"))
        #expect(body.contains("filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mp4"))
        #expect(try leftovers().isEmpty, "the multipart body file is deleted after the upload")
    }

    @Test func detectSpeakersAndLanguageSendsNeitherField() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        http.body = scribeBody([])
        _ = try await scribe().transcribe(file: try audioFile(), options: FileTranscriptionOptions())
        let body = String(decoding: http.requests[0].httpBody!, as: UTF8.self)
        #expect(!body.contains("num_speakers"))
        #expect(!body.contains("language_code"))
    }

    @Test func multichannelOnAStereoFileAsksForChannels() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        http.body = scribeBody([])
        _ = try await scribe().transcribe(file: try audioFile(), options: FileTranscriptionOptions(multichannel: true))
        #expect(String(decoding: http.requests[0].httpBody!, as: UTF8.self).contains("name=\"use_multi_channel\"\r\n\r\ntrue\r\n"))
    }

    @Test func wordsBecomeOneSegmentPerSpeakerRun() throws {
        let body = scribeBody([
            ("Hallo", 0.0, 0.4, "speaker_0", "word"), (" ", 0.4, 0.4, "speaker_0", "spacing"),
            ("Frau", 0.4, 0.6, "speaker_0", "word"), (" ", 0.6, 0.6, "speaker_0", "spacing"),
            ("Stürmer.", 0.6, 1.0, "speaker_0", "word"), (" ", 1.0, 1.9, "speaker_0", "spacing"),
            ("Hallo.", 1.9, 2.3, "speaker_1", "word"), (" ", 2.3, 2.4, "speaker_1", "spacing"),
            ("Hören", 2.4, 2.7, "speaker_0", "word"), (" ", 2.7, 2.7, "speaker_0", "spacing"),
            ("Sie", 2.7, 2.9, "speaker_0", "word"), (" ", 2.9, 2.9, "speaker_0", "spacing"),
            ("mich?", 2.9, 3.3, "speaker_0", "word"),
        ])
        #expect(try ScribeTranscriber.segments(from: body, multichannel: false) == [
            SpeakerSegment(speaker: "speaker_0", start: 0.0, end: 1.0, text: "Hallo Frau Stürmer."),
            SpeakerSegment(speaker: "speaker_1", start: 1.9, end: 2.3, text: "Hallo."),
            SpeakerSegment(speaker: "speaker_0", start: 2.4, end: 3.3, text: "Hören Sie mich?"),
        ])
    }

    @Test func multichannelTranscriptsInterleaveByTime() throws {
        let body = try JSONSerialization.data(withJSONObject: ["transcripts": [
            ["channel_index": 0, "words": [["text": "Hallo.", "start": 0.0, "end": 0.5, "type": "word"],
                                           ["text": "Gut.", "start": 3.0, "end": 3.4, "type": "word"]]],
            ["channel_index": 1, "words": [["text": "Hallo,", "start": 1.0, "end": 1.4, "type": "word"],
                                           ["text": " ", "start": 1.4, "end": 1.4, "type": "spacing"],
                                           ["text": "hören", "start": 1.4, "end": 1.8, "type": "word"],
                                           ["text": " ", "start": 1.8, "end": 1.8, "type": "spacing"],
                                           ["text": "Sie?", "start": 1.8, "end": 2.2, "type": "word"]]],
        ]])
        #expect(try ScribeTranscriber.segments(from: body, multichannel: true) == [
            SpeakerSegment(speaker: "channel_0", start: 0.0, end: 0.5, text: "Hallo."),
            SpeakerSegment(speaker: "channel_1", start: 1.0, end: 2.2, text: "Hallo, hören Sie?"),
            SpeakerSegment(speaker: "channel_0", start: 3.0, end: 3.4, text: "Gut."),
        ])
    }

    @Test func aKeyWithoutSpeechToTextSaysSo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // The exact body T1 got back from a scoped key.
        http.status = 401
        http.body = Data(#"{"detail":{"type":"authentication_error","code":"unauthorized","message":"The API key you used is missing the permission speech_to_text to execute this operation.","status":"missing_permissions"}}"#.utf8)
        await #expect(throws: TranscriptionFailure.rejected(status: 401, message: ScribeTranscriber.missingPermissionMessage)) {
            try await self.scribe().transcribe(file: try self.audioFile(), options: FileTranscriptionOptions())
        }
    }

    @Test func statusesMapLikeTheOtherEngines() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try audioFile()
        let cases: [(Int, String, TranscriptionFailure)] = [
            (401, #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, .unauthorized),
            (429, "{}", .rateLimited),
            (503, "{}", .serverError(503)),
            (422, #"{"detail":{"message":"file too long"}}"#, .rejected(status: 422, message: "file too long")),
            (200, "not json", .malformed),
        ]
        for (status, body, expected) in cases {
            http.status = status
            http.body = Data(body.utf8)
            await #expect(throws: expected) { try await self.scribe().transcribe(file: file, options: FileTranscriptionOptions()) }
        }
        #expect(try leftovers().isEmpty)
    }

    @Test func noKeyFailsBeforeAnyRequest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: TranscriptionFailure.unauthorized) {
            try await self.scribe(key: nil).transcribe(file: try self.audioFile(), options: FileTranscriptionOptions())
        }
        #expect(http.requests.isEmpty)
    }

    @Test func audioFilesAreUploadedAsTheyAre() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try audioFile()
        let info = try await AudioFileDecoder.probe(file)
        #expect(try await AudioFileDecoder.audioOnly(file, info: info, directory: directory) == file)
    }
}

@Suite("OpenAITranscriber timeouts")
struct OpenAITranscriberTimeoutTests {
    let http = FakeHTTPClient()
    let audio = RecordedAudio(pcm16: Data(repeating: 1, count: 3_200))

    @Test func dictationKeepsItsTenSecondTimeout() async throws {
        http.body = Data(#"{"text":"Hallo."}"#.utf8)
        _ = try await OpenAITranscriber(http: http, apiKey: { "gsk" }).transcribe(audio, language: nil)
        #expect(http.requests[0].timeoutInterval == 10)
    }

    @Test func filePiecesGetTheLongerTimeout() async throws {
        http.body = Data(#"{"text":"Hallo.","segments":[]}"#.utf8)
        _ = try await OpenAITranscriber(http: http, timeout: OpenAITranscriber.fileTimeout, apiKey: { "gsk" })
            .transcribeSegments(audio, language: nil)
        #expect(http.requests[0].timeoutInterval == 60)
    }
}
