import Foundation
import Observation

/// AssetInventory behind a protocol so readiness is tested without downloads (D9).
public protocol OnDeviceModelStore: Sendable {
    func state(for language: String?) async -> OnDeviceModelState
    /// Downloads and installs the model if missing; returns the resulting state.
    func prepare(for language: String?) async -> OnDeviceModelState
}

public struct LiveOnDeviceModelStore: OnDeviceModelStore {
    public init() {}
    public func state(for language: String?) async -> OnDeviceModelState { await OnDeviceModel.state(for: language) }
    public func prepare(for language: String?) async -> OnDeviceModelState { await OnDeviceModel.prepare(for: language) }
}

/// Keeps Apple's on-device model ready so the fallback works offline the first time (D9):
/// checked at launch and downloaded in the background when missing. Settings shows `state`
/// and offers Retry after a failure.
@MainActor
@Observable
public final class OnDeviceModelStatus {
    public private(set) var state: OnDeviceModelState?
    public private(set) var language: String?
    private let store: any OnDeviceModelStore
    private var task: Task<Void, Never>?

    public init(store: any OnDeviceModelStore) {
        self.store = store
    }

    /// Checks the model for `language` (nil = system language) and downloads it if missing.
    /// A call while one is running for the same language does nothing.
    public func prepare(language: String?) {
        if task != nil && language == self.language { return }
        task?.cancel()
        self.language = language
        task = Task { [weak self, store] in
            let initial = await store.state(for: language)
            guard let self, !Task.isCancelled else { return }
            self.state = initial
            if initial == .notInstalled || initial == .downloading {
                self.state = .downloading
                let final = await store.prepare(for: language)
                guard !Task.isCancelled else { return }
                self.state = final
            }
            self.task = nil
        }
    }

    public func retry() {
        task?.cancel()
        task = nil
        prepare(language: language)
    }

    public var isReady: Bool { state == .ready }

    /// Short line for Settings.
    public var summary: String {
        switch state {
        case nil: return "Checking"
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .notInstalled: return "Not installed"
        case .unsupportedLanguage: return "This language has no on-device model"
        case .unavailableOnThisMac: return "Needs macOS 26"
        case .failed(let reason): return "Download failed: \(reason)"
        }
    }
}
