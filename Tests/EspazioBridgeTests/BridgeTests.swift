import EspazioBridge
import Foundation
import XCTest

final class BridgeTests: XCTestCase {
    var directory: URL!
    var socketPath: String { directory.appendingPathComponent("b.sock").path }

    override func setUp() {
        // Keep the path short: sun_path is limited to 104 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ez-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let server = BridgeServer(path: socketPath) { request, peer in
            BridgeReply(id: request.id, status: .ok, body: "echo:\(request.body):\(peer.processID != nil)")
        }
        try server.start()
        defer { server.stop() }
        let reply = try BridgeClient.send(
            BridgeRequest(id: "1", kind: "test", body: "hello", expectsReply: true), path: socketPath, timeout: 5)
        XCTAssertEqual(reply.status, .ok)
        XCTAssertEqual(reply.body, "echo:hello:true")
    }

    func testSocketAndDirectoryPermissions() throws {
        let server = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .accepted) }
        try server.start()
        defer { server.stop() }
        let socketAttributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((socketAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSecondInstanceRefused() throws {
        let first = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .accepted) }
        try first.start()
        defer { first.stop() }
        let second = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .accepted) }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? SocketError, .alreadyRunning)
        }
    }

    func testStaleSocketFileIsReplaced() throws {
        let first = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .accepted) }
        try first.start()
        // Simulate a crash: the listener disappears but the file remains.
        let stale = socketPath
        first.stop()
        _ = FileManager.default.createFile(atPath: stale, contents: Data())
        let second = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .ok, body: "new") }
        try second.start()
        defer { second.stop() }
        let reply = try BridgeClient.send(BridgeRequest(id: "x", kind: "t", body: "", expectsReply: true), path: socketPath, timeout: 5)
        XCTAssertEqual(reply.body, "new")
    }

    func testClientDisconnectCancelsHandler() throws {
        let cancelled = expectation(description: "handler cancelled")
        let server = BridgeServer(path: socketPath) { request, _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            } onCancel: {
                cancelled.fulfill()
            }
            return BridgeReply(id: request.id, status: .ok, body: "late")
        }
        try server.start()
        defer { server.stop() }
        let socket = try UnixSocket.connect(path: socketPath)
        try socket.writeAll(BridgeProtocol.encodeFrame(BridgeRequest(id: "1", kind: "t", body: "", expectsReply: true)))
        Thread.sleep(forTimeInterval: 0.2)
        socket.close()
        wait(for: [cancelled], timeout: 5)
    }

    func testOversizedFrameIsRejectedBeforeAllocation() throws {
        let handled = expectation(description: "handler must not run")
        handled.isInverted = true
        let server = BridgeServer(path: socketPath) { request, _ in
            handled.fulfill()
            return BridgeReply(id: request.id, status: .ok)
        }
        try server.start()
        defer { server.stop() }
        let socket = try UnixSocket.connect(path: socketPath)
        var length = UInt32(BridgeProtocol.maxFrameSize + 1).bigEndian
        try socket.writeAll(Data(bytes: &length, count: 4))
        XCTAssertThrowsError(try socket.readExactly(1, deadline: Date().addingTimeInterval(2)))
        wait(for: [handled], timeout: 0.5)
    }

    func testWrongVersionGetsErrorReply() throws {
        let server = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .ok) }
        try server.start()
        defer { server.stop() }
        var request = BridgeRequest(id: "v", kind: "t", body: "", expectsReply: true)
        request.v = 99
        let reply = try BridgeClient.send(request, path: socketPath, timeout: 5)
        XCTAssertEqual(reply.status, .error)
    }

    func testGarbageIsDropped() throws {
        let server = BridgeServer(path: socketPath) { request, _ in BridgeReply(id: request.id, status: .ok) }
        try server.start()
        defer { server.stop() }
        let socket = try UnixSocket.connect(path: socketPath)
        var length = UInt32(5).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(Data("nope!".utf8))
        try socket.writeAll(frame)
        XCTAssertThrowsError(try socket.readExactly(1, deadline: Date().addingTimeInterval(2)))
    }

    func testUnreachableServerThrows() {
        XCTAssertThrowsError(try BridgeClient.send(
            BridgeRequest(id: "1", kind: "t", body: "", expectsReply: true), path: socketPath, timeout: 1))
    }

    func testDefaultPathOverride() {
        XCTAssertEqual(BridgePaths.defaultSocketPath(environment: ["ESPAZIO_BRIDGE_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertTrue(BridgePaths.defaultSocketPath(environment: ["HOME": "/home/u"]).hasSuffix("bridge.sock"))
    }
}
