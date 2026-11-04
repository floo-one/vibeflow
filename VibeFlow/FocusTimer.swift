import AppKit
import Observation
import OSLog
import UserNotifications
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "focus")

/// The Pomodoro timer in the app: FocusEngine's rules, FocusLog's file, a one-second ticker while a
/// phase runs, a chime and a silent notification when one ends. Every command is saved before
/// it shows: if focus.json cannot be written, nothing changes and the menu says so.
@MainActor
@Observable
final class FocusTimer {
    private(set) var session: FocusSession?
    private(set) var blocks: [FocusBlock]
    /// Advanced every second while a phase runs, for the label and the countdown.
    private(set) var now = Date()
    private(set) var saveFailed = false

    @ObservationIgnored private let store: FocusLog
    @ObservationIgnored private let preferences: Preferences
    /// Also serves "Transcript ready" (file transcription D10): one delegate per app.
    @ObservationIgnored let notifications = FocusNotifications()
    @ObservationIgnored private let chime = NSSound(named: "Glass")
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(preferences: Preferences) {
        self.preferences = preferences
        // VibeFlow Dev shares Application Support with the release; its runs stay out of the real stats.
        #if DEBUG
        store = FocusLog(fileURL: FocusLog.defaultFileURL(named: "focus-dev.json"))
        #else
        store = FocusLog(fileURL: FocusLog.defaultFileURL(named: "focus.json"))
        #endif
        session = store.file.active
        blocks = store.file.blocks

        notifications.onStart = { [weak self] sessionID, blockIndex, phase in
            guard let self else { return }
            guard FocusEngine.accepts(sessionID: sessionID, blockIndex: blockIndex, phase: phase, session: session) else {
                log.notice("Focus: stale notification action ignored")
                return
            }
            send(.start)
        }
        notifications.install()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
        send(.tick) // a phase that ran out while VibeFlow was quit
        syncTicker()
    }

    /// The selected preset and rhythm, or the running session's.
    var preset: FocusPreset { session?.preset ?? preferences.focusPreset }
    var rhythm: FocusRhythm { session?.rhythm ?? preferences.focusRhythm }

    func send(_ command: FocusCommand) {
        let now = Date()
        self.now = now
        let before = session
        let transition = FocusEngine.apply(command, to: before, preset: preferences.focusPreset,
                                           rhythm: preferences.focusRhythm, now: now)
        var next = store.file
        next.active = transition.session
        if let block = transition.logged { next.blocks.append(block) }
        guard store.commit(next) else {
            saveFailed = true
            return
        }
        saveFailed = false
        session = transition.session
        blocks = next.blocks

        if command == .start, before == nil { notifications.requestPermission() }
        if transition.ended != nil {
            chime?.stop()
            chime?.play()
        }
        if let session, case .awaiting(let phase) = session.stage {
            if session.stage != before?.stage { notifications.post(for: phase, session: session) }
        } else {
            notifications.removeDelivered()
        }
        syncTicker()
    }

    func selectPreset(_ preset: FocusPreset) {
        preferences.focusPreset = preset
        if session != nil { send(.select(preset, preferences.focusRhythm)) }
    }

    /// The Custom steppers; a running Custom session picks the change up from its next phase.
    func setCustom(_ rhythm: FocusRhythm) {
        preferences.focusCustom = rhythm.clamped
        if session?.preset == .custom { send(.select(.custom, preferences.focusCustom)) }
    }

    /// The start/pause shortcut: one key starts, pauses and resumes.
    func toggle() {
        send(FocusEngine.toggle(session))
    }

    /// A running phase reached its deadline while VibeFlow watched it. With auto-advance the
    /// next phase starts at once; a phase that ran out during sleep or while quit still waits.
    private func phaseRanOut() {
        send(.tick)
        if preferences.focusAutoAdvance, case .awaiting = session?.stage { send(.start) }
    }

    /// History's right-click Delete, saved before it shows like every other change.
    func deleteRound(_ id: FocusBlock.ID) {
        if store.delete(id) {
            saveFailed = false
            blocks = store.file.blocks
        } else {
            saveFailed = true
        }
    }


    private func syncTicker() {
        guard case .running = session?.stage else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                now = Date()
                if case .running(_, let deadline) = session?.stage, deadline <= now { phaseRanOut() }
            }
        }
    }
}

// MARK: - Notifications

private let requestID = "one.floo.vibeflow.focus.phase-ended"
private let startAction = NotificationRoute.focusStartAction
private let breakCategory = "one.floo.vibeflow.focus.break"
private let focusCategory = "one.floo.vibeflow.focus.focus"

/// One silent notification at a time ("Focus done. Start break?") with a button that starts the
/// awaited phase. The chime is the only sound. The delegate is set at launch, from
/// AppContainer, so the button works even if the menu was never opened.
@MainActor
final class FocusNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onStart: ((UUID, Int, FocusPhase) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: breakCategory,
                                   actions: [UNNotificationAction(identifier: startAction, title: "Start break")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: focusCategory,
                                   actions: [UNNotificationAction(identifier: startAction, title: "Start focus")],
                                   intentIdentifiers: []),
        ])
    }

    /// Asked on the first Start; without it the chime and the "Break?" label still work.
    func requestPermission() {
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { log.notice("Focus notifications: \(error.localizedDescription, privacy: .public)") }
            log.notice("Focus notifications allowed=\(granted, privacy: .public)")
        }
    }

    func post(for phase: FocusPhase, session: FocusSession) {
        let content = UNMutableNotificationContent()
        let minutes = session.rhythm.minutes(for: phase)
        if phase.isBreak {
            content.title = "Pomodoro: focus done"
            content.body = phase == .longBreak ? "Time for a \(minutes)-minute long break." : "Time for a \(minutes)-minute break."
            content.categoryIdentifier = breakCategory
        } else {
            content.title = "Pomodoro: break over"
            content.body = "Ready for \(minutes) minutes of focus?"
            content.categoryIdentifier = focusCategory
        }
        content.sound = nil
        content.userInfo = ["session": session.id.uuidString, "block": session.blockIndex, "phase": phase.rawValue]
        // The same identifier replaces an older one, e.g. after a preset change while waiting.
        center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil)) { error in
            if let error { log.notice("Focus notification not posted: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func removeDelivered() {
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Routes every click through NotificationRoute (file transcription eng review R4).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let route = NotificationRoute.from(category: content.categoryIdentifier, action: response.actionIdentifier,
                                           userInfo: content.userInfo)
        await MainActor.run {
            switch route {
            case .startFocusPhase(let session, let block, let phase): self.onStart?(session, block, phase)
            case .openTranscript(let id): self.onOpenTranscript?(id)
            case .none: break
            }
        }
    }

    // MARK: Transcript ready (file transcription D10)

    var onOpenTranscript: ((UUID) -> Void)?

    /// Asked the first time a file is transcribed (eng review D1); Focus asks on its first Start.
    func requestPermissionForTranscripts() {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            log.notice("Transcript notifications allowed=\(granted, privacy: .public)")
        }
    }

    func postTranscriptReady(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = NotificationRoute.transcriptCategory
        content.userInfo = [NotificationRoute.transcriptKey: id.uuidString]
        content.sound = nil
        center.add(UNNotificationRequest(identifier: "one.floo.vibeflow.transcript.\(id.uuidString)", content: content, trigger: nil)) { error in
            if let error { log.notice("Transcript notification not posted: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
