import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One-shot HTTP listener on 127.0.0.1 for the OAuth loopback redirect.
///
/// Opened only for the duration of a sign-in, bound to the loopback interface on an ephemeral
/// port, closed after the first OAuth callback or after the timeout. No other port is ever opened.
public final class LoopbackReceiver: @unchecked Sendable {
    public let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init() throws {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw OAuthError.invalidResponse }
        fd = descriptor
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            _ = close(descriptor)
            throw OAuthError.invalidResponse
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { shutdown() }

    public var redirectURI: String { "http://127.0.0.1:\(port)" }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = close(fd)
    }

    /// Waits for the OAuth redirect and returns its query parameters.
    /// Requests whose `state` differs from `expectedState` (forged or stale) are ignored.
    public func waitForCallback(timeout: TimeInterval, expectedState: String? = nil) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(with: Result { try self.acceptCallback(deadline: Date().addingTimeInterval(timeout), expectedState: expectedState) })
            }
        }
    }

    private func acceptCallback(deadline: Date, expectedState: String?) throws -> [String: String] {
        defer { shutdown() }
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw OAuthError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 3600) * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw OAuthError.timeout }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            defer { _ = close(client) }
            guard let query = Self.readRequestQuery(client) else {
                Self.respond(client, status: "404 Not Found", body: "")
                continue
            }
            // Ignore unrelated requests (favicon…) and keep waiting for the real callback.
            guard query["code"] != nil || query["error"] != nil, expectedState == nil || query["state"] == expectedState else {
                Self.respond(client, status: "404 Not Found", body: "")
                continue
            }
            let success = query["code"] != nil
            Self.respond(client, status: "200 OK", body: Self.page(success: success))
            return query
        }
    }

    static func readRequestQuery(_ client: Int32) -> [String: String]? {
        let capacity = 8192
        var buffer = [UInt8](repeating: 0, count: capacity)
        var total = 0
        // Overall per-connection deadline: a slow client cannot stall the listener.
        let deadline = Date().addingTimeInterval(3)
        while total < capacity {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { break }
            let received = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress! + total, capacity - total, 0) }
            if received <= 0 { break }
            total += received
            if buffer[0..<total].contains(0x0A) { break }
        }
        guard let text = String(bytes: buffer[0..<total], encoding: .utf8),
            let line = text.split(separator: "\r\n", maxSplits: 1).first ?? text.split(separator: "\n").first
        else { return nil }
        return parseRequestLine(String(line))
    }

    /// `GET /?code=x&state=y HTTP/1.1` → query dictionary.
    static func parseRequestLine(_ line: String) -> [String: String]? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/" || components.path.isEmpty else {
            return nil
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        _ = response.withCString { send(client, $0, strlen($0), flags) }
    }

    private static func page(success: Bool) -> String {
        let message = success ? "Connexion réussie. Vous pouvez fermer cet onglet et revenir à Espazio." : "Connexion annulée. Vous pouvez fermer cet onglet."
        return "<!doctype html><html lang=\"fr\"><meta charset=\"utf-8\"><title>Espazio</title><body style=\"font:15px -apple-system,sans-serif;margin:4em;color:#111\"><p>\(message)</p></body></html>"
    }
}
