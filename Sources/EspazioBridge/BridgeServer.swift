import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Information about a connected local client.
public struct BridgePeer: Sendable, Equatable {
    public let processID: Int32?
}

/// Local-only IPC server over a Unix domain socket.
///
/// Security model:
/// - socket in a 0700 directory, socket file 0600, no network port;
/// - every peer must run as the same user (`getpeereid` / `SO_PEERCRED`), others are dropped;
/// - bounded frame size, bounded number of concurrent connections, read deadline;
/// - if the peer disconnects while its request is pending, the handler task is cancelled so the
///   pending decision is withdrawn (never approved).
///
/// Event-driven: no polling, no thread parked while idle (dispatch sources only).
public final class BridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BridgeRequest, BridgePeer) async -> BridgeReply

    public let path: String
    private let handler: Handler
    private let maxConnections: Int
    private let readTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.espazio.bridge", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: UnixSocket?
    private var acceptSource: DispatchSourceRead?
    private var activeConnections = 0

    public init(path: String = BridgePaths.defaultSocketPath(), maxConnections: Int = 32, readTimeout: TimeInterval = 5, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.maxConnections = maxConnections
        self.readTimeout = readTimeout
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }

        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory, 0o700)

        // Refuse to steal the socket from a running instance; remove only stale files.
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? UnixSocket.connect(path: path) {
                probe.close()
                throw SocketError.alreadyRunning
            }
            _ = unlink(path)
        }

        let socket = try UnixSocket.makeStream()
        let previousMask = umask(0o177)
        let bound = try UnixSocket.withAddress(path: path) { address, length in
            systemBind(socket.fd, address, length)
        }
        umask(previousMask)
        guard bound == 0 else { throw SocketError.system(operation: "bind", code: errno) }
        _ = chmod(path, 0o600)
        guard systemListen(socket.fd, 16) == 0 else { throw SocketError.system(operation: "listen", code: errno) }

        let source = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        listener = socket
        acceptSource = source
    }

    public func stop() {
        lock.lock()
        let source = acceptSource
        let socket = listener
        acceptSource = nil
        listener = nil
        lock.unlock()
        source?.cancel()
        socket?.close()
        if socket != nil { _ = unlink(path) }
    }

    // MARK: - Private

    private func acceptPending() {
        guard let listenerFD = currentListenerFD() else { return }
        let fd = systemAccept(listenerFD)
        guard fd >= 0 else { return }
        let connection = UnixSocket(fd: fd)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        guard connection.peerUserID() == geteuid() else {
            connection.close()
            return
        }
        guard reserveSlot() else {
            connection.close()
            return
        }
        let peer = BridgePeer(processID: connection.peerProcessID())
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serve(connection, peer: peer)
        }
    }

    private func serve(_ connection: UnixSocket, peer: BridgePeer) {
        let request: BridgeRequest
        do {
            request = try BridgeProtocol.readFrame(BridgeRequest.self, from: connection, deadline: Date().addingTimeInterval(readTimeout))
        } catch {
            connection.close()
            releaseSlot()
            return
        }
        guard request.v == BridgeProtocol.version else {
            if let frame = try? BridgeProtocol.encodeFrame(BridgeReply(id: request.id, status: .error, body: "unsupported version")) {
                try? connection.writeAll(frame)
            }
            connection.close()
            releaseSlot()
            return
        }

        let handler = self.handler
        let task = Task {
            let reply = await handler(request, peer)
            if !Task.isCancelled, let frame = try? BridgeProtocol.encodeFrame(reply) {
                try? connection.writeAll(frame)
            }
        }

        // Watch for the peer going away while the handler runs. After the request, the client
        // sends nothing; any readability is EOF or a protocol violation: both cancel the task.
        let watcher = DispatchSource.makeReadSource(fileDescriptor: connection.fd, queue: queue)
        watcher.setEventHandler {
            task.cancel()
            watcher.cancel()
        }
        // The descriptor is closed only once the source is fully cancelled (no fd reuse race).
        watcher.setCancelHandler { [self] in
            connection.close()
            releaseSlot()
        }
        watcher.resume()

        Task {
            _ = await task.value
            watcher.cancel()
        }
    }

    private func currentListenerFD() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return listener?.fd
    }

    private func reserveSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < maxConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseSlot() {
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }
}

/// Synchronous client used by the short-lived hook helper.
public enum BridgeClient {
    public static func send(_ request: BridgeRequest, path: String = BridgePaths.defaultSocketPath(), timeout: TimeInterval) throws -> BridgeReply {
        let socket = try UnixSocket.connect(path: path)
        defer { socket.close() }
        try socket.writeAll(BridgeProtocol.encodeFrame(request))
        let reply = try BridgeProtocol.readFrame(BridgeReply.self, from: socket, deadline: Date().addingTimeInterval(timeout))
        guard reply.id == request.id else { throw SocketError.closed }
        return reply
    }
}
