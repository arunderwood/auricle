import Foundation
import Network

/// A one-shot HTTP listener bound to `127.0.0.1` on an ephemeral port that
/// catches the browser's OAuth redirect. It answers the browser with a short
/// "you can close this tab" page and hands the redirect's query items to
/// whoever is awaiting `nextRedirect()`.
///
/// Only the first request that carries an OAuth response (`code` or `error`)
/// is accepted; anything else (a favicon fetch, a stray probe) gets a 404 and
/// leaves the flow waiting.
///
/// `@unchecked Sendable`: `accepted` is touched only on `queue`, the serial
/// queue every Network callback runs on; everything else is immutable.
final class LoopbackRedirectListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.auricle.app.google-oauth-loopback")
    private let readiness: AsyncThrowingStream<UInt16, any Error>
    private let readinessContinuation: AsyncThrowingStream<UInt16, any Error>.Continuation
    private let redirects: AsyncStream<[URLQueryItem]>
    private let redirectContinuation: AsyncStream<[URLQueryItem]>.Continuation
    private var accepted = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        (readiness, readinessContinuation) = AsyncThrowingStream.makeStream(of: UInt16.self)
        (redirects, redirectContinuation) = AsyncStream.makeStream(of: [URLQueryItem].self)
    }

    /// Starts listening and returns the port the system assigned.
    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)

        for try await port in readiness {
            return port
        }
        throw CancellationError()
    }

    /// Suspends until a redirect has been accepted and answered. The redirect
    /// is buffered, so one that lands before this is called is not lost.
    func nextRedirect() async throws -> [URLQueryItem] {
        for await items in redirects {
            return items
        }
        try Task.checkCancellation()
        throw GoogleCalendarFailure.authorizationFailed(reason: "the local redirect listener closed before a response arrived")
    }

    func cancel() {
        listener.cancel()
    }

    // MARK: - Listener

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                readinessContinuation.yield(port)
                readinessContinuation.finish()
            } else {
                readinessContinuation.finish(throwing: GoogleCalendarFailure.authorizationFailed(reason: "the local redirect listener has no port"))
            }
        case let .failed(error):
            readinessContinuation.finish(throwing: error)
            redirectContinuation.finish()
        case .cancelled:
            readinessContinuation.finish()
            redirectContinuation.finish()
        default:
            break
        }
    }

    // MARK: - Connections

    private static let maximumRequestLineBytes = 8192

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestLine(on: connection, buffered: Data())
    }

    private func receiveRequestLine(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffered
            if let data {
                buffer.append(data)
            }

            if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
                respond(to: connection, requestLine: String(bytes: buffer[..<lineEnd.lowerBound], encoding: .utf8) ?? "")
            } else if error != nil || isComplete || buffer.count >= Self.maximumRequestLineBytes {
                connection.cancel()
            } else {
                receiveRequestLine(on: connection, buffered: buffer)
            }
        }
    }

    private func respond(to connection: NWConnection, requestLine: String) {
        guard !accepted, let items = Self.oauthQueryItems(fromRequestLine: requestLine) else {
            send(Self.response(status: "404 Not Found", body: "Not found."), on: connection, then: nil)
            return
        }
        accepted = true

        // Neutral on purpose: the response has not been validated yet, so the
        // page must not claim success or failure.
        send(Self.response(status: "200 OK", body: "You can close this tab and return to auricle."), on: connection) { [weak self] in
            self?.redirectContinuation.yield(items)
            self?.redirectContinuation.finish()
        }
    }

    /// Delivering after the reply has been flushed keeps the caller from
    /// cancelling the listener while the browser is still being answered.
    private func send(_ data: Data, on connection: NWConnection, then completion: (@Sendable () -> Void)?) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    /// The query items of a `GET` request line that carries an OAuth response,
    /// or `nil` for any other request.
    static func oauthQueryItems(fromRequestLine line: String) -> [URLQueryItem]? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        guard let items = URLComponents(string: String(parts[1]))?.queryItems else { return nil }
        guard items.contains(where: { $0.name == "code" || $0.name == "error" }) else { return nil }
        return items
    }

    private static func response(status: String, body: String) -> Data {
        let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>auricle</title></head><body><p>\(body)</p></body></html>"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + page).utf8)
    }
}
