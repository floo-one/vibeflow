import Foundation

/// Which build of VibeFlow Dev is running (docs/designs/dev-prod-channels.md, P3).
/// scripts/dev.sh passes branch, commit and build time as build settings, Info.plist carries
/// them as VFGitBranch, VFGitCommit and VFBuildDate, and the Dev menu shows them on top.
public struct BuildStamp: Equatable, Sendable {
    public let branch: String
    /// Short commit, with "*" when the working tree had uncommitted changes.
    public let commit: String
    public let built: Date

    /// nil for a build that did not come from scripts/dev.sh (Xcode, a plain xcodebuild):
    /// its Info.plist has the keys, but empty.
    public init?(info: [String: Any]) {
        guard let branch = info["VFGitBranch"] as? String, !branch.isEmpty,
              let commit = info["VFGitCommit"] as? String, !commit.isEmpty,
              let stamp = info["VFBuildDate"] as? String,
              let built = try? Date(stamp, strategy: .iso8601)
        else { return nil }
        self.branch = branch
        self.commit = commit
        self.built = built
    }

    /// "smart-read · 8767a8f* · built 15:40". A build from an earlier day names the day too,
    /// so a stale VibeFlow Dev stands out.
    public func menuTitle(now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let when = calendar.isDate(built, inSameDayAs: now)
            ? built.formatted(style.hour().minute())
            : built.formatted(style.month(.abbreviated).day().hour().minute())
        return "\(branch) · \(commit) · built \(when)"
    }
}
