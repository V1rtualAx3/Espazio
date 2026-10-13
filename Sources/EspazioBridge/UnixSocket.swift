import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong
    case system(operation: String, code: Int32)
    case timeout
    case closed
    case frameTooLarge(Int)
    case unauthorizedPeer
    case alreadyRunning

    public var description: String {
        switch self {
        case .pathTooLong: return "socket path too long"
        case let .system(operation, code): return "\(operation) failed: \(String(cString: strerror(code)))"
        case .timeout: return "timed out"
        case .closed: return "connection closed"
        case let .frameTooLarge(size): return "frame too large (\(size) bytes)"
        case .unauthorizedPeer: return "peer is not the current user"
        case .alreadyRunning: return "another instance is already listening"
        }
    }
}

/// Thin RAII wrapper over a POSIX stream socket file descriptor.
public final class UnixSocket: @unchecked Sendable {
    public let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        var on: Int32 = 1
        // Never raise SIGPIPE when the peer vanished; we get EPIPE instead.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        _ = systemClose(fd)
    }

    // MARK: - Factories

    public static func makeStream() throws -> UnixSocket {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SocketError.system(operation: "socket", code: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return UnixSocket(fd: fd)
    }

    static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    public static func connect(path: String) throws -> UnixSocket {
        let socket = try makeStream()
        let result = try withAddress(path: path) { address, length in
            systemConnect(socket.fd, address, length)
        }
        guard result == 0 else { throw SocketError.system(operation: "connect", code: errno) }
        return socket
    }

    // MARK: - IO

    /// Waits until the socket is readable. Returns false on timeout.
    public func waitReadable(timeout: TimeInterval) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = timeout.isInfinite ? -1 : Int32(max(0, min(timeout * 1000, Double(Int32.max))))
        while true {
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw SocketError.system(operation: "poll", code: errno)
        }
    }

    public func readExactly(_ count: Int, deadline: Date) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, try waitReadable(timeout: remaining) else { throw SocketError.timeout }
            let received = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + offset, count - offset, 0)
            }
            if received == 0 { throw SocketError.closed }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SocketError.system(operation: "recv", code: errno)
            }
            offset += received
        }
        return Data(buffer)
    }

    public func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let sent = send(fd, base + offset, raw.count - offset, 0)
                #else
                let sent = send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system(operation: "send", code: errno)
                }
                offset += sent
            }
        }
    }

    /// True when the peer has closed the connection (EOF pending) or the socket errored.
    public func peerHasClosed() -> Bool {
        var byte: UInt8 = 0
        #if canImport(Darwin)
        let flags = MSG_PEEK | MSG_DONTWAIT
        #else
        let flags = Int32(MSG_PEEK) | Int32(MSG_DONTWAIT)
        #endif
        let result = recv(fd, &byte, 1, flags)
        if result == 0 { return true }
        if result < 0 { return !(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) }
        return false
    }

    /// User id of the connected peer (macOS: `getpeereid`, Linux: `SO_PEERCRED`).
    public func peerUserID() -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        var credentials = LinuxPeerCredentials()
        var length = socklen_t(MemoryLayout<LinuxPeerCredentials>.size)
        return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 ? credentials.uid : nil
        #endif
    }

    /// Process id of the connected peer, when the platform exposes it.
    public func peerProcessID() -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
        #else
        var credentials = LinuxPeerCredentials()
        var length = socklen_t(MemoryLayout<LinuxPeerCredentials>.size)
        return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 ? credentials.pid : nil
        #endif
    }
}

#if !canImport(Darwin)
/// Layout of Linux `struct ucred` (not exported to Swift without `_GNU_SOURCE`).
struct LinuxPeerCredentials {
    var pid: pid_t = 0
    var uid: uid_t = 0
    var gid: gid_t = 0
}
#endif

// Disambiguate POSIX functions from methods with the same names.
@inline(__always) func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #elseif canImport(Glibc)
    return Glibc.close(fd)
    #else
    return Musl.close(fd)
    #endif
}

@inline(__always) func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #elseif canImport(Glibc)
    return Glibc.connect(fd, address, length)
    #else
    return Musl.connect(fd, address, length)
    #endif
}

@inline(__always) func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, address, length)
    #elseif canImport(Glibc)
    return Glibc.bind(fd, address, length)
    #else
    return Musl.bind(fd, address, length)
    #endif
}

@inline(__always) func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.listen(fd, backlog)
    #elseif canImport(Glibc)
    return Glibc.listen(fd, backlog)
    #else
    return Musl.listen(fd, backlog)
    #endif
}

@inline(__always) func systemAccept(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.accept(fd, nil, nil)
    #elseif canImport(Glibc)
    return Glibc.accept(fd, nil, nil)
    #else
    return Musl.accept(fd, nil, nil)
    #endif
}
