import Foundation

/// Versioned messages exchanged between `espazio-hook` (or any local client) and the app.
///
/// Frame = 4-byte big-endian length + UTF-8 JSON. Frames above `maxFrameSize` are rejected
/// before allocation.
public enum BridgeProtocol {
    public static let version = 1
    public static let maxFrameSize = 2 * 1024 * 1024

    public static func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maxFrameSize else { throw SocketError.frameTooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    public static func readFrame<T: Decodable>(_ type: T.Type, from socket: UnixSocket, deadline: Date) throws -> T {
        let header = try socket.readExactly(4, deadline: deadline)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= maxFrameSize else { throw SocketError.frameTooLarge(length) }
        let body = try socket.readExactly(length, deadline: deadline)
        return try JSONDecoder().decode(T.self, from: body)
    }
}

/// Request from a local client.
public struct BridgeRequest: Codable, Sendable, Equatable {
    /// Protocol version of the sender.
    public var v: Int
    /// Unique id of this message (used for idempotency and correlation).
    public var id: String
    /// Message kind, e.g. `claude.hook`.
    public var kind: String
    /// Raw JSON body (the hook input), kept as text so the bridge stays provider-agnostic.
    public var body: String
    /// Whether the client waits for a decision.
    public var expectsReply: Bool
    /// Free-form client environment hints (terminal program…). Never secrets.
    public var hints: [String: String]

    public init(id: String, kind: String, body: String, expectsReply: Bool, hints: [String: String] = [:]) {
        self.v = BridgeProtocol.version
        self.id = id
        self.kind = kind
        self.body = body
        self.expectsReply = expectsReply
        self.hints = hints
    }
}

public struct BridgeReply: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// `body` holds the answer.
        case ok
        /// Received, nothing to answer (fire-and-forget events).
        case accepted
        /// The app declines to handle it; the client must fall back to its default behavior.
        case passThrough
        case error
    }

    public var v: Int
    public var id: String
    public var status: Status
    public var body: String?

    public init(id: String, status: Status, body: String? = nil) {
        self.v = BridgeProtocol.version
        self.id = id
        self.status = status
        self.body = body
    }
}

public enum BridgePaths {
    /// `~/Library/Application Support/Espazio/run/bridge.sock` on macOS,
    /// `$XDG_RUNTIME_DIR/espazio/bridge.sock` (or `~/.espazio/run`) elsewhere.
    /// `ESPAZIO_BRIDGE_SOCKET` overrides it (tests, development).
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["ESPAZIO_BRIDGE_SOCKET"], !override.isEmpty { return override }
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
        return home + "/Library/Application Support/Espazio/run/bridge.sock"
        #else
        if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty { return runtime + "/espazio/bridge.sock" }
        return home + "/.espazio/run/bridge.sock"
        #endif
    }
}
