import Foundation

public enum ProviderKind: String, Codable, Sendable, Equatable {
    case elevenLabs
    case apple
}

/// Per-app voice and behaviour (design: Per-app preset schema). `bundleID == nil` is the
/// global default. Resolved and frozen when the hotkey fires (D8).
public struct AppPreset: Codable, Sendable, Equatable {
    public var bundleID: String?
    public var provider: ProviderKind
    public var elevenLabsVoiceID: String
    /// BCP-47 language -> AVSpeechSynthesisVoice identifier.
    public var appleVoiceByLanguage: [String: String]
    /// Playback multiplier 0.7 ... 2.0.
    public var speed: Double
    public var smartReadEnabled: Bool
    public var smartReadMode: SmartReadMode
    /// Extra smart read guidance for this app, e.g. "focus on deadlines". nil = none.
    public var smartReadInstructions: String?
    /// BCP-47, nil = detect from the text.
    public var languageOverride: String?
    /// Dictation into this app stays on the Mac: Apple's on-device recognizer, no cloud
    /// cleanup (D5). Absent in presets saved before VibeFlow 2, decoded as false.
    public var dictationLocalOnly: Bool

    public init(
        bundleID: String? = nil,
        provider: ProviderKind = .elevenLabs,
        elevenLabsVoiceID: String = AppPreset.defaultElevenLabsVoiceID,
        appleVoiceByLanguage: [String: String] = [:],
        speed: Double = 1.0,
        smartReadEnabled: Bool = true,
        smartReadMode: SmartReadMode = .brief,
        smartReadInstructions: String? = nil,
        languageOverride: String? = nil,
        dictationLocalOnly: Bool = false
    ) {
        self.bundleID = bundleID
        self.provider = provider
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.appleVoiceByLanguage = appleVoiceByLanguage
        self.speed = speed
        self.smartReadEnabled = smartReadEnabled
        self.smartReadMode = smartReadMode
        self.smartReadInstructions = smartReadInstructions
        self.languageOverride = languageOverride
        self.dictationLocalOnly = dictationLocalOnly
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID, provider, elevenLabsVoiceID, appleVoiceByLanguage, speed
        case smartReadEnabled, smartReadMode, smartReadInstructions, languageOverride, dictationLocalOnly
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        provider = try c.decode(ProviderKind.self, forKey: .provider)
        elevenLabsVoiceID = try c.decode(String.self, forKey: .elevenLabsVoiceID)
        appleVoiceByLanguage = try c.decode([String: String].self, forKey: .appleVoiceByLanguage)
        speed = try c.decode(Double.self, forKey: .speed)
        smartReadEnabled = try c.decode(Bool.self, forKey: .smartReadEnabled)
        smartReadMode = try c.decode(SmartReadMode.self, forKey: .smartReadMode)
        smartReadInstructions = try c.decodeIfPresent(String.self, forKey: .smartReadInstructions)
        languageOverride = try c.decodeIfPresent(String.self, forKey: .languageOverride)
        dictationLocalOnly = try c.decodeIfPresent(Bool.self, forKey: .dictationLocalOnly) ?? false
    }

    /// The one privacy switch per app: Apple voice, no smart read, dictation on device. Nothing
    /// from the app leaves the Mac. Turning it off restores the cloud defaults.
    public var keepsOnThisMac: Bool {
        get { provider == .apple && !smartReadEnabled && dictationLocalOnly }
        set {
            provider = newValue ? .apple : .elevenLabs
            smartReadEnabled = !newValue
            dictationLocalOnly = newValue
        }
    }

    /// George, ElevenLabs premade narrative voice.
    public static let defaultElevenLabsVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    /// Created on first run: ElevenLabs unconditionally (provider selection handles the
    /// no-key case), speed 1.0, smart read on in brief mode.
    public static let `default` = AppPreset()
}

/// Resolution: exact bundle id match, else the global default.
@MainActor
public protocol PresetResolving: AnyObject {
    func preset(for bundleID: String?) -> AppPreset
}
