import Foundation

/// The one-time "VibeFlow is now Maagical" card in the menu bar panel (PanelState), shown on a
/// Mac that already has VibeFlow data when the first Maagical build starts, until OK is
/// pressed. A fresh install never sees it. Decided before the stores run, because they create
/// the folder and its files themselves.
enum RenameNotice {
    private static let seenKey = "rename.noticeSeen"

    /// True when the card should show. Marks a fresh install as seen right away.
    static func decideAtLaunch() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: seenKey) != nil { return false }
        let folder = URL.applicationSupportDirectory.appending(path: "VibeFlow")
        let files = FileManager.default
        let hadData = ["history.json", "history-dev.json", "usage.json", "usage-dev.json", "focus.json", "focus-dev.json"]
            .contains { files.fileExists(atPath: folder.appending(path: $0).path) }
        if !hadData { defaults.set(true, forKey: seenKey) }
        return hadData
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}
