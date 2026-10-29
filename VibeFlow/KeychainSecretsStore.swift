import Foundation
import KeychainAccess
import VibeFlowCore

/// API keys in the login Keychain, cached in memory so the hotkey path never waits on
/// Keychain (perf note P3). Keys are bound to this app's signing identity.
final class KeychainSecretsStore: SecretsStore, @unchecked Sendable {
    private let keychain = Keychain(service: "one.floo.vibeflow").accessibility(.whenUnlocked)
    private let lock = NSLock()
    private var cache: [SecretKey: String] = [:]

    init() {
        for key in SecretKey.allCases where !key.readsOnDemand {
            if let value = try? keychain.get(key.rawValue), !value.isEmpty {
                cache[key] = value
            }
        }
    }

    func read(_ key: SecretKey) -> String? {
        lock.withLock { cache[key] }
    }

    func readOnDemand(_ key: SecretKey) throws -> String? {
        let value = try keychain.get(key.rawValue)
        return value?.isEmpty == false ? value : nil
    }

    func write(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try delete(key); return }
        try keychain.set(trimmed, key: key.rawValue)
        lock.withLock { cache[key] = trimmed }
    }

    func delete(_ key: SecretKey) throws {
        try keychain.remove(key.rawValue)
        lock.withLock { cache[key] = nil }
    }
}
