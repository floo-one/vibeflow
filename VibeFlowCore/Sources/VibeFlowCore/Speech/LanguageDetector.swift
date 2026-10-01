import Foundation
import NaturalLanguage

/// Dominant language of the captured text as a BCP-47 tag, or nil when undetermined.
/// Used to pick the Apple voice and to tell smart read which language to answer in.
public enum LanguageDetector {
    public static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(2_000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }
}
