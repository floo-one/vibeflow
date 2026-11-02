import Foundation
import Testing
@testable import VibeFlowCore

/// Log lines ship with Send Feedback, so they carry metadata only (docs/designs/feedback.md, D7, D8).
@Suite("LogLine")
struct LogLineTests {
    @Test func providerMessagesAreCapped() {
        #expect(LogLine.providerMessage("model not found") == "model not found")
        let long = String(repeating: "x", count: 500)
        let capped = LogLine.providerMessage(long)
        #expect(capped.count == LogLine.providerMessageLimit + 1)
        #expect(capped.hasSuffix("…"))
    }

    @Test func aRawBodyNeverReachesTheLog() {
        let body = "<html>proxy echoed: please summarise my private contract</html>"
        let line = LogLine.rejected(name: "Groq", status: 502, message: body, rawBodyBytes: 512)
        #expect(line == "Groq error 502: non-JSON body, 512 bytes")
        #expect(!line.contains("private"))
    }

    @Test func aProviderJSONMessageIsKept() {
        #expect(LogLine.rejected(name: "Groq", status: 413, message: "file too large", rawBodyBytes: nil)
                == "Groq error 413: file too large")
    }

    @Test func readFinishedCarriesKindVoiceSizeAndTime() {
        let line = LogLine.readFinished(status: "Done", kind: .smartRead, usingApple: true, characters: 812,
                                        duration: .milliseconds(4_230))
        #expect(line == "Read finished: Done (smart read, Apple voice, 812 chars, 4.2 s)")
        #expect(LogLine.readFinished(status: "Done", kind: .read, usingApple: false, characters: nil, duration: nil)
                == "Read finished: Done (read, ElevenLabs)")
    }

    @Test func aFinishWithoutASessionIsJustTheStatus() {
        #expect(LogLine.readFinished(status: "Nothing selected", kind: nil, usingApple: false, characters: nil, duration: nil)
                == "Read finished: Nothing selected")
    }

    @Test func smartReadAnswersLogModelSizeAndTime() {
        #expect(LogLine.smartReadAnswered(model: "claude-haiku-4-5", characters: 640, duration: .seconds(2))
                == "Smart read answered: claude-haiku-4-5, 640 chars in 2.0 s")
    }

    @Test func voiceFallbackNamesTheReason() {
        #expect(LogLine.voiceFallback(status: "Using Apple voice: ElevenLabs unavailable (offline)")
                == "Voice fallback: ElevenLabs → Apple (Using Apple voice: ElevenLabs unavailable (offline))")
        #expect(LogLine.voiceFallback(status: String(repeating: "y", count: 400)).count < 220)
    }
}
