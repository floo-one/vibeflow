import Foundation
import KeychainAccess
import OSLog

/// One-time import of settings and API keys from the app's previous identity,
/// one.floo.outflow, after the rename to VibeFlow (2026-10-01). Runs before any store is
/// created. Idempotent: a marker in the new defaults stops it from running twice, and it
/// never overwrites a value that already exists under the new identity.
enum LegacyMigration {
    static let legacyBundleID = "one.floo.outflow"
    private static let markerKey = "migratedFromOutflow"
    private static let log = Logger(subsystem: "one.floo.vibeflow", category: "migration")

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        // Only the release identity inherits from OutFlow; VibeFlow Dev starts clean.
        guard Bundle.main.bundleIdentifier == "one.floo.vibeflow" else { return }
        guard !defaults.bool(forKey: markerKey) else { return }
        let copiedDefaults = migrateDefaults(into: defaults)
        let copiedKeys = migrateKeychain()
        defaults.set(true, forKey: markerKey)
        log.notice("legacy migration: copied \(copiedDefaults, privacy: .public) settings and \(copiedKeys, privacy: .public) keys")
    }

    /// Copies presets, preferences and KeyboardShortcuts bindings. Not sandboxed, so the old
    /// app's preferences domain is readable by name.
    private static func migrateDefaults(into defaults: UserDefaults) -> Int {
        guard let old = UserDefaults.standard.persistentDomain(forName: legacyBundleID) else { return 0 }
        var copied = 0
        for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// Same signing team, so the old Keychain items are readable; macOS may ask once.
    private static func migrateKeychain() -> Int {
        let old = Keychain(service: legacyBundleID)
        let new = Keychain(service: "one.floo.vibeflow").accessibility(.whenUnlocked)
        var copied = 0
        for account in ["elevenlabs-api-key", "anthropic-api-key"] {
            guard (try? new.get(account)) == nil,
                  let value = try? old.get(account), !value.isEmpty else { continue }
            do {
                try new.set(value, key: account)
                copied += 1
            } catch {
                log.error("legacy migration: could not copy \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return copied
    }
}
