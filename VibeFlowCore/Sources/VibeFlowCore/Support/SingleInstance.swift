import Foundation

/// One running copy per app (docs/designs/dev-prod-channels.md, P2). A VibeFlow that starts
/// quits every older copy of itself, wherever that copy was launched from (another worktree,
/// Xcode, a stray build), so two menu bar icons never answer the same shortcut. VibeFlow and
/// VibeFlow Dev have different bundle ids and never see each other here.
public enum SingleInstance {
    public struct Copy: Equatable, Sendable {
        public let pid: Int32
        /// nil when the copy was not launched through Launch Services (Xcode, a debugger).
        public let launchDate: Date?

        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// The copies `me` quits: every other copy that started earlier. Two copies starting at the
    /// same moment do not quit each other; the newer one stays. A copy without a launch date
    /// counts as older, and `me` without one counts as newest, since it is starting right now.
    public static func olderCopies(of me: Copy, among running: [Copy]) -> [Int32] {
        let mine = me.launchDate ?? .distantFuture
        return running
            .filter { $0.pid != me.pid && ($0.launchDate ?? .distantPast) < mine }
            .map(\.pid)
    }
}
