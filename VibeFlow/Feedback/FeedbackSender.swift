import Foundation
import os
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
