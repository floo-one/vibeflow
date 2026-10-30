// Upcoming meetings, task T1b: Google Calendar sign-in spike (R7).
//
// Proves the shipping flow on a real account before any feature code:
//   1. loopback sign-in: PKCE S256 + state, one-shot listener on 127.0.0.1:<ephemeral>,
//      5 min timeout, client_secret sent on the code exchange
//   2. one refresh-token exchange (the refreshed access token is used for everything below)
//   3. calendarList (all pages), "you" = the primary calendar id (R9)
//   4. today's events (all pages, R12), each with the M5 keep/drop verdict and its join link
// If Google answers admin_policy_enforced, the GLE admin must trust the client ID: stop there.
//
// Usage (Command Line Tools are enough):
//   swift Spike/google-calendar-spike.swift
//   options: --login you@example.com   pre-fill the account in the consent screen
//            --calendar <id>                   list this calendar too (repeatable; default primary)
//            --page-size 3                     small pages, to see paging work on a busy day
//            --revoke                          revoke the grant at the end
//            --no-browser                      only print the consent URL
//
// Client ID and secret come from Config/Google.xcconfig (gitignored, see the .example) or the
// environment: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET. Tokens are never printed or saved.

import CryptoKit
import Foundation
import Network

// MARK: - Options and client

struct Options {
    var login: String?
    var calendars: [String] = []
    var pageSize: Int?
    var revoke = false
    var openBrowser = true

    init(_ args: [String]) throws {
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw SpikeError.usage("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--login": login = try value()
            case "--calendar": calendars.append(try value())
            case "--page-size":
                guard let n = Int(try value()), (1...2500).contains(n) else { throw SpikeError.usage("--page-size 1...2500") }
                pageSize = n
            case "--revoke": revoke = true
            case "--no-browser": openBrowser = false
            default: throw SpikeError.usage("unknown option \(args[i])")
            }
            i += 1
        }
    }
}

struct Client {
    let id: String
    let secret: String

    static func load() throws -> Client {
        var values: [String: String] = [:]
        if let text = try? String(contentsOfFile: "Config/Google.xcconfig", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                values[key] = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let env = ProcessInfo.processInfo.environment
        let id = env["GOOGLE_CLIENT_ID"] ?? values["GOOGLE_CLIENT_ID"] ?? ""
        let secret = env["GOOGLE_CLIENT_SECRET"] ?? values["GOOGLE_CLIENT_SECRET"] ?? ""
        guard !id.isEmpty, !secret.isEmpty else {
            throw SpikeError.usage("no client: copy Config/Google.xcconfig.example to Config/Google.xcconfig and fill it in (run from the repo root)")
        }
        return Client(id: id, secret: secret)
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case callback(String)
    case http(String, Int, String)

    var description: String {
        switch self {
        case .usage(let s): "usage: \(s)"
        case .callback(let s): "sign-in: \(s)"
        case .http(let what, let code, let body): "\(what): HTTP \(code) \(body)"
        }
    }
}

// MARK: - PKCE and URLs

func randomURLSafe(_ bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return base64URL(data)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func formEncode(_ fields: [(String, String)]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return fields
        .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
        .joined(separator: "&")
        .data(using: .utf8)!
}

let scope = "https://www.googleapis.com/auth/calendar.readonly"

// MARK: - Loopback listener

/// One-shot HTTP listener on 127.0.0.1. Ignores everything but `GET /?...` (favicon, browser
/// preconnects), answers the first callback with a page, then closes. All state lives on `queue`.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private let expectedState: String

    init(expectedState: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        ready?.resume(returning: listener.port?.rawValue ?? 0); ready = nil
                    case .failed(let error):
                        ready?.resume(throwing: error); ready = nil
                        finish(.failure(error))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [self] connection in accept(connection) }
                listener.start(queue: queue)
            }
        }
    }

    /// Waits for the redirect. Returns the query items; throws on timeout, state mismatch or `error=`.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result { continuation.resume(with: result); return }
                callback = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(.failure(SpikeError.callback("timed out after \(Int(timeout)) s, listener closed")))
                }
            }
        }
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        listener.cancel()
        callback?.resume(with: outcome); callback = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard result == nil, parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/?"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1])
        else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        let outcome: Result<[String: String], Error>
        let page: String
        if query["state"] != expectedState {
            outcome = .failure(SpikeError.callback("state mismatch, callback ignored"))
            page = "VibeFlow sign-in failed: this answer did not come from this sign-in. Close this tab and try again."
        } else if let error = query["error"] {
            outcome = .failure(SpikeError.callback("Google answered error=\(error)"))
            page = error == "admin_policy_enforced"
                ? "VibeFlow is blocked by your Google Workspace admin. Ask them to trust the VibeFlow client ID."
                : "VibeFlow sign-in did not finish (\(error)). You can close this tab."
        } else if query["code"]?.isEmpty == false {
            outcome = .success(query)
            page = "VibeFlow is signed in. You can close this tab."
        } else {
            outcome = .failure(SpikeError.callback("callback without code or error"))
            page = "VibeFlow sign-in failed: Google sent no code. Close this tab and try again."
        }
        respond(connection, status: "200 OK", body: page)
        finish(outcome)
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let escaped = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!doctype html><meta charset=utf-8><title>VibeFlow</title>"
            + "<body style=\"font:16px -apple-system,sans-serif;margin:4em auto;max-width:32em\"><p>\(escaped)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Google endpoints

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String?
}

