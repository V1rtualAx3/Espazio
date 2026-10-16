import Foundation

/// Minimal local audit journal for agent decisions (spec §3.6). One JSON object per line,
/// size-bounded with a single rotation. Contains identifiers and outcomes only — never
/// commands, answers, tokens or message content.
public final class AuditLog: @unchecked Sendable {
    public let fileURL: URL
    public let maxBytes: Int
    private let queue = DispatchQueue(label: "app.espazio.audit", qos: .utility)
    private let encoder: JSONEncoder

    public init(fileURL: URL, maxBytes: Int = 512 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    private struct Line: Encodable {
        let date: Date
        let action: String
        let requestID: String
        let sessionID: String
        let provider: String
        let tool: String
        let outcome: String?
    }

    public func record(_ event: ApprovalAuditEvent) {
        let line = Line(
            date: event.date, action: event.action.rawValue, requestID: Redactor.redact(event.requestID),
            sessionID: Redactor.redact(event.sessionID), provider: event.provider.rawValue,
            tool: Redactor.truncate(Redactor.redact(event.toolName), limit: 64), outcome: event.outcome)
        guard var encoded = try? encoder.encode(line) else { return }
        encoded.append(0x0A)
        let data = encoded
        queue.async { [fileURL, maxBytes] in
            Self.append(data, to: fileURL, maxBytes: maxBytes)
        }
    }

    /// Blocks until pending writes are flushed (tests, shutdown).
    public func flush() {
        queue.sync {}
    }

    private static func append(_ data: Data, to url: URL, maxBytes: Int) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int, size + data.count > maxBytes
        {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
