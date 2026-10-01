import Foundation
import Observation

/// User settings that are not per-app presets, backed by UserDefaults.
/// Shortcuts live in KeyboardShortcuts' own storage; keys live in the Keychain.
@MainActor
@Observable
public final class Preferences {
    public static let sizeCapRange = 1_000...SessionConfiguration.hardMax

    private let defaults: UserDefaults
    private enum Key {
        static let sizeCap = "sizeCap"
        static let smartReadModel = "smartReadModel"
        static let launchAtLogin = "launchAtLogin"
    }

    /// Selections above this need a confirmation. Clamped to 1,000 ... 40,000 (D1).
    public var sizeCap: Int {
        didSet {
            let clamped = min(max(sizeCap, Self.sizeCapRange.lowerBound), Self.sizeCapRange.upperBound)
            if clamped != sizeCap { sizeCap = clamped; return }
            defaults.set(sizeCap, forKey: Key.sizeCap)
        }
    }

    public var smartReadModel: String {
        didSet { defaults.set(smartReadModel, forKey: Key.smartReadModel) }
    }

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = SessionConfiguration()
        let storedCap = defaults.object(forKey: Key.sizeCap) as? Int ?? config.sizeCap
        sizeCap = min(max(storedCap, Self.sizeCapRange.lowerBound), Self.sizeCapRange.upperBound)
        smartReadModel = defaults.string(forKey: Key.smartReadModel) ?? config.smartReadModel
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    /// The session configuration reflecting these preferences.
    public var sessionConfiguration: SessionConfiguration {
        var config = SessionConfiguration()
        config.sizeCap = sizeCap
        config.smartReadModel = smartReadModel
        return config
    }
}
