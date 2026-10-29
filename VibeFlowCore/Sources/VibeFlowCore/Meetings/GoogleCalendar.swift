import CryptoKit
import Foundation

// Google sign-in and Calendar reads for upcoming meetings (docs/designs/upcoming-meetings.md).
// Request building and callback parsing are pure; GoogleCalendarClient talks to Google through
// HTTPClient; MeetingsSync is the reducer the app's MeetingsStore calls. The loopback listener
// itself lives in the app (GoogleSignIn.swift).

/// The desktop OAuth client baked into the build from Config/Google.xcconfig (R2).
public struct GoogleOAuthConfig: Equatable, Sendable {
    public var clientID: String
    /// Not secret for desktop clients (Google says so); kept out of git all the same.
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// nil when the build has no client: the Meetings tab says "Not configured in this build".
    public init?(infoDictionary: [String: Any]?) {
        let id = (infoDictionary?["GoogleClientID"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let secret = (infoDictionary?["GoogleClientSecret"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.init(clientID: id, clientSecret: secret)
    }
}

// MARK: - OAuth (R3)

public enum GoogleOAuth {
    public static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// How long the loopback listener waits for the browser.
    public static let signInTimeout: Duration = .seconds(300)

    /// PKCE S256: the verifier stays in the app, the challenge goes in the consent URL.
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            self.challenge = GoogleOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public static func generate() -> PKCE { PKCE(verifier: randomToken(bytes: 32)) }
    }

    /// URL-safe random string for the PKCE verifier and the `state` parameter.
    public static func randomToken(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public static func authorizationURL(config: GoogleOAuthConfig, redirectURI: String, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token on every sign-in, also after a revoke.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ] + (loginHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return components.url!
    }

    public enum CallbackError: Error, Equatable, Sendable {
        /// The answer did not come from this sign-in.
        case stateMismatch
        /// You clicked Cancel on the consent screen.
        case accessDenied
        /// The Workspace admin does not trust this client.
        case adminPolicyEnforced
        case missingCode
        case other(String)
    }

    /// Reads the loopback request target ("/?state=…&code=…"). nil means the request is not the
    /// callback (favicon, a browser preconnect) and the listener keeps waiting.
    public static func parseCallback(requestTarget: String, expectedState: String) -> Result<String, CallbackError>? {
        guard requestTarget.hasPrefix("/?"),
              let items = URLComponents(string: "http://127.0.0.1" + requestTarget)?.queryItems else { return nil }
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["state"] == expectedState else { return .failure(.stateMismatch) }
        if let error = query["error"] {
            switch error {
            case "access_denied": return .failure(.accessDenied)
            case "admin_policy_enforced": return .failure(.adminPolicyEnforced)
            default: return .failure(.other(error))
            }
        }
        guard let code = query["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    public static func codeExchangeRequest(config: GoogleOAuthConfig, code: String, verifier: String, redirectURI: String) -> URLRequest {
        formPost(tokenEndpoint, [
            ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
            ("redirect_uri", redirectURI), ("client_id", config.clientID), ("client_secret", config.clientSecret),
        ])
    }

    public static func refreshRequest(config: GoogleOAuthConfig, refreshToken: String) -> URLRequest {
        formPost(tokenEndpoint, [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
            ("client_id", config.clientID), ("client_secret", config.clientSecret),
        ])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        formPost(revokeEndpoint, [("token", token)])
    }

    static func formPost(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Calendar client (R4, R11)

public enum GoogleCalendarError: Error, Equatable, Sendable {
    /// The refresh token was revoked or expired: sign in again.
    case invalidGrant
    /// The Workspace admin blocks this client.
    case adminPolicyEnforced
    case offline
    /// The access token was refused (401).
    case unauthorized
    case http(Int)
    case malformed
    /// The exchange returned no refresh token, so the sign-in cannot last.
    case noRefreshToken
    /// You unticked calendar access on Google's consent screen.
    case calendarAccessNotGranted
}

public struct GoogleCalendarEntry: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var summary: String?
    public var primary: Bool?
    public var accessRole: String?

    public init(id: String, summary: String? = nil, primary: Bool? = nil, accessRole: String? = nil) {
        self.id = id
        self.summary = summary
        self.primary = primary
        self.accessRole = accessRole
    }
}

/// One complete sync: who you are, your calendars, and every page of events per calendar.
public struct MeetingsFetch: Equatable, Sendable {
    /// The primary calendar's id, which is the signed-in email (R9).
    public var email: String
    public var calendars: [GoogleCalendarEntry]
    public var events: [CalendarFetch]

    public struct CalendarFetch: Equatable, Sendable {
        public var calendarID: String
        public var events: [CalendarEvent]
        public init(calendarID: String, events: [CalendarEvent]) {
            self.calendarID = calendarID
            self.events = events
        }
    }

    public init(email: String, calendars: [GoogleCalendarEntry], events: [CalendarFetch]) {
        self.email = email
        self.calendars = calendars
        self.events = events
    }

    public var meetings: [Meeting] {
        MeetingFilter.meetings(from: events.map { ($0.calendarID, $0.events) }, me: email)
    }
}

public struct GoogleTokens: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// The scopes Google granted, space separated; the consent screen lets you untick some.
    public var scope: String?
}

public final class GoogleCalendarClient: Sendable {
    public static let apiBase = URL(string: "https://www.googleapis.com/calendar/v3/")!

    private let http: any HTTPClient
    private let config: GoogleOAuthConfig
    /// Google's page size; small in tests to exercise paging.
    private let pageSize: Int

    public init(http: any HTTPClient, config: GoogleOAuthConfig, pageSize: Int = 250) {
        self.http = http
        self.config = config
        self.pageSize = pageSize
    }

    /// The end of sign-in: trade the callback code for tokens.
    public func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleTokens {
        let tokens = try await token(GoogleOAuth.codeExchangeRequest(config: config, code: code, verifier: verifier, redirectURI: redirectURI))
        guard tokens.refreshToken != nil else { throw GoogleCalendarError.noRefreshToken }
        if let scope = tokens.scope, !scope.split(separator: " ").contains(Substring(GoogleOAuth.scope)) {
            throw GoogleCalendarError.calendarAccessNotGranted
        }
        return tokens
    }

    public func refresh(refreshToken: String) async throws -> GoogleTokens {
        try await token(GoogleOAuth.refreshRequest(config: config, refreshToken: refreshToken))
    }

    /// Best effort on sign-out; failures are ignored (the token is forgotten either way).
    public func revoke(token: String) async {
        _ = try? await http.send(GoogleOAuth.revokeRequest(token: token))
    }

    /// Every page of the calendar list.
    public func calendars(accessToken: String) async throws -> [GoogleCalendarEntry] {
        struct Page: Decodable { let items: [GoogleCalendarEntry]?; let nextPageToken: String? }
        let pages: [Page] = try await allPages("users/me/calendarList", [URLQueryItem(name: "maxResults", value: String(pageSize))],
                                               bearer: accessToken, next: \.nextPageToken)
        return pages.flatMap { $0.items ?? [] }
    }

    /// Every page of one calendar's events in the window, recurring events expanded.
    public func events(calendarID: String, in window: DateInterval, accessToken: String) async throws -> [CalendarEvent] {
        struct Page: Decodable { let items: [CalendarEvent]?; let nextPageToken: String? }
        let iso = Date.ISO8601FormatStyle()
        let query = [
            URLQueryItem(name: "timeMin", value: window.start.formatted(iso)),
            URLQueryItem(name: "timeMax", value: window.end.formatted(iso)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(pageSize)),
        ]
        let path = "calendars/\(Self.pathSegment(calendarID))/events"
        let pages: [Page] = try await allPages(path, query, bearer: accessToken, next: \.nextPageToken)
        return pages.flatMap { $0.items ?? [] }
    }

    /// One whole sync. All or nothing: a failed page fails the fetch, so the caller keeps its
    /// last complete snapshot instead of half a day (R11). `selected` nil means your own calendar.
    public func fetch(refreshToken: String, selected: [String]?, window: DateInterval) async throws -> MeetingsFetch {
        let accessToken = try await refresh(refreshToken: refreshToken).accessToken
        let calendars = try await calendars(accessToken: accessToken)
        guard let email = calendars.first(where: { $0.primary == true })?.id else { throw GoogleCalendarError.malformed }
        let known = Set(calendars.map(\.id))
        var ids = (selected ?? [email]).filter(known.contains)
        // Saved ids that all belong to another account (signed in as someone else): use yours.
        if ids.isEmpty, selected?.isEmpty == false { ids = [email] }
        // Your own calendar first, so a meeting on two calendars keeps your copy.
        ids.sort { ($0 == email ? 0 : 1) < ($1 == email ? 0 : 1) }
        var events: [MeetingsFetch.CalendarFetch] = []
        for id in ids {
            events.append(.init(calendarID: id, events: try await self.events(calendarID: id, in: window, accessToken: accessToken)))
        }
        return MeetingsFetch(email: email, calendars: calendars, events: events)
    }

    // MARK: Plumbing

    private func token(_ request: URLRequest) async throws -> GoogleTokens {
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let scope: String? }
        struct ErrorResponse: Decodable { let error: String? }
        let response = try await send(request)
        guard response.status == 200 else {
            switch (try? JSONDecoder().decode(ErrorResponse.self, from: response.body))?.error {
            case "invalid_grant": throw GoogleCalendarError.invalidGrant
            case "admin_policy_enforced": throw GoogleCalendarError.adminPolicyEnforced
            default: throw GoogleCalendarError.http(response.status)
            }
        }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else { throw GoogleCalendarError.malformed }
        return GoogleTokens(accessToken: body.access_token, refreshToken: body.refresh_token, scope: body.scope)
    }

    private func allPages<Page: Decodable>(_ path: String, _ query: [URLQueryItem], bearer: String,
                                           next: (Page) -> String?) async throws -> [Page] {
        var pages: [Page] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: Self.apiBase.absoluteString + path)!
            components.queryItems = query + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let response = try await send(request)
            switch response.status {
            case 200: break
            case 401: throw GoogleCalendarError.unauthorized
            default: throw GoogleCalendarError.http(response.status)
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: response.body) else { throw GoogleCalendarError.malformed }
            pages.append(page)
            pageToken = next(page)
        } while pageToken != nil
        return pages
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            return try await http.send(request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                throw GoogleCalendarError.offline
            default: throw GoogleCalendarError.http(error.errorCode)
            }
        }
    }

    /// Calendar ids hold "@" and "#" ("en.th#holiday@group.v.calendar.google.com"); "#" and "/"
    /// must be escaped inside a path segment.
    static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/#?"))) ?? id
    }
}

