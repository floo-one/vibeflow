import AppKit
import Foundation
import Network
import Observation
import os
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "meetings")

/// Upcoming meetings for the menu bar. Thin on purpose: it runs the sync triggers (every
/// 5 minutes, wake, network back, settings change, sign-in), keeps one fetch in flight, and
/// hands every outcome to MeetingsSync in Core, which owns the rules (R4, R8).
@MainActor
@Observable
final class MeetingsStore {
    static let syncInterval: Duration = .seconds(5 * 60)

    private(set) var state = MeetingsSyncState()
    private(set) var isSigningIn = false
    /// The last sign-in problem, shown under the Sign in button until the next attempt.
    private(set) var signInMessage: String?

    /// nil when the build has no Google client (R2).
    let config: GoogleOAuthConfig?
    @ObservationIgnored private let client: GoogleCalendarClient?
    @ObservationIgnored private let secrets: any SecretsStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let googleSignIn = GoogleSignIn()
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    /// Bumped per Sign in click, so a cancelled attempt winding down cannot reset the new one.
    @ObservationIgnored private var signInAttempt = 0
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init(config: GoogleOAuthConfig?, secrets: any SecretsStore, preferences: Preferences, http: any HTTPClient) {
        self.config = config
        self.secrets = secrets
        self.preferences = preferences
        client = config.map { GoogleCalendarClient(http: http, config: $0) }
        if config == nil { state.status = .notConfigured }
    }

    /// First sync and the triggers. Call once at launch.
    func start() {
        guard config != nil else { return }
        sync(firstSync: true)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard let self else { return }
                sync()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        let wasOnline = OSAllocatedUnfairLock(initialState: true)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cameBack = wasOnline.withLock { was in
                defer { was = online }
                return online && !was
            }
            if cameBack { Task { @MainActor in self?.sync() } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "one.floo.vibeflow.meetings-network"))
    }

    /// What the menu bar item shows at `now` (M2).
    func nudge(at now: Date) -> MeetingNudge {
        guard preferences.meetingsEnabled else { return .hidden }
        return MeetingSchedule.nudge(for: state.meetings, at: now, leadMinutes: preferences.meetingsLeadMinutes)
    }

    /// Fetch now. A fetch still running is cancelled and its result dropped (R8); the new one
    /// waits for it to wind down, so token refreshes never overlap. With meetings switched off
    /// only the first sync (launch, sign-in) runs, so the tab still shows who is signed in;
    /// background triggers then leave a running fetch alone.
    func sync(firstSync: Bool = false) {
        guard let client, preferences.meetingsEnabled || firstSync else { return }
        let previous = fetchTask
        previous?.cancel()
        let generation = MeetingsSync.begin(&state, firstSync: firstSync)
        let selected = preferences.meetingsCalendars
        let window = MeetingSchedule.fetchWindow(at: Date())
        let secrets = secrets
        fetchTask = Task { [weak self] in
            await previous?.value
            guard let outcome = await Self.fetch(client: client, secrets: secrets, selected: selected, window: window) else { return }
            self?.finish(generation: generation, outcome: outcome)
        }
    }

    /// Opens Google's consent screen; on success saves the refresh token and syncs.
    func signIn() {
        guard let config, let client else { return }
        signInTask?.cancel()
        signInMessage = nil
        isSigningIn = true
        signInAttempt += 1
        let attempt = signInAttempt
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { if attempt == signInAttempt { isSigningIn = false } }
            do throws(GoogleSignInError) {
                let tokens = try await googleSignIn.signIn(config: config, client: client)
                // Cancel can land while the code exchange is in flight: never save that sign-in.
                guard let refreshToken = tokens.refreshToken, attempt == signInAttempt, !Task.isCancelled else { return }
                do {
                    try secrets.write(refreshToken, for: .googleRefreshToken)
                } catch {
                    signInMessage = "Could not save the sign-in to the Keychain"
                    log.error("Google token save failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                log.notice("Google sign-in finished")
                sync(firstSync: true)
            } catch {
                if error != .cancelled, attempt == signInAttempt { signInMessage = error.message }
                log.notice("Google sign-in ended: \(error.message, privacy: .public)")
            }
        }
    }

    /// Stops the whole attempt: the browser wait and a code exchange already in flight.
    func cancelSignIn() {
        googleSignIn.cancel()
        signInTask?.cancel()
        signInAttempt += 1
        isSigningIn = false
    }

    /// Forgets the sign-in on this Mac only. Revoking at Google would end the whole grant, and
    /// with it VibeFlow on your other Macs and the other build (Dev or release); remove the
    /// grant at myaccount.google.com/permissions instead.
    func signOut() {
        do {
            try secrets.delete(.googleRefreshToken)
        } catch {
            signInMessage = "Could not remove the sign-in from the Keychain"
            log.error("Google token delete failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        fetchTask?.cancel()
        cancelSignIn()
        MeetingsSync.signOut(&state)
        // The calendar choice belongs to this account; the next one starts from its own calendar.
        preferences.meetingsCalendars = nil
        signInMessage = nil
    }

    private func finish(generation: Int, outcome: MeetingsFetchOutcome) {
        MeetingsSync.finish(&state, generation: generation, outcome: outcome, at: Date())
        guard generation == state.generation else { return }
        switch outcome {
        case .fetched(let fetch):
            // Saved calendars that no longer exist (another account, unshared): start over from
            // yours, so the toggles show what is actually watched.
            let ids = Set(fetch.calendars.map(\.id))
            if let saved = preferences.meetingsCalendars, !saved.isEmpty, !saved.contains(where: ids.contains) {
                preferences.meetingsCalendars = nil
            }
            log.notice("Meetings synced: \(fetch.meetings.count, privacy: .public) meetings from \(fetch.events.count, privacy: .public) calendars")
        case .failed(.invalidGrant):
            // Google no longer accepts the token; keeping it would fail every 5 minutes.
            try? secrets.delete(.googleRefreshToken)
            log.notice("Meetings sync: sign-in expired")
        case .failed(let error):
            log.notice("Meetings sync failed: \(String(describing: error), privacy: .public)")
        case .noToken, .keychainUnavailable:
            log.notice("Meetings sync skipped: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Off the main actor (a nonisolated async function), so the Keychain read and the network
    /// never block the menu bar; cancelling the fetch task cancels the requests. nil when cancelled.
    nonisolated private static func fetch(client: GoogleCalendarClient, secrets: any SecretsStore,
                                          selected: [String]?, window: DateInterval) async -> MeetingsFetchOutcome? {
        let token: String?
        do {
            token = try secrets.readOnDemand(.googleRefreshToken)
        } catch {
            return .keychainUnavailable
        }
        guard let token else { return .noToken }
        do {
            return .fetched(try await client.fetch(refreshToken: token, selected: selected, window: window))
        } catch let error as GoogleCalendarError {
            return .failed(error)
        } catch is CancellationError {
            // Our own cancel drops the result; a request cancelled under us reads as offline.
            return Task.isCancelled ? nil : .failed(.offline)
        } catch {
            return .failed(.malformed)
        }
    }
}
