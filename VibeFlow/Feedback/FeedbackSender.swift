import Carbon
import Foundation
import OSLog
import Sentry
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "feedback")

/// Sentry for Send Feedback and crash reports (docs/designs/feedback.md). Started once at
/// launch, in VibeFlow Dev too (environment "dev", D11). Without a DSN in Info.plist (forks,
/// CI) nothing starts and the feedback entry points stay hidden.
enum FeedbackSender {
    static var isEnabled: Bool { dsn != nil }

    /// The build that is running (D5): Debug, a nightly (stamped commit) or a stable release.
    static var environment: FeedbackReport.Environment {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return .of(isDebug: isDebug, commit: info["VFGitCommit"] as? String)
    }

    static var release: String {
        FeedbackReport.release(version: info["CFBundleShortVersionString"] as? String ?? "?",
                               build: info["CFBundleVersion"] as? String ?? "?")
    }

    static func start() {
        guard let dsn else {
            log.notice("feedback: no Sentry DSN in this build, feedback and crash reports off")
            return
        }
        let environment = environment.rawValue
        let release = release
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = release
            // Crashes and hand-sent feedback only (F3, D10): no tracing, sessions or
            // automatic breadcrumbs, and never an HTTP request or response as an event.
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableUncaughtNSExceptionReporting = true
            options.enableAppHangTracking = true
            options.beforeSend = { scrub($0) }
        }
        SentrySDK.setUser(User(userId: installID))
        log.notice("feedback: Sentry started (\(environment, privacy: .public), \(release, privacy: .public))")
    }

    // MARK: Sending a report

    /// What the app knows about itself, frozen when the form opens.
    @MainActor
    static func facts(container: AppContainer) -> FeedbackReport.Facts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackReport.Facts(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            environment: environment,
            nightlyChannel: container.preferences.updateToNewestMain,
            stamp: BuildStamp(info: info),
            pane: SettingsWindow.isVisible ? "\(container.settingsTab)" : nil,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            keyboardLayout: keyboardLayout,
            accessibilityGranted: container.session.accessibilityTrusted,
            microphoneGranted: container.microphonePermission == .granted,
            settings: FeedbackReport.settings(from: container.preferences)
        )
    }

    /// The last 10 minutes of VibeFlow's own log, oldest first. Slow enough to keep off the
    /// main thread; the form says "Collecting logs…" meanwhile.
    static func readLogs(minutes: Double = 10) async -> FeedbackReport.Logs {
        await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let since = store.position(date: Date().addingTimeInterval(-minutes * 60))
                let entries = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", "one.floo.vibeflow"))
                let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                let lines = entries.compactMap { entry -> String? in
                    guard let entry = entry as? OSLogEntryLog else { return nil }
                    return "\(entry.date.formatted(time)) [\(entry.category)] \(entry.composedMessage)"
                }
                return .lines(lines)
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
        }.value
    }

    /// Hands the report to the SDK, which keeps it on disk until it is delivered (D6).
    static func send(_ report: FeedbackReport) {
        var attachments: [Attachment] = []
        if let logFile = report.logFile, !logFile.isEmpty {
            attachments.append(Attachment(data: Data(logFile.utf8), filename: FeedbackReport.logFileName,
                                          contentType: "text/plain"))
        }
        SentrySDK.configureScope { $0.setTags(report.tags) }
        SentrySDK.capture(feedback: SentryFeedback(message: report.text, name: nil, email: nil, source: .custom,
                                                   attachments: attachments))
        // Kind and pane describe this report only; crash events keep the rest.
        SentrySDK.configureScope { scope in
            scope.removeTag(key: "kind")
            scope.removeTag(key: "pane")
        }
        log.notice("feedback: \(report.kind.rawValue, privacy: .public) report queued")
    }

    /// "German", "ABC", "U.S.": the layout decides which keys VibeFlow's shortcuts sit on.
    private static var keyboardLayout: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Crash and hang events follow the same rules as feedback reports: keys and the home
    /// folder scrubbed, and no host name (it is often the owner's name).
    private static func scrub(_ event: Event) -> Event {
        event.serverName = nil
        if let formatted = event.message?.formatted {
            event.message = SentryMessage(formatted: FeedbackReport.scrub(formatted))
        }
        event.exceptions?.forEach { exception in
            exception.value = exception.value.map { FeedbackReport.scrub($0) }
        }
        event.breadcrumbs?.forEach { crumb in
            crumb.message = crumb.message.map { FeedbackReport.scrub($0) }
        }
        return event
    }

    /// A random id made on first launch, so reports from one Mac group together without
    /// naming anyone.
    private static var installID: String {
        let key = "feedback.installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    private static var dsn: String? {
        guard let value = info["SentryDSN"] as? String, value.hasPrefix("https://") else { return nil }
        return value
    }
}
