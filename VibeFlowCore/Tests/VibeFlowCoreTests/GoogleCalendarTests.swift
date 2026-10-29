import Foundation
import Testing
@testable import VibeFlowCore

private let config = GoogleOAuthConfig(clientID: "client-123.apps.googleusercontent.com", clientSecret: "GOCSPX-test")
private let me = "florian@example.com"
private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }
private let window = DateInterval(start: utc("2026-10-28T17:00:00Z"), end: utc("2026-10-30T17:00:00Z"))

/// Answers each request with a handler, so one test can script refresh, list and paging.
private final class ScriptedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: @Sendable (URLRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        return try handler(request)
    }
}

private func json(_ text: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, body: Data(text.utf8)) }
private func form(_ request: URLRequest) -> [String: String] {
    let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
        let parts = $0.split(separator: "=", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : "")
    })
}
private func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private let meetingJSON = """
{"id":"%@","summary":"Standup","start":{"dateTime":"2026-10-29T09:00:00Z"},"end":{"dateTime":"2026-10-29T09:30:00Z"},
 "attendees":[{"email":"florian@example.com"},{"email":"alex@example.com"}]}
"""
private func meeting(_ id: String) -> String { String(format: meetingJSON, id) }

@Suite struct GoogleOAuthTests {
    /// Expected value from `printf %s <verifier> | openssl dgst -sha256 -binary | base64`, URL-safe, unpadded.
    @Test func pkceChallengeIsS256() {
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r7wW1gFWFOEjXk")
        #expect(pkce.challenge == "bwWFMyPfdG9qreDhH2lmftFx_dFeLDalzcT1gb_j68g")
    }

    @Test func randomTokensAreURLSafeAndDiffer() {
        let a = GoogleOAuth.randomToken(bytes: 32), b = GoogleOAuth.randomToken(bytes: 32)
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func authorizationURLCarriesPKCEStateAndOffline() {
        let pkce = GoogleOAuth.PKCE(verifier: "v")
        let url = GoogleOAuth.authorizationURL(config: config, redirectURI: "http://127.0.0.1:51234", pkce: pkce, state: "s1", loginHint: me)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.host() == "accounts.google.com")
        #expect(items["client_id"] == config.clientID)
        #expect(items["redirect_uri"] == "http://127.0.0.1:51234")
        #expect(items["scope"] == "https://www.googleapis.com/auth/calendar.readonly")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "s1")
        #expect(items["access_type"] == "offline")
        #expect(items["login_hint"] == me)
        #expect(items["client_secret"] == nil)
        // Value: protects=consent URL always forces consent and omits login_hint when none is given; fails_when=prompt=consent is dropped (no refresh token on re-sign-in) or an empty login_hint leaks in; why_new=the test above never read prompt nor the nil-hint branch; seam=none; no_claim=Google's acceptance of the URL (unit only)
        #expect(items["prompt"] == "consent")
        let noHint = GoogleOAuth.authorizationURL(config: config, redirectURI: "http://127.0.0.1:51234", pkce: pkce, state: "s1")
        #expect(URLComponents(url: noHint, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "login_hint" } == false)
    }

    @Test func callbackParsing() {
        func parse(_ target: String) -> Result<String, GoogleOAuth.CallbackError>? {
            GoogleOAuth.parseCallback(requestTarget: target, expectedState: "s1")
        }
        #expect(parse("/?state=s1&code=4/0Ab&scope=x") == .success("4/0Ab"))
        #expect(parse("/?state=evil&code=4/0Ab") == .failure(.stateMismatch))
        #expect(parse("/?code=4/0Ab") == .failure(.stateMismatch))
        #expect(parse("/?state=s1&error=access_denied") == .failure(.accessDenied))
        #expect(parse("/?state=s1&error=admin_policy_enforced") == .failure(.adminPolicyEnforced))
        #expect(parse("/?state=s1&error=server_error") == .failure(.other("server_error")))
        #expect(parse("/?state=s1") == .failure(.missingCode))
        #expect(parse("/favicon.ico") == nil)
        #expect(parse("/") == nil)
    }

