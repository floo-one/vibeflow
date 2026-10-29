import AppKit
import Foundation
import Network
import os
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "meetings")

/// Why a Google sign-in did not finish, in the words the Meetings tab shows.
enum GoogleSignInError: Error, Equatable {
    case cancelled
    case timedOut
    case callback(GoogleOAuth.CallbackError)
    case exchange(GoogleCalendarError)
    case listener(String)

    var message: String {
        switch self {
        case .cancelled: "Sign-in cancelled"
        case .timedOut: "Sign-in timed out. Try again."
        case .callback(.accessDenied): "Sign-in cancelled in the browser"
        case .callback(.adminPolicyEnforced): "Blocked by your Google Workspace admin"
        case .callback(.stateMismatch): "Sign-in failed: the browser answer did not match. Try again."
        case .callback(.missingCode), .callback(.other): "Sign-in failed. Try again."
        case .exchange(.adminPolicyEnforced): "Blocked by your Google Workspace admin"
        case .exchange(.calendarAccessNotGranted): "Allow calendar access to use Meetings. Sign in again and keep \"See your calendars\" ticked."
        case .exchange(.offline): "Sign-in failed: offline"
        case .exchange: "Sign-in failed at Google. Try again."
        case .listener(let reason): "Sign-in could not start (\(reason))"
        }
    }
}

/// Desktop OAuth with a loopback redirect (R3): PKCE S256 and a random state, a listener on
/// 127.0.0.1 with an ephemeral port that takes one callback and closes, a 5 minute timeout,
/// and a new sign-in cancels the one still waiting.
@MainActor
final class GoogleSignIn {
    private var listener: LoopbackListener?

    /// Opens the consent screen in the default browser and returns the tokens.
    func signIn(config: GoogleOAuthConfig, client: GoogleCalendarClient) async throws(GoogleSignInError) -> GoogleTokens {
        cancel()
        let pkce = GoogleOAuth.PKCE.generate()
        let state = GoogleOAuth.randomToken(bytes: 16)
        let listener: LoopbackListener
        let port: UInt16
        do {
            listener = try LoopbackListener(expectedState: state, timeout: GoogleOAuth.signInTimeout)
            port = try await listener.start()
        } catch {
            throw .listener(error.localizedDescription)
        }
        self.listener = listener
        defer { if self.listener === listener { self.listener = nil } }

        let redirectURI = "http://127.0.0.1:\(port)"
        NSWorkspace.shared.open(GoogleOAuth.authorizationURL(config: config, redirectURI: redirectURI, pkce: pkce, state: state))
        log.notice("Google sign-in waiting on port \(port, privacy: .public)")

        let code = try await listener.waitForCode()
        do {
            return try await client.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        } catch let error as GoogleCalendarError {
            throw .exchange(error)
        } catch {
            throw .cancelled
        }
    }

    /// Stops a sign-in that is still waiting for the browser.
    func cancel() {
        listener?.cancel()
        listener = nil
    }
}

/// One-shot HTTP listener for the OAuth redirect. Everything runs on `queue`.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "one.floo.vibeflow.google-sign-in")
    private let expectedState: String
    private let timeout: Duration
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var outcome: Result<String, GoogleSignInError>?

    init(expectedState: String, timeout: Duration) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.expectedState = expectedState
        self.timeout = timeout
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        ready?.resume(returning: listener.port?.rawValue ?? 0)
                        ready = nil
                        queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) { [self] in
                            finish(.failure(.timedOut))
                        }
                    case .failed(let error):
                        ready?.resume(throwing: error)
                        ready = nil
                        finish(.failure(.listener(error.localizedDescription)))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [self] connection in
                    connection.start(queue: queue)
                    read(connection, buffer: Data())
                }
                listener.start(queue: queue)
            }
        }
    }

    func waitForCode() async throws(GoogleSignInError) -> String {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let outcome {
                        continuation.resume(with: outcome.mapError { $0 as Error })
                    } else {
                        waiter = continuation
                    }
                }
            }
        } catch let error as GoogleSignInError {
            throw error
        } catch {
            throw .cancelled
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(.cancelled)) }
    }

    private func finish(_ result: Result<String, GoogleSignInError>) {
        guard outcome == nil else { return }
        outcome = result
        listener.cancel()
        waiter?.resume(with: result.mapError { $0 as Error })
        waiter = nil
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
        let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
        guard outcome == nil, parts.count >= 2, parts[0] == "GET",
              let callback = GoogleOAuth.parseCallback(requestTarget: String(parts[1]), expectedState: expectedState)
        else {
            respond(connection, status: "404 Not Found", page: "Not found")
            return
        }
        switch callback {
        case .failure(.stateMismatch):
            // Not our browser's answer (another tab, another program): ignore it and keep
            // waiting, so a stray request cannot end the sign-in.
            respond(connection, status: "400 Bad Request", page: "This request does not belong to the VibeFlow sign-in.")
        case .success(let code):
            respond(connection, status: "200 OK", page: "VibeFlow is signed in to Google Calendar. You can close this tab.")
            finish(.success(code))
        case .failure(let error):
            let page = switch error {
            case .adminPolicyEnforced: "Your Google Workspace admin blocks VibeFlow. Ask them to trust the VibeFlow client ID, then try again."
            case .accessDenied: "Sign-in cancelled. You can close this tab."
            default: "VibeFlow sign-in failed. Close this tab and try again from VibeFlow's Settings."
            }
            respond(connection, status: "200 OK", page: page)
            finish(.failure(.callback(error)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, page: String) {
        let escaped = page
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
