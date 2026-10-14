// espazio-hook — minimal Claude Code command-hook helper.
//
// Reads the hook JSON on stdin, forwards it to the running Espazio app over the local Unix
// socket, and prints the decision for PermissionRequest. It never decides by itself:
// - Espazio unreachable / error / unexpected reply → prints nothing, exits 0: Claude Code keeps
//   its normal behavior (its own permission prompt). Nothing is ever auto-approved.
// - Non-blocking events are fire-and-forget with a short timeout.

import AgentIntegrations
import EspazioBridge
import Foundation

let maxInputSize = BridgeProtocol.maxFrameSize - 64 * 1024

func readStandardInput() -> String? {
    var data = Data()
    while true {
        let chunk = FileHandle.standardInput.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        data.append(chunk)
        if data.count > maxInputSize { return nil }
    }
    return String(data: data, encoding: .utf8)
}

/// `espazio-hook codex-notify '<json>'`: Codex CLI `notify` callback (observe-only, fire-and-forget).
func runCodexNotify(_ payload: String) -> Int32 {
    guard payload.utf8.count < maxInputSize else { return 0 }
    let request = BridgeRequest(id: UUID().uuidString, kind: "codex.notify", body: payload, expectsReply: false)
    _ = try? BridgeClient.send(request, timeout: 1.5)
    return 0
}

func run() -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let arguments = CommandLine.arguments
    if arguments.count >= 3, arguments[1] == CodexNotify.argument {
        return runCodexNotify(arguments[2])
    }
    guard let input = readStandardInput(), let event = try? ClaudeHookInput.decode(input) else { return 0 }
    let environment = ProcessInfo.processInfo.environment
    var hints: [String: String] = [:]
    for key in ["TERM_PROGRAM", "__CFBundleIdentifier", "TERM_SESSION_ID", "ITERM_SESSION_ID"] {
        if let value = environment[key], !value.isEmpty { hints[key] = String(value.prefix(128)) }
    }
    #if canImport(Darwin)
    if let host = HostApplication.bundlePath(inAncestry: HostApplication.ancestorExecutablePaths()), host.utf8.count <= 1024 {
        hints[HostApplication.hintKey] = host
    }
    #endif
    let isBlocking = ClaudeHookEvent(rawValue: event.hookEventName)?.isBlocking ?? false
    let request = BridgeRequest(
        id: UUID().uuidString, kind: "claude.hook", body: input, expectsReply: isBlocking, hints: hints)
    // Stay below the hook timeout configured by the installer (600 s).
    let timeout: TimeInterval = isBlocking ? Double(ClaudeHookInstaller.permissionHookTimeout - 15) : 1.5
    guard let reply = try? BridgeClient.send(request, timeout: timeout) else { return 0 }
    if isBlocking, reply.status == .ok, let body = reply.body, !body.isEmpty {
        FileHandle.standardOutput.write(Data(body.utf8))
    }
    return 0
}

exit(run())