    @Test func exchangeSendsSecretAndVerifier() {
        let request = GoogleOAuth.codeExchangeRequest(config: config, code: "4/0Ab+c", verifier: "ver", redirectURI: "http://127.0.0.1:51234")
        let fields = form(request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "4/0Ab+c")
        #expect(fields["code_verifier"] == "ver")
        #expect(fields["client_secret"] == "GOCSPX-test")
        #expect(fields["redirect_uri"] == "http://127.0.0.1:51234")
    }

    // Value: protects=refresh and revoke form bodies match Google's token and revoke endpoints; fails_when=a field name or grant_type changes, or revoke stops posting to the revoke endpoint; why_new=only the code-exchange body was asserted; seam=none; no_claim=Google's acceptance of the bodies (no network; unit only)
    @Test func refreshAndRevokeRequests() {
        let refresh = GoogleOAuth.refreshRequest(config: config, refreshToken: "1//r+t")
        #expect(refresh.url == GoogleOAuth.tokenEndpoint)
        #expect(refresh.httpMethod == "POST")
        #expect(form(refresh) == ["grant_type": "refresh_token", "refresh_token": "1//r+t",
                                  "client_id": config.clientID, "client_secret": "GOCSPX-test"])
        let revoke = GoogleOAuth.revokeRequest(token: "1//r+t")
        #expect(revoke.url == GoogleOAuth.revokeEndpoint)
        #expect(revoke.httpMethod == "POST")
        #expect(form(revoke) == ["token": "1//r+t"])
    }

    @Test func configComesFromInfoPlistOrIsMissing() {
        #expect(GoogleOAuthConfig(infoDictionary: ["GoogleClientID": "id", "GoogleClientSecret": "secret"]) == GoogleOAuthConfig(clientID: "id", clientSecret: "secret"))
        #expect(GoogleOAuthConfig(infoDictionary: ["GoogleClientID": "", "GoogleClientSecret": ""]) == nil)
        #expect(GoogleOAuthConfig(infoDictionary: nil) == nil)
    }
}