struct CalendarListPage: Decodable {
    struct Entry: Decodable {
        let id: String
        let summary: String?
        let accessRole: String?
        let primary: Bool?
        let selected: Bool?
    }
    let items: [Entry]?
    let nextPageToken: String?
}

struct EventsPage: Decodable {
    let items: [Event]?
    let nextPageToken: String?
}

struct Event: Decodable {
    struct Time: Decodable { let dateTime: String?; let date: String? }
    struct Attendee: Decodable {
        let email: String?
        let responseStatus: String?
        let isSelf: Bool?
        let resource: Bool?
        enum CodingKeys: String, CodingKey { case email, responseStatus, isSelf = "self", resource }
    }
    struct Conference: Decodable {
        struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
        struct Solution: Decodable { let name: String? }
        let entryPoints: [EntryPoint]?
        let conferenceSolution: Solution?
    }
    let summary: String?
    let status: String?
    let eventType: String?
    let transparency: String?
    let start: Time?
    let attendees: [Attendee]?
    let hangoutLink: String?
    let conferenceData: Conference?
    let location: String?
    let description: String?
}

let session = URLSession(configuration: .ephemeral)

func send(_ request: URLRequest, _ what: String) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
        throw SpikeError.http(what, code, String(decoding: data.prefix(400), as: UTF8.self))
    }
    return data
}

func token(_ fields: [(String, String)], _ what: String) async throws -> TokenResponse {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncode(fields)
    return try JSONDecoder().decode(TokenResponse.self, from: try await send(request, what))
}

/// GET every page of a Calendar list endpoint (R12: a list is only complete once nextPageToken is gone).
func allPages<Page: Decodable>(_ path: String, _ query: [URLQueryItem], bearer: String,
                               next: (Page) -> String?) async throws -> [Page] {
    var pages: [Page] = []
    var pageToken: String?
    repeat {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        components.queryItems = query + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let page = try JSONDecoder().decode(Page.self, from: try await send(request, path))
        pages.append(page)
        pageToken = next(page)
    } while pageToken != nil
    return pages
}

// MARK: - The M5 filter, as the design doc states it

/// nil = keep. Otherwise the reason it would not count as a meeting. "You" is `me` (R9), not `self`.
func dropReason(_ event: Event, me: String) -> String? {
    let type = event.eventType ?? "default"
    if type != "default" && type != "fromGmail" { return "eventType \(type)" }
    if event.status == "cancelled" { return "cancelled" }
    if event.start?.date != nil { return "all-day" }
    if event.transparency == "transparent" { return "free" }
    let attendees = event.attendees ?? []
    if attendees.contains(where: { $0.email?.lowercased() == me && $0.responseStatus == "declined" }) { return "declined by you" }
    // Rooms are attendees with resource=true; they are not people.
    if !attendees.contains(where: { $0.email?.lowercased() != me && $0.resource != true }) { return "nobody but you" }
    return nil
}

func joinLink(_ event: Event) -> String? {
    if let link = event.hangoutLink { return link }
    if let uri = event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri { return uri }
    let text = [event.location, event.description].compactMap { $0 }.joined(separator: " ")
    let pattern = #"https://[^\s"<>]*(zoom\.us|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|webex\.com)[^\s"<>]*"#
    return text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
}

