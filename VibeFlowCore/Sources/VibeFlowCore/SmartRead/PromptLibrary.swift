import Foundation

/// Every prompt text the listener can edit (Settings > Prompts), as edits on top of the
/// built-in defaults: a part never edited follows the default, so improved defaults reach it.
/// What keeps the features safe and parseable stays fixed in SmartReadPrompts: who reads the
/// text as data, the markers, the language rule, the call summary's JSON shape.
public struct PromptLibrary: Sendable, Equatable, Codable {
    /// A feature that sends a prompt.
    public enum Feature: String, CaseIterable, Codable, Sendable, Identifiable {
        case brief, cleanup, followUp, dictation, callSummary
        public var id: Self { self }

        public var title: String {
            switch self {
            case .brief: "Smart Read brief"
            case .cleanup: "Smart Read cleanup"
            case .followUp: "Follow-up answers"
            case .dictation: "Dictation cleanup"
            case .callSummary: "Call summary"
            }
        }
    }

    /// Where a part sits in the Prompts tree.
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case context, shared, smartRead, dictation, transcription
        public var id: Self { self }

        public var title: String {
            switch self {
            case .context: "Context"
            case .shared: "Shared"
            case .smartRead: "Smart Read"
            case .dictation: "Dictation"
            case .transcription: "Transcription"
            }
        }

        public var parts: [Part] { Part.allCases.filter { $0.group == self } }
    }

    /// One editable text.
    public enum Part: String, CaseIterable, Codable, Sendable, Identifiable {
        case aboutYou
        case identity, spokenStyle, customRules
        case briefKinds, briefAIReply, briefOpening, cleanup, followUp
        case dictationCleanup
        case callSummary
        public var id: Self { self }

        public var title: String {
            switch self {
            case .aboutYou: "About you"
            case .identity: "Who VibeFlow is"
            case .spokenStyle: "Spoken style"
            case .customRules: "Your rules"
            case .briefKinds: "Brief: kinds of text"
            case .briefAIReply: "Brief: AI replies"
            case .briefOpening: "Brief: opening and length"
            case .cleanup: "Cleanup"
            case .followUp: "Follow-up answers"
            case .dictationCleanup: "Cleanup"
            case .callSummary: "Call summary"
            }
        }

        public var group: Group {
            switch self {
            case .aboutYou: .context
            case .identity, .spokenStyle, .customRules: .shared
            case .briefKinds, .briefAIReply, .briefOpening, .cleanup, .followUp: .smartRead
            case .dictationCleanup: .dictation
            case .callSummary: .transcription
            }
        }

        /// The features that include this part; `customRules` follows the listener's choice.
        public var defaultUsedBy: [Feature] {
            switch self {
            case .aboutYou: [.brief, .followUp]
            case .identity: [.brief, .cleanup, .followUp]
            case .spokenStyle: [.brief, .followUp]
            case .customRules: PromptLibrary.defaultCustomRulesFeatures.sorted { $0.order < $1.order }
            case .briefKinds, .briefAIReply, .briefOpening: [.brief]
            case .cleanup: [.cleanup]
            case .followUp: [.followUp]
            case .dictationCleanup: [.dictation]
            case .callSummary: [.callSummary]
            }
        }

        public var hint: String {
            switch self {
            case .aboutYou: "Who you are, so briefs and answers can say \"your email to Charlotte\" instead of naming you. Name, role, company, languages. Empty = none."
            case .identity: "Opens every Smart Read prompt. \"I\" is VibeFlow; everyone else is named."
            case .spokenStyle: "How answers sound when spoken: sentences, terms, numbers."
            case .customRules: "Your own instructions, added to the features you tick. Empty = none."
            case .briefKinds: "The brief picks one kind of text and follows its line, word limit and sample opening."
            case .briefAIReply: "Used instead of the kinds of text for ChatGPT, Codex, Claude and Gemini. {assistant} becomes the app's name."
            case .briefOpening: "How every brief starts and how short it stays. Selections under 300 characters also get at most 25 words."
            case .cleanup: "Smart Read in cleanup mode: rewrites the text to read well aloud instead of summarizing it."
            case .followUp: "Answers to the question you ask by holding the Smart Read key."
            case .dictationCleanup: "Tidies what you dictated. Your vocabulary is added after it."
            case .callSummary: "What the summary and action items say. The JSON format and the speaker tokens stay fixed so the app can read the reply."
            }
        }

        public var defaultText: String {
            switch self {
            case .aboutYou: ""
            case .identity: SmartReadPrompts.identity
            case .spokenStyle: SmartReadPrompts.spokenStyleRule
            case .customRules: ""
            case .briefKinds: SmartReadPrompts.situationRule
            case .briefAIReply: SmartReadPrompts.aiReplyTemplate
            case .briefOpening: SmartReadPrompts.briefOpeningRule
            case .cleanup: SmartReadPrompts.cleanupRule
            case .followUp: SmartReadPrompts.followUpRule
            case .dictationCleanup: SmartReadPrompts.dictationCleanupRule
            case .callSummary: SmartReadPrompts.callSummaryRule
            }
        }
    }

    public static let assistantPlaceholder = "{assistant}"
    /// A pasted essay cannot crowd out the fixed rules.
    public static let maxLength = 4_000
    public static let defaultCustomRulesFeatures: Set<Feature> = [.brief, .followUp]

    /// Part raw value -> edited text, as typed.
    private var edits: [String: String]
    /// The features "Your rules" is added to.
    public var customRulesFeatures: Set<Feature>

    public init() {
        edits = [:]
        customRulesFeatures = Self.defaultCustomRulesFeatures
    }

    private enum CodingKeys: String, CodingKey { case edits, customRulesFeatures }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edits = try c.decodeIfPresent([String: String].self, forKey: .edits) ?? [:]
        customRulesFeatures = try c.decodeIfPresent(Set<Feature>.self, forKey: .customRulesFeatures) ?? Self.defaultCustomRulesFeatures
    }

    /// The edit, nil = the default. Setting blank text or the default itself clears the edit.
    public subscript(part: Part) -> String? {
        get { edits[part.rawValue] }
        set { edits[part.rawValue] = Self.normalized(newValue, default: part.defaultText) }
    }

    /// The text sent to the model: the edit, trimmed, or the default.
    public func text(_ part: Part) -> String {
        Self.normalized(self[part], default: part.defaultText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? part.defaultText
    }

    /// The text an editor shows: the edit exactly as typed, or the default.
    public func editableText(_ part: Part) -> String {
        self[part] ?? part.defaultText
    }

    public var isEdited: Bool { !edits.isEmpty || customRulesFeatures != Self.defaultCustomRulesFeatures }

    public func usedBy(_ part: Part) -> [Feature] {
        part == .customRules ? customRulesFeatures.sorted { $0.order < $1.order } : part.defaultUsedBy
    }

    /// "Your rules" for one feature, nil when empty or not ticked for it.
    public func customRules(for feature: Feature) -> String? {
        guard customRulesFeatures.contains(feature) else { return nil }
        let rules = text(.customRules)
        return rules.isEmpty ? nil : rules
    }

    /// Blank or identical to the default = no edit; long text is cut. Kept as typed otherwise, so
    /// an editor does not lose the space just typed at the end. Blank "Your rules" is no edit too.
    static func normalized(_ text: String?, default defaultText: String) -> String? {
        guard let text, case let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed != defaultText.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return String(text.prefix(maxLength))
    }
}

extension PromptLibrary.Feature {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