@Suite struct GoogleCalendarClientTests {
    @Test func exchangeWithoutRefreshTokenFails() async {
        let client = GoogleCalendarClient(http: ScriptedHTTPClient { _ in json(#"{"access_token":"a","expires_in":3599}"#) }, config: config)
        await #expect(throws: GoogleCalendarError.noRefreshToken) {
            try await client.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        }
    }

    // Value: protects=a sign-in with calendar access unticked fails with its own error instead of a sign-in that 403s forever; fails_when=the granted scope is not checked or the check rejects a full grant; why_new=scope was never read; seam=none; no_claim=Google's real consent payload (scripted HTTP)
    @Test func exchangeRequiresCalendarAccess() async throws {
        func exchanging(scope: String) async throws -> GoogleTokens {
            let body = #"{"access_token":"a","refresh_token":"r","scope":"\#(scope)"}"#
            return try await GoogleCalendarClient(http: ScriptedHTTPClient { _ in json(body) }, config: config)
                .exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        }
        await #expect(throws: GoogleCalendarError.calendarAccessNotGranted) { try await exchanging(scope: "openid email") }
        let granted = try await exchanging(scope: "openid https://www.googleapis.com/auth/calendar.readonly")
        #expect(granted.refreshToken == "r")
    }

    @Test func refreshErrorsAreMapped() async {
        func refreshing(_ response: HTTPResponse) async -> GoogleCalendarError? {
            let client = GoogleCalendarClient(http: ScriptedHTTPClient { _ in response }, config: config)
            do { _ = try await client.refresh(refreshToken: "r"); return nil } catch { return error as? GoogleCalendarError }
        }
        #expect(await refreshing(json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400)) == .invalidGrant)
        #expect(await refreshing(json(#"{"error":"admin_policy_enforced"}"#, status: 400)) == .adminPolicyEnforced)
        #expect(await refreshing(json("oops", status: 500)) == .http(500))
        #expect(await refreshing(json("not json")) == .malformed)
    }

    @Test func networkErrorsMeanOffline() async {
        let client = GoogleCalendarClient(http: ScriptedHTTPClient { _ in throw URLError(.notConnectedToInternet) }, config: config)
        await #expect(throws: GoogleCalendarError.offline) { try await client.refresh(refreshToken: "r") }
    }

    // Value: protects=transport errors map to cancel (dropped), offline (kept list) or http(code), and revoke never throws; fails_when=cancel is reported as a sync failure or timeouts stop meaning offline; why_new=only notConnectedToInternet was covered; seam=none; no_claim=real URLSession error codes (scripted HTTP client; unit only)
    @Test func transportErrorsAreMapped() async {
        func refreshing(_ error: URLError.Code) async -> any Error {
            let client = GoogleCalendarClient(http: ScriptedHTTPClient { _ in throw URLError(error) }, config: config)
            do { _ = try await client.refresh(refreshToken: "r"); return GoogleCalendarError.malformed } catch { return error }
        }
        #expect(await refreshing(.cancelled) is CancellationError)
        #expect(await refreshing(.timedOut) as? GoogleCalendarError == .offline)
        #expect(await refreshing(.networkConnectionLost) as? GoogleCalendarError == .offline)
        #expect(await refreshing(.badServerResponse) as? GoogleCalendarError == .http(URLError.Code.badServerResponse.rawValue))

        let http = ScriptedHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        await GoogleCalendarClient(http: http, config: config).revoke(token: "1//r")
        #expect(http.requests.map(\.url) == [GoogleOAuth.revokeEndpoint])
    }

    // Value: protects=a calendar list without a primary entry or an undecodable page fails as malformed; fails_when=fetch guesses the email from another calendar or a bad page decodes as empty; why_new=fetch tests always had a primary calendar and valid JSON; seam=none; no_claim=Google's real payloads (scripted HTTP client; unit only)
    @Test func missingPrimaryOrBadPageIsMalformed() async {
        let noPrimary = ScriptedHTTPClient { request in
            request.url!.absoluteString.hasPrefix(GoogleOAuth.tokenEndpoint.absoluteString)
                ? json(#"{"access_token":"fresh","expires_in":3599}"#)
                : json(#"{"items":[{"id":"team@example.com","accessRole":"reader"}]}"#)
        }
        await #expect(throws: GoogleCalendarError.malformed) {
            try await GoogleCalendarClient(http: noPrimary, config: config).fetch(refreshToken: "r", selected: nil, window: window)
        }
        let badPage = GoogleCalendarClient(http: ScriptedHTTPClient { _ in json(#"{"items":"nope"}"#) }, config: config)
        await #expect(throws: GoogleCalendarError.malformed) {
            try await badPage.events(calendarID: me, in: window, accessToken: "tok")
        }
    }

    @Test func eventsFollowEveryPage() async throws {
        let http = ScriptedHTTPClient { request in
            switch query(request, "pageToken") {
            case nil: json(#"{"items":[],"nextPageToken":"p2"}"#)       // an empty first page still has more
            case "p2": json(#"{"items":[\#(meeting("a"))],"nextPageToken":"p3"}"#)
            default: json(#"{"items":[\#(meeting("b"))]}"#)
            }
        }
        let client = GoogleCalendarClient(http: http, config: config, pageSize: 1)
        let events = try await client.events(calendarID: "en.th#holiday@group.v.calendar.google.com", in: window, accessToken: "tok")
        #expect(events.map(\.id) == ["a", "b"])
        #expect(http.requests.count == 3)
        let first = try #require(http.requests.first)
        #expect(first.url?.absoluteString.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/en.th%23holiday@group.v.calendar.google.com/events?") == true)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(query(first, "singleEvents") == "true")
        #expect(query(first, "maxResults") == "1")
        #expect(query(first, "timeMin") == "2026-10-28T17:00:00Z")
        #expect(query(first, "timeMax") == "2026-10-30T17:00:00Z")
    }

    @Test func expiredAccessTokenIsUnauthorized() async {
        let client = GoogleCalendarClient(http: ScriptedHTTPClient { _ in json("{}", status: 401) }, config: config)
        await #expect(throws: GoogleCalendarError.unauthorized) { try await client.calendars(accessToken: "old") }
    }

    /// Refresh, the calendar list (two pages), then events for the selected calendars.
    private func syncServer(failEventsOn calendarID: String? = nil) -> ScriptedHTTPClient {
        ScriptedHTTPClient { request in
            let url = request.url!.absoluteString
            if url.hasPrefix(GoogleOAuth.tokenEndpoint.absoluteString) { return json(#"{"access_token":"fresh","expires_in":3599}"#) }
            if url.contains("/users/me/calendarList") {
                return query(request, "pageToken") == nil
                    ? json(#"{"items":[{"id":"colleague@example.com","accessRole":"owner"}],"nextPageToken":"c2"}"#)
                    : json(#"{"items":[{"id":"florian@example.com","primary":true,"accessRole":"owner"}]}"#)
            }
            if let calendarID, url.contains("/calendars/\(calendarID)/") { return json("{}", status: 503) }
            if url.contains("/calendars/colleague@example.com/") { return json(#"{"items":[\#(meeting("shared")),\#(meeting("theirs"))]}"#) }
            return json(#"{"items":[\#(meeting("shared"))]}"#)
        }
    }

    @Test func fetchDefaultsToYourCalendarAndUsesTheFreshToken() async throws {
        let http = syncServer()
        let fetch = try await GoogleCalendarClient(http: http, config: config).fetch(refreshToken: "r", selected: nil, window: window)
        #expect(fetch.email == me)
        #expect(fetch.calendars.map(\.id) == ["colleague@example.com", me])
        #expect(fetch.events.map(\.calendarID) == [me])
        #expect(http.requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" })
    }

    @Test func fetchReadsSelectedCalendarsYoursFirstAndSkipsUnknown() async throws {
        let fetch = try await GoogleCalendarClient(http: syncServer(), config: config)
            .fetch(refreshToken: "r", selected: ["colleague@example.com", "gone@example.com", me], window: window)
        #expect(fetch.events.map(\.calendarID) == [me, "colleague@example.com"])
        #expect(fetch.meetings.map(\.id) == ["shared", "theirs"])
        #expect(fetch.meetings.first?.calendarID == me)
    }

    // Value: protects=after switching accounts the saved calendars of the old account fall back to yours, while an empty choice stays empty; fails_when=unknown saved ids silently fetch nothing or an empty selection is overridden; why_new=only a mix of known and unknown ids was tested; seam=none; no_claim=none beyond protects
    @Test func savedCalendarsFromAnotherAccountFallBackToYours() async throws {
        let client = GoogleCalendarClient(http: syncServer(), config: config)
        let switched = try await client.fetch(refreshToken: "r", selected: ["old@example.com"], window: window)
        #expect(switched.events.map(\.calendarID) == [me])
        let none = try await client.fetch(refreshToken: "r", selected: [], window: window)
        #expect(none.events.isEmpty)
    }

    @Test func oneFailedCalendarFailsTheWholeFetch() async {
        let client = GoogleCalendarClient(http: syncServer(failEventsOn: "colleague@example.com"), config: config)
        await #expect(throws: GoogleCalendarError.http(503)) {
            try await client.fetch(refreshToken: "r", selected: [me, "colleague@example.com"], window: window)
        }
    }
}

@Suite struct MeetingsSyncTests {
    private let t0 = utc("2026-10-29T08:00:00Z")
    private let t1 = utc("2026-10-29T08:05:00Z")
    private var fetch: MeetingsFetch {
        let event = CalendarEvent(id: "m", summary: "Standup", start: .init(dateTime: "2026-10-29T09:00:00Z"),
                                  end: .init(dateTime: "2026-10-29T09:30:00Z"),
                                  attendees: [.init(email: me), .init(email: "alex@example.com")])
        return MeetingsFetch(email: me, calendars: [.init(id: me, primary: true)], events: [.init(calendarID: me, events: [event])])
    }
    private func signedIn() -> MeetingsSyncState {
        var state = MeetingsSyncState()
        let generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .fetched(fetch), at: t0)
        return state
    }

    @Test func firstSyncShowsSyncingThenSignedIn() {
        var state = MeetingsSyncState()
        let generation = MeetingsSync.begin(&state, afterSignIn: true)
        #expect(state.status == .syncing)
        MeetingsSync.finish(&state, generation: generation, outcome: .fetched(fetch), at: t0)
        #expect(state.status == .signedIn(email: me, lastSynced: t0))
        #expect(state.meetings.map(\.id) == ["m"])
        #expect(state.email == me)
        // Later syncs keep the signed-in line while they run.
        _ = MeetingsSync.begin(&state)
        #expect(state.status == .signedIn(email: me, lastSynced: t0))
    }

    @Test func signOutDuringAFetchDropsItsResult() {
        var state = signedIn()
        let generation = MeetingsSync.begin(&state)
        MeetingsSync.signOut(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .fetched(fetch), at: t1)
        #expect(state.status == .signedOut)
        #expect(state.meetings.isEmpty)
    }

    @Test func calendarChangeDuringAFetchKeepsOnlyTheNewest() {
        var state = signedIn()
        let old = MeetingsSync.begin(&state)
        let new = MeetingsSync.begin(&state)
        var newer = fetch
        newer.events = []
        MeetingsSync.finish(&state, generation: new, outcome: .fetched(newer), at: t1)
        MeetingsSync.finish(&state, generation: old, outcome: .fetched(fetch), at: t1)
        #expect(state.meetings.isEmpty)
        #expect(state.lastSynced == t1)
    }

    @Test func offlineKeepsTheLastListThenRecovers() {
        var state = signedIn()
        var generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.offline), at: t1)
        #expect(state.status == .offline(lastSynced: t0))
        #expect(state.meetings.map(\.id) == ["m"])

        generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .fetched(fetch), at: t1)
        #expect(state.status == .signedIn(email: me, lastSynced: t1))
    }

    @Test func revokedOrBlockedClearsEverything() {
        var state = signedIn()
        var generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.invalidGrant), at: t1)
        #expect(state.status == .signInExpired)
        #expect(state.meetings.isEmpty && state.email == nil && state.calendars.isEmpty)

        state = signedIn()
        generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.adminPolicyEnforced), at: t1)
        #expect(state.status == .blocked)
        #expect(state.meetings.isEmpty)

        // Value: protects=an exchange without a refresh token reads as sign-in expired and clears the list; fails_when=noRefreshToken falls through to a generic failure that keeps stale meetings; why_new=only invalidGrant was driven through finish; seam=none; no_claim=none beyond protects
        state = signedIn()
        generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.noRefreshToken), at: t1)
        #expect(state.status == .signInExpired)
        #expect(state.meetings.isEmpty && state.email == nil && state.lastSynced == nil)
    }

    @Test func keychainTroubleIsNotSignedOut() {
        var state = signedIn()
        var generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .keychainUnavailable, at: t1)
        #expect(state.status == .keychainUnavailable)
        #expect(state.meetings.map(\.id) == ["m"])

        generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .noToken, at: t1)
        #expect(state.status == .signedOut)
        #expect(state.meetings.isEmpty)
    }

    @Test func otherErrorsKeepTheListAndSayWhy() {
        var state = signedIn()
        let generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.http(503)), at: t1)
        #expect(state.status == .failed("HTTP 503", lastSynced: t0))
        #expect(state.meetings.map(\.id) == ["m"])
    }