// MARK: - Sync reducer (R1, R4, R8, R12)

/// What the Meetings tab's status line says (R1); the menu bar stays silent on failures (D2).
public enum MeetingsStatus: Equatable, Sendable {
    case notConfigured
    case signedOut
    /// The refresh token stopped working: revoked, password change, or expired.
    case signInExpired
    case syncing
    case signedIn(email: String, lastSynced: Date)
    case blocked
    case offline(lastSynced: Date?)
    case keychainUnavailable
    case failed(String, lastSynced: Date?)

    public func line(timeZone: TimeZone = .current) -> String {
        func synced(_ date: Date?) -> String { date.map { ", last synced \(ClockFormat.time($0, in: timeZone))" } ?? "" }
        return switch self {
        case .notConfigured: "Not configured in this build"
        case .signedOut: "Signed out"
        case .signInExpired: "Signed out: sign in again"
        case .syncing: "Syncing…"
        case .signedIn(let email, let date): "Signed in as \(email)\(synced(date))"
        case .blocked: "Blocked by your Google Workspace admin"
        case .offline(let date): "Offline\(synced(date))"
        case .keychainUnavailable: "Keychain unavailable, retrying"
        case .failed(let reason, let date): "Sync failed (\(reason))\(synced(date))"
        }
    }
}

