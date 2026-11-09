import Foundation

/// Remembers which app was frontmost when the clipboard last changed, so Shift + smart read
/// speaks as an AI assistant only when the text was copied in that assistant.
///
/// macOS does not say who wrote the pasteboard. The best attribution is the app that was in
/// front while changeCount moved: a change seen at an activation belongs to the app resigning,
/// a change since the last activation belongs to the app in front now. A clipboard that
/// predates the first activation seen has no known source.
public struct ClipboardSourceTracker: Sendable {
    private var frontmost: String?
    private var countAtActivation: Int?
    private var lastChange: (bundleID: String?, changeCount: Int)?

    public init() {}

    /// An app became frontmost; `changeCount` is the pasteboard's at that moment.
    public mutating func appActivated(_ bundleID: String?, changeCount: Int) {
        if let countAtActivation, changeCount != countAtActivation {
            lastChange = (frontmost, changeCount)
        }
        frontmost = bundleID
        countAtActivation = changeCount
    }

    /// The app the current clipboard was copied in, nil when unknown.
    public func source(changeCount: Int) -> String? {
        guard let countAtActivation else { return nil }
        if changeCount != countAtActivation { return frontmost }
        if let lastChange, lastChange.changeCount == changeCount { return lastChange.bundleID }
        return nil
    }
}