    // Value: protects=every outcome of a superseded fetch is dropped, not only .fetched; fails_when=finish applies an old noToken/invalidGrant/offline result after a newer begin or a sign-out; why_new=only .fetched was driven through a stale generation; seam=none; no_claim=none beyond protects
    @Test(arguments: [MeetingsFetchOutcome.noToken, .keychainUnavailable, .failed(.invalidGrant), .failed(.noRefreshToken),
                      .failed(.adminPolicyEnforced), .failed(.offline), .failed(.http(500))])
    func staleOutcomesAreDropped(_ outcome: MeetingsFetchOutcome) {
        var state = signedIn()
        let stale = MeetingsSync.begin(&state)
        _ = MeetingsSync.begin(&state)
        let before = state
        MeetingsSync.finish(&state, generation: stale, outcome: outcome, at: t1)
        #expect(state == before)

        MeetingsSync.signOut(&state)
        let signedOut = state
        MeetingsSync.finish(&state, generation: stale, outcome: outcome, at: t1)
        #expect(state == signedOut)
    }

    // Value: protects="Signed out: sign in again" survives the next sync and background syncs never flash Syncing; fails_when=noToken after an expiry resets the reason, or begin sets syncing on every tick; why_new=the expiry was only checked right after invalidGrant; seam=none; no_claim=none beyond protects
    @Test func expiredStaysExpiredAndBackgroundSyncsDoNotFlicker() {
        var state = signedIn()
        var generation = MeetingsSync.begin(&state)
        MeetingsSync.finish(&state, generation: generation, outcome: .failed(.invalidGrant), at: t1)
        generation = MeetingsSync.begin(&state)
        #expect(state.status == .signInExpired)
        MeetingsSync.finish(&state, generation: generation, outcome: .noToken, at: t1)
        #expect(state.status == .signInExpired)

        var signedOut = MeetingsSyncState()
        generation = MeetingsSync.begin(&signedOut)
        #expect(signedOut.status == .signedOut)
        MeetingsSync.finish(&signedOut, generation: generation, outcome: .noToken, at: t1)
        #expect(signedOut.status == .signedOut)
    }

