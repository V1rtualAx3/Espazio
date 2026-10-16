import EspazioCore
import Foundation

/// Launches `codex app-server` and exposes its stdio as a line transport.
public final class ProcessLineTransport: LineTransport, @unchecked Sendable {
    public static let maxLineLength = 8 * 1024 * 1024

    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var discarding = false

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) throws {
        (incoming, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let continuation = self.continuation
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            self?.consume(chunk)
        }
        // The stream ends on pipe EOF. Termination alone can race ahead of the last buffered
        // output, so it only finishes the stream after a grace period (covers a grandchild that
        // would keep the pipe open).
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.finish() }
        }
        try process.run()
        // Close the parent's copies of the child's pipe ends, otherwise EOF never arrives.
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    public var isRunning: Bool { process.isRunning }

    public func send(_ line: Data) throws {
        guard process.isRunning else { throw CodexClientError.notRunning }
        var data = line
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if discarding {
                discarding = false
                continue
            }
            if !line.isEmpty { continuation.yield(Data(line)) }
        }
        if buffer.count > Self.maxLineLength {
            // Drop an oversized line instead of growing without bound.
            buffer.removeAll(keepingCapacity: false)
            discarding = true
        }
    }
}

/// Finds the `codex` executable. GUI apps inherit a minimal PATH, so common install locations
/// are searched too, and the same directories are added to the child's PATH (the npm
/// distribution needs `node`).
public enum CodexLocator {
    public static func searchDirectories(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "\(home)/.bun/bin", "\(home)/.cargo/bin", "/usr/bin",
        ]
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    public static func locate(override: String? = nil, home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        if let override, !override.isEmpty, manager.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        for directory in searchDirectories(home: home, environment: environment) {
            let candidate = directory + "/codex"
            if manager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    public static func childEnvironment(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        result["PATH"] = searchDirectories(home: home, environment: environment).joined(separator: ":")
        return result
    }
}

/// `notify` integration for independent Codex CLI sessions (observe-only): Codex runs the
/// configured program with a JSON payload when a turn completes.
public enum CodexNotify {
    public static let argument = "codex-notify"

    public enum InstallResult: Equatable {
        case installed(String)
        case alreadyInstalled
        /// A different `notify` program is configured; Espazio does not override it.
        case conflict
    }

    public static func defaultConfigURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".codex/config.toml")
    }

    /// Adds `notify = [helper, "codex-notify"]` as a top-level key (before any table).
    public static func installing(into text: String, helperPath: String) -> InstallResult {
        let lines = text.components(separatedBy: "\n")
        var inTable = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inTable = true }
            if !inTable, trimmed.hasPrefix("notify"), trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                return line.contains("espazio-hook") ? .alreadyInstalled : .conflict
            }
        }
        let escaped = helperPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let entry = "notify = [\"\(escaped)\", \"\(argument)\"]  # Espazio: suivi des sessions Codex CLI"
        return .installed(entry + "\n" + text)
    }

    /// Maps a notify payload (`agent-turn-complete`) to an observe-only event.
    public static func events(fromPayload text: String) -> [AgentEvent] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            json["type"]?.stringValue == "agent-turn-complete",
            let threadID = json["thread-id"]?.stringValue ?? json["thread_id"]?.stringValue
        else { return [] }
        let message = json["last-assistant-message"]?.stringValue.map { Redactor.truncate(Redactor.redact($0), limit: 200) }
        return [
            .sessionStarted(sessionID: threadID, provider: .codex, projectPath: json["cwd"]?.stringValue, control: .observeOnly, clientHint: nil),
            .turnCompleted(sessionID: threadID, provider: .codex, message: message),
        ]
    }
}
