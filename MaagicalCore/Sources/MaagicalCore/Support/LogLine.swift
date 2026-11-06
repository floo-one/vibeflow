import Foundation

/// Text for log lines that Send Feedback attaches (docs/designs/feedback.md). Lines carry
/// metadata only: statuses, providers, models, counts and durations, never the selected,
/// dictated or answered text (D4). Provider error text is capped and raw response bodies
/// are reduced to their size (D7).
enum LogLine {
    static let providerMessageLimit = 160

    /// A provider's own error message, as logged: at most 160 characters.
    static func providerMessage(_ message: String) -> String {
        message.count > providerMessageLimit ? String(message.prefix(providerMessageLimit)) + "…" : message
    }

    /// Stands in for a response body that was not the provider's JSON error.
    static func rawBody(bytes: Int) -> String {
        "non-JSON body, \(bytes) bytes"
    }

    /// "Groq error 413: file too large", or "Groq error 502: non-JSON body, 512 bytes".
    static func rejected(name: String, status: Int, message: String, rawBodyBytes: Int?) -> String {
        "\(name) error \(status): " + (rawBodyBytes.map(rawBody(bytes:)) ?? providerMessage(message))
    }

    /// "Read finished: Done (smart read, ElevenLabs, 812 chars, 4.2 s)"
    static func readFinished(status: String, kind: ReadKind?, usingApple: Bool, characters: Int?, duration: Duration?) -> String {
        guard let kind else { return "Read finished: \(status)" }
        var details = [kind == .smartRead ? "smart read" : "read", usingApple ? "Apple voice" : "ElevenLabs"]
        if let characters { details.append("\(characters) chars") }
        if let duration { details.append(seconds(duration)) }
        return "Read finished: \(status) (\(details.joined(separator: ", ")))"
    }

    /// "Smart read answered: claude-haiku-4-5, 640 chars in 2.1 s"
    static func smartReadAnswered(model: String, characters: Int, duration: Duration) -> String {
        "Smart read answered: \(model), \(characters) chars in \(seconds(duration))"
    }

    /// "Voice fallback: ElevenLabs → Apple (Using Apple voice: ElevenLabs unavailable (offline))"
    static func voiceFallback(status: String) -> String {
        "Voice fallback: ElevenLabs → Apple (\(providerMessage(status)))"
    }

    private static func seconds(_ duration: Duration) -> String {
        let (s, attoseconds) = duration.components
        let value = Double(s) + Double(attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }
}