    // Value: protects=readable failure reasons and the failed line format in the Meetings tab; fails_when=unauthorized/malformed/calendar-access fall back to a raw enum dump or the line format changes; why_new=only HTTP 503 was asserted; seam=none; no_claim=none beyond protects
    @Test func failureReasonsAreReadable() {
        for (error, reason) in [(GoogleCalendarError.unauthorized, "access refused"), (.malformed, "unexpected answer from Google"),
                                (.calendarAccessNotGranted, "calendar access not allowed")] {
            var state = signedIn()
            let generation = MeetingsSync.begin(&state)
            MeetingsSync.finish(&state, generation: generation, outcome: .failed(error), at: t1)
            #expect(state.status == .failed(reason, lastSynced: t0))
        }
        #expect(MeetingsStatus.failed("HTTP 503", lastSynced: t0).line(timeZone: TimeZone(identifier: "UTC")!)
                == "Sync failed (HTTP 503), last synced 08:00")
    }

    @Test func statusLines() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(MeetingsStatus.signedIn(email: me, lastSynced: t0).line(timeZone: utc) == "Signed in as florian@example.com, last synced 08:00")
        #expect(MeetingsStatus.signInExpired.line() == "Signed out: sign in again")
        #expect(MeetingsStatus.blocked.line() == "Blocked by your Google Workspace admin")
        #expect(MeetingsStatus.offline(lastSynced: t0).line(timeZone: utc) == "Offline, last synced 08:00")
        #expect(MeetingsStatus.offline(lastSynced: nil).line() == "Offline")
        #expect(MeetingsStatus.keychainUnavailable.line() == "Keychain unavailable, retrying")
        #expect(MeetingsStatus.notConfigured.line() == "Not configured in this build")
    }
}
