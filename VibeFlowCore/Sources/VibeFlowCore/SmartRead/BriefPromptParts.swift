import Foundation

/// The three parts of the brief prompt the listener can edit in Settings > Smart Read > Prompts.
/// nil means the built-in default, so improved defaults reach everyone who never edited a part.
/// The identity, the injection guard and the language rule are not here: they stay fixed.
public struct BriefPromptParts: Sendable, Equatable, Codable {
    /// The kinds of text with their word limits (SmartReadPrompts.situationRule).
    public var situations: String?
    /// The AI-reply relay, with `{assistant}` where the assistant's name goes.
    public var aiReply: String?
    /// How every brief starts and sounds (SmartReadPrompts.briefStyleRule).
    public var style: String?

    public static let assistantPlaceholder = "{assistant}"
    /// A pasted essay cannot crowd out the fixed rules.
    public static let maxLength = 4_000

    public init(situations: String? = nil, aiReply: String? = nil, style: String? = nil) {
        self.situations = situations
        self.aiReply = aiReply
        self.style = style
    }

    public enum Part: String, CaseIterable, Sendable {
        case situations, aiReply, style

        public var defaultText: String {
            switch self {
            case .situations: SmartReadPrompts.situationRule
            case .aiReply: SmartReadPrompts.aiReplyTemplate
            case .style: SmartReadPrompts.briefStyleRule
            }
        }
    }

    public subscript(part: Part) -> String? {
        get {
            switch part {
            case .situations: situations
            case .aiReply: aiReply
            case .style: style
            }
        }
        set {
            let value = Self.normalized(newValue, default: part.defaultText)
            switch part {
            case .situations: situations = value
            case .aiReply: aiReply = value
            case .style: style = value
            }
        }
    }

    /// The text sent to the model: the edit, trimmed, or the default.
    public func text(_ part: Part) -> String {
        Self.normalized(self[part], default: part.defaultText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? part.defaultText
    }

    /// The text an editor shows: the edit exactly as typed, or the default.
    public func editableText(_ part: Part) -> String {
        self[part] ?? part.defaultText
    }

    public var isEdited: Bool { Part.allCases.contains { self[$0] != nil } }

    /// Blank or identical to the default = no edit; long text is cut. Kept as typed otherwise, so
    /// an editor does not lose the space just typed at the end.
    static func normalized(_ text: String?, default defaultText: String) -> String? {
        guard let text, case let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed != defaultText.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return String(text.prefix(maxLength))
    }
}
