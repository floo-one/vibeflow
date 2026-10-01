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

    public init(
        bundleID: String? = nil,
        provider: ProviderKind = .elevenLabs,
        elevenLabsVoiceID: String = AppPreset.defaultElevenLabsVoiceID,
        appleVoiceByLanguage: [String: String] = [:],
        speed: Double = 1.0,
        smartReadEnabled: Bool = true,
        smartReadMode: SmartReadMode = .brief,
        smartReadInstructions: String? = nil,
        languageOverride: String? = nil
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