public struct MeetingsSyncState: Equatable, Sendable {
    /// The generation of the newest fetch started; older results are dropped (R8).
    public var generation = 0
    /// The last complete snapshot, already filtered to meetings.
    public var meetings: [Meeting] = []
    /// For the calendar picker.
    public var calendars: [GoogleCalendarEntry] = []
    public var email: String?
    public var lastSynced: Date?
    public var status: MeetingsStatus = .signedOut

    public init() {}
}

/// How one sync attempt ended, as MeetingsStore reports it.
public enum MeetingsFetchOutcome: Sendable {
    case fetched(MeetingsFetch)
    /// No refresh token in the Keychain.
    case noToken
    /// The Keychain read failed; not the same as signed out (R12).
    case keychainUnavailable
    case failed(GoogleCalendarError)
}

/// The sync rules, so MeetingsStore only runs timers and calls these (R4).
public enum MeetingsSync {
    /// A new fetch starts (timer, wake, network back, settings change, sign-in): any fetch
    /// still running becomes stale. Returns the generation the new fetch must report with.
    /// Only the first sync after a sign-in says "Syncing…"; background syncs leave the status
    /// alone, so "Signed out" or "Blocked" does not flicker every 5 minutes.
    public static func begin(_ state: inout MeetingsSyncState, afterSignIn: Bool = false) -> Int {
        state.generation += 1
        if afterSignIn { state.status = .syncing }
        return state.generation
    }

    public static func finish(_ state: inout MeetingsSyncState, generation: Int, outcome: MeetingsFetchOutcome, at now: Date) {
        guard generation == state.generation else { return }
        switch outcome {
        case .fetched(let fetch):
            state.meetings = fetch.meetings
            state.calendars = fetch.calendars
            state.email = fetch.email
            state.lastSynced = now
            state.status = .signedIn(email: fetch.email, lastSynced: now)
        case .noToken:
            // An expired sign-in deletes its token; keep saying why until you sign in again.
            clear(&state, status: state.status == .signInExpired ? .signInExpired : .signedOut)
        case .keychainUnavailable:
            state.status = .keychainUnavailable
        case .failed(.invalidGrant), .failed(.noRefreshToken):
            clear(&state, status: .signInExpired)
        case .failed(.adminPolicyEnforced):
            clear(&state, status: .blocked)
        case .failed(.offline):
            state.status = .offline(lastSynced: state.lastSynced)
        case .failed(let error):
            state.status = .failed(reason(error), lastSynced: state.lastSynced)
        }
    }

    /// You clicked Sign out: drop everything, and make any running fetch stale.
    public static func signOut(_ state: inout MeetingsSyncState) {
        state.generation += 1
        clear(&state, status: .signedOut)
    }

    private static func clear(_ state: inout MeetingsSyncState, status: MeetingsStatus) {
        state.meetings = []
        state.calendars = []
        state.email = nil
        state.lastSynced = nil
        state.status = status
    }

    private static func reason(_ error: GoogleCalendarError) -> String {
        switch error {
        case .unauthorized: "access refused"
        case .http(let code): "HTTP \(code)"
        case .malformed: "unexpected answer from Google"
        case .calendarAccessNotGranted: "calendar access not allowed"
        default: "\(error)"
        }
    }
}
