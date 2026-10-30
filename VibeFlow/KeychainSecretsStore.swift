import Foundation
import KeychainAccess
import VibeFlowCore

/// API keys in the login Keychain, cached in memory so the hotkey path never waits on
/// Keychain (perf note P3). Keys are bound to this app's signing identity. API keys are shared
/// by VibeFlow and VibeFlow Dev; the Google sign-in is per app, so signing out of Dev never
/// signs out the release.
final class KeychainSecretsStore: SecretsStore, @unchecked Sendable {
    private let keychain = Keychain(service: "one.floo.vibeflow").accessibility(.whenUnlocked)
    private let perApp = Keychain(service: (Bundle.main.bundleIdentifier ?? "one.floo.vibeflow") + ".google")
        .accessibility(.whenUnlocked)
    private let lock = NSLock()
    private var cache: [SecretKey: String] = [:]

    init() {
        for key in SecretKey.allCases where !key.readsOnDemand {
            if let value = try? keychain.get(key.rawValue), !value.isEmpty {
                cache[key] = value
            }
        }
        // Builds before the per-app split kept the Google sign-in in the shared service.
        try? keychain.remove(SecretKey.googleRefreshToken.rawValue)
    }

    private func store(for key: SecretKey) -> Keychain {
        key == .googleRefreshToken ? perApp : keychain
    }

    func read(_ key: SecretKey) -> String? {
        lock.withLock { cache[key] }
    }

    func readOnDemand(_ key: SecretKey) throws -> String? {
        let value = try store(for: key).get(key.rawValue)
        return value?.isEmpty == false ? value : nil
    }

    func write(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(key); return }
        try store(for: key).set(trimmed, key: key.rawValue)
        lock.withLock { cache[key] = trimmed }
    }

    func delete(_ key: SecretKey) throws {
        try store(for: key).remove(key.rawValue)
        lock.withLock { cache[key] = nil }
    }
}