/// Where a missing join link might hide, without printing the meeting text itself: the
/// conference provider and entry point types, and the hosts of any URLs in location/description.
func joinHints(_ event: Event) -> String {
    var hints: [String] = []
    if let c = event.conferenceData {
        hints.append("conference \(c.conferenceSolution?.name ?? "?") entry points \((c.entryPoints ?? []).compactMap(\.entryPointType))")
    }
    for (field, text) in [("location", event.location), ("description", event.description)] {
        guard let text, !text.isEmpty else { continue }
        let hosts = text.matches(of: #/https?://([^/\s"<>]+)/#).map { String($0.1) }
        hints.append("\(field) \(text.count) chars, url hosts \(Set(hosts).sorted())")
    }
    return hints.isEmpty ? "no conferenceData, location or description" : hints.joined(separator: "; ")
}

// MARK: - Main

func main() async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0) // line by line, also when piped to a file
    let options: Options
    let client: Client
    do {
        options = try Options(Array(CommandLine.arguments.dropFirst()))
        client = try Client.load()
    } catch { print(error); return 2 }

    do {
        // 1. Loopback sign-in.
        let verifier = randomURLSafe(32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)
        let server = try LoopbackServer(expectedState: state)
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        var consent = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        consent.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ] + (options.login.map { [.init(name: "login_hint", value: $0)] } ?? [])
        print("listening on \(redirect) (5 min)")
        print("consent screen (opens in your browser unless --no-browser):\n\(consent.url!.absoluteString)\n")
        if options.openBrowser {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [consent.url!.absoluteString]
            try? open.run()
        }

        let query = try await server.waitForCallback(timeout: 300)
        print("callback ok: state matched, got a code")

        let signedIn = try await token([
            ("grant_type", "authorization_code"), ("code", query["code"]!), ("code_verifier", verifier),
            ("redirect_uri", redirect), ("client_id", client.id), ("client_secret", client.secret),
        ], "code exchange")
        print("code exchange ok: access token for \(signedIn.expires_in) s, scope \(signedIn.scope ?? "?")")
        guard let refreshToken = signedIn.refresh_token else {
            print("FAIL: no refresh_token (needs access_type=offline and prompt=consent)"); return 1
        }
        print("refresh token received")

        // 2. One refresh.
        let refreshed = try await token([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
            ("client_id", client.id), ("client_secret", client.secret),
        ], "refresh")
        print("refresh ok: new access token for \(refreshed.expires_in) s\n")
        let accessToken = refreshed.access_token

        // 3. Calendars, and who "you" are.
        let calendarPages: [CalendarListPage] = try await allPages(
            "users/me/calendarList", options.pageSize.map { [URLQueryItem(name: "maxResults", value: String($0))] } ?? [],
            bearer: accessToken, next: \.nextPageToken)
        let calendars = calendarPages.flatMap { $0.items ?? [] }
        guard let me = calendars.first(where: { $0.primary == true })?.id.lowercased() else {
            print("FAIL: no primary calendar in calendarList"); return 1
        }
        print("signed in as \(me); \(calendars.count) calendars in \(calendarPages.count) page(s):")
        for c in calendars {
            print("  \(c.primary == true ? "*" : " ") \(c.selected == true ? "[x]" : "[ ]") \(c.summary ?? "?")  (\(c.accessRole ?? "?"))  \(c.id)")
        }

        // 4. Today's events.
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        let iso = ISO8601DateFormatter()
        let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
        var kept = 0
        for calendarID in options.calendars.isEmpty ? ["primary"] : options.calendars {
            var query = [
                URLQueryItem(name: "timeMin", value: iso.string(from: startOfDay)),
                URLQueryItem(name: "timeMax", value: iso.string(from: endOfDay)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
            ]
            if let size = options.pageSize { query.append(URLQueryItem(name: "maxResults", value: String(size))) }
            let path = "calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))!)/events"
            let pages: [EventsPage] = try await allPages(path, query, bearer: accessToken, next: \.nextPageToken)
            let events = pages.flatMap { $0.items ?? [] }
            print("\ntoday on \(calendarID): \(events.count) events in \(pages.count) page(s)")
            for event in events {
                let when = event.start?.dateTime.flatMap { iso.date(from: $0) }.map { $0.formatted(timeFormat) } ?? "all day"
                let others = (event.attendees ?? []).filter { $0.email?.lowercased() != me && $0.resource != true }.count
                let verdict = dropReason(event, me: me).map { "drop: \($0)" } ?? "KEEP"
                if verdict == "KEEP" { kept += 1 }
                print("  \(when.padding(toLength: 8, withPad: " ", startingAt: 0)) \(verdict.padding(toLength: 30, withPad: " ", startingAt: 0)) \(event.summary ?? "(no title)")")
                print("           type \(event.eventType ?? "default"), status \(event.status ?? "?"), \(others) other attendee(s), join \(joinLink(event) ?? "none")")
                if joinLink(event) == nil { print("           no join link: \(joinHints(event))") }
            }
        }
        print("\n\(kept) event(s) today would show in the menu bar")

        if options.revoke {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncode([("token", refreshToken)])
            _ = try await send(request, "revoke")
            print("grant revoked")
        }
        print("PASS")
        return 0
    } catch {
        print("FAIL: \(error)")
        if "\(error)".contains("admin_policy_enforced") {
            print("The GLE Workspace admin blocks this client. Ask them to trust the client ID in Admin console → Security → API controls → App access control.")
        }
        return 1
    }
}

exit(await main())
