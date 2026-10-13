import EspazioCore
import Foundation

/// Input JSON received by a Claude Code command hook on stdin
/// (https://code.claude.com/docs/en/hooks). Unknown fields are ignored.
public struct ClaudeHookInput: Decodable, Sendable, Equatable {
    public var sessionID: String
    public var transcriptPath: String?
    public var cwd: String?
    public var hookEventName: String
    public var permissionMode: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolUseID: String?
    public var notificationType: String?
    public var message: String?
    public var source: String?
    public var reason: String?
    public var lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case source
        case reason
        case lastAssistantMessage = "last_assistant_message"
    }

    public static func decode(_ text: String) throws -> ClaudeHookInput {
        try JSONDecoder().decode(ClaudeHookInput.self, from: Data(text.utf8))
    }
}

/// Hook events Espazio registers. `PermissionRequest` is the only blocking one.
public enum ClaudeHookEvent: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case notification = "Notification"
    case stop = "Stop"
    case permissionRequest = "PermissionRequest"

    public var isBlocking: Bool { self == .permissionRequest }
}

/// Maps Claude hook inputs to Espazio's normalized model.
public enum ClaudeHookMapper {
    /// Tools that need real user interaction in Claude's own UI; Espazio never answers them.
    public static let passThroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Upper bound of the text kept for display (the full command is displayed up to this size;
    /// longer inputs are flagged as truncated and the user is pointed to the terminal).
    public static let maxSummaryLength = 16 * 1024

    public static func agentEvent(for input: ClaudeHookInput, clientHint: String?) -> AgentEvent? {
        let id = input.sessionID
        switch ClaudeHookEvent(rawValue: input.hookEventName) {
        case .sessionStart:
            return .sessionStarted(sessionID: id, provider: .claudeCode, projectPath: input.cwd, control: .approvals, clientHint: clientHint)
        case .sessionEnd:
            return .sessionEnded(sessionID: id, provider: .claudeCode)
        case .userPromptSubmit:
            return .activity(sessionID: id, provider: .claudeCode, message: nil)
        case .notification:
            let message = input.message.map { Redactor.truncate(Redactor.redact($0), limit: 200) }
            switch input.notificationType {
            case "permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input":
                return .waiting(sessionID: id, provider: .claudeCode, message: message)
            default:
                return .activity(sessionID: id, provider: .claudeCode, message: message)
            }
        case .stop:
            let message = input.lastAssistantMessage.map { Redactor.truncate(Redactor.redact($0), limit: 200) }
            return .turnCompleted(sessionID: id, provider: .claudeCode, message: message)
        case .permissionRequest:
            return .waiting(sessionID: id, provider: .claudeCode, message: input.toolName)
        case nil:
            return .activity(sessionID: id, provider: .claudeCode, message: nil)
        }
    }

    /// Builds the decision request shown in the notch, or `nil` when Espazio must not answer.
    public static func approvalRequest(for input: ClaudeHookInput, fallbackID: String, now: Date, timeout: TimeInterval) -> AgentRequest? {
        guard input.hookEventName == ClaudeHookEvent.permissionRequest.rawValue,
            let tool = input.toolName, !passThroughTools.contains(tool),
            !input.sessionID.isEmpty
        else { return nil }

        let kind: AgentRequestKind
        switch tool {
        case "Bash": kind = .command
        case "Edit", "Write", "MultiEdit", "NotebookEdit": kind = .fileChange
        default: kind = .tool
        }
        let toolInput = input.toolInput
        var summary: String
        var detail: String?
        switch tool {
        case "Bash":
            summary = toolInput?["command"]?.stringValue ?? toolInput?.compactString() ?? tool
            detail = toolInput?["description"]?.stringValue
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            summary = toolInput?["file_path"]?.stringValue ?? toolInput?["notebook_path"]?.stringValue ?? tool
            detail = describeFileChange(tool: tool, input: toolInput)
        case "WebFetch":
            summary = toolInput?["url"]?.stringValue ?? tool
            detail = toolInput?["prompt"]?.stringValue
        default:
            summary = toolInput?.compactString() ?? tool
        }
        if summary.count > maxSummaryLength {
            summary = String(summary.prefix(maxSummaryLength)) + "\n… [tronqué — voir le terminal]"
        }
        let requestID = "claude:\(input.sessionID):\(input.toolUseID ?? fallbackID)"
        return AgentRequest(
            id: requestID, sessionID: input.sessionID, provider: .claudeCode, kind: kind, toolName: tool,
            summary: summary, workingDirectory: input.cwd, detail: detail.map { Redactor.truncate($0, limit: 2000) },
            createdAt: now, deadline: now.addingTimeInterval(timeout))
    }

    private static func describeFileChange(tool: String, input: JSONValue?) -> String? {
        guard let input else { return nil }
        switch tool {
        case "Write":
            let length = input["content"]?.stringValue?.count ?? 0
            return "Écriture complète du fichier (\(length) caractères)"
        case "Edit":
            let old = input["old_string"]?.stringValue ?? ""
            let new = input["new_string"]?.stringValue ?? ""
            return "− \(Redactor.truncate(old, limit: 600))\n+ \(Redactor.truncate(new, limit: 600))"
        case "MultiEdit":
            let count = input["edits"]?.arrayValue?.count ?? 0
            return "\(count) modification(s)"
        default:
            return nil
        }
    }

    /// Hook stdout JSON for a PermissionRequest decision. Only "allow once" or "deny" exist:
    /// no `updatedPermissions` is ever sent, so no persistent rule is created.
    public static func permissionOutput(for response: AgentResponse) -> String {
        let decision: [String: JSONValue]
        switch response {
        case .allowOnce:
            decision = ["behavior": .string("allow")]
        case let .deny(reason):
            let message: String
            switch reason {
            case .user: message = "Refusé par l’utilisateur depuis Espazio."
            case .timeout: message = "Aucune réponse dans le délai imparti : refusé par sécurité (Espazio)."
            case .cancelled, .disconnected: message = "Demande annulée (Espazio)."
            }
            decision = ["behavior": .string("deny"), "message": .string(message)]
        case .answer:
            // Not a valid answer for a permission: deny.
            decision = ["behavior": .string("deny"), "message": .string("Réponse invalide (Espazio).")]
        }
        let output: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string(ClaudeHookEvent.permissionRequest.rawValue),
                "decision": .object(decision),
            ]),
        ])
        return output.compactString()
    }
}
