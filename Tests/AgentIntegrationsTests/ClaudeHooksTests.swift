@testable import AgentIntegrations
import EspazioCore
import XCTest

final class ClaudeHooksTests: XCTestCase {
    let permissionJSON = #"""
    {"session_id":"abc","transcript_path":"/t.jsonl","cwd":"/Users/me/proj","hook_event_name":"PermissionRequest",
     "permission_mode":"default","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run tests"},
     "tool_use_id":"toolu_1","extra_future_field":42}
    """#

    func testDecodePermissionRequest() throws {
        let input = try ClaudeHookInput.decode(permissionJSON)
        XCTAssertEqual(input.sessionID, "abc")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.toolInput?["command"]?.stringValue, "npm test -- --watch=false")
    }

    func testApprovalRequestMapping() throws {
        let input = try ClaudeHookInput.decode(permissionJSON)
        let now = Date()
        let request = try XCTUnwrap(ClaudeHookMapper.approvalRequest(for: input, fallbackID: "f", now: now, timeout: 120))
        XCTAssertEqual(request.id, "claude:abc:toolu_1")
        XCTAssertEqual(request.kind, .command)
        XCTAssertEqual(request.summary, "npm test -- --watch=false")
        XCTAssertEqual(request.detail, "Run tests")
        XCTAssertEqual(request.workingDirectory, "/Users/me/proj")
        XCTAssertEqual(request.deadline, now.addingTimeInterval(120))
    }

    func testFileChangeAndFallbackID() throws {
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a.swift","old_string":"x","new_string":"y"}}"#
        let request = try XCTUnwrap(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(json), fallbackID: "F", now: Date(), timeout: 60))
        XCTAssertEqual(request.kind, .fileChange)
        XCTAssertEqual(request.summary, "/a.swift")
        XCTAssertEqual(request.id, "claude:s:F")
        XCTAssertEqual(request.diffs.first?.addedCount, 1)
    }

    func testFileChangeDiffs() throws {
        let edit = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a.swift","old_string":"let x = 1","new_string":"let x = 2"}}"#
        let request = try XCTUnwrap(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(edit), fallbackID: "F", now: Date(), timeout: 60))
        XCTAssertEqual(request.diffs.first?.lines, [.init(.removed, "let x = 1"), .init(.added, "let x = 2")])
        XCTAssertNil(request.detail, "diff replaces the textual detail")

        let write = #"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"notes.md","content":"a\nB\nc"}}"#
        var readPath: String?
        let written = try XCTUnwrap(ClaudeHookMapper.approvalRequest(
            for: try ClaudeHookInput.decode(write), fallbackID: "F", now: Date(), timeout: 60,
            readFile: { path in readPath = path; return "a\nb\nc" }))
        XCTAssertEqual(readPath, "/p/notes.md")
        XCTAssertEqual(written.diffs.first?.removedCount, 1)
        XCTAssertEqual(written.diffs.first?.addedCount, 1)

        let bash = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        XCTAssertTrue(try XCTUnwrap(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(bash), fallbackID: "F", now: Date(), timeout: 60)).diffs.isEmpty)
    }

    func testInteractiveToolsArePassedThrough() throws {
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#
        XCTAssertNil(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(json), fallbackID: "F", now: Date(), timeout: 60))
        let other = #"{"session_id":"s","hook_event_name":"Stop"}"#
        XCTAssertNil(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(other), fallbackID: "F", now: Date(), timeout: 60))
    }

    func testHugeCommandIsBoundedAndFlagged() throws {
        let command = String(repeating: "a", count: 20_000)
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"\#(command)"}}"#
        let request = try XCTUnwrap(ClaudeHookMapper.approvalRequest(for: try ClaudeHookInput.decode(json), fallbackID: "F", now: Date(), timeout: 60))
        XCTAssertTrue(request.summary.hasSuffix("[tronqué — voir le terminal]"))
    }

    func testEventMapping() throws {
        func event(_ json: String) throws -> AgentEvent? {
            ClaudeHookMapper.agentEvent(for: try ClaudeHookInput.decode(json), clientHint: "Apple_Terminal")
        }
        XCTAssertEqual(
            try event(#"{"session_id":"s","hook_event_name":"SessionStart","cwd":"/p","source":"startup"}"#),
            .sessionStarted(sessionID: "s", provider: .claudeCode, projectPath: "/p", control: .approvals, clientHint: "Apple_Terminal"))
        XCTAssertEqual(
            try event(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting"}"#),
            .waiting(sessionID: "s", provider: .claudeCode, message: "Claude is waiting"))
        XCTAssertEqual(
            try event(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"Done. token=abc"}"#),
            .turnCompleted(sessionID: "s", provider: .claudeCode, message: "Done. token=[REDACTED]"))
        XCTAssertEqual(try event(#"{"session_id":"s","hook_event_name":"SessionEnd","reason":"other"}"#), .sessionEnded(sessionID: "s", provider: .claudeCode))
        XCTAssertEqual(try event(#"{"session_id":"s","hook_event_name":"FutureEvent"}"#), .activity(sessionID: "s", provider: .claudeCode, message: nil))
    }

    func testPermissionOutputs() throws {
        func decision(_ response: AgentResponse) throws -> JSONValue? {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(ClaudeHookMapper.permissionOutput(for: response).utf8))
            XCTAssertEqual(json["hookSpecificOutput"]?["hookEventName"]?.stringValue, "PermissionRequest")
            XCTAssertNil(json["hookSpecificOutput"]?["decision"]?["updatedPermissions"], "never persist a rule")
            return json["hookSpecificOutput"]?["decision"]
        }
        XCTAssertEqual(try decision(.allowOnce)?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(try decision(.deny(.user))?["behavior"]?.stringValue, "deny")
        XCTAssertEqual(try decision(.deny(.timeout))?["behavior"]?.stringValue, "deny")
        XCTAssertEqual(try decision(.answer("x"))?["behavior"]?.stringValue, "deny")
    }

    func testInstallerIsIdempotentAndPreservesOtherHooks() throws {
        let existing = #"""
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-linter"}]}],
         "Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"/old/espazio-hook"}]}]}}
        """#
        let helper = "/Applications/Espazio.app/Contents/MacOS/espazio-hook"
        let once = try ClaudeHookInstaller.installing(into: Data(existing.utf8), helperPath: helper)
        let twice = try ClaudeHookInstaller.installing(into: once, helperPath: helper)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(in: twice))

        let root = try JSONDecoder().decode(JSONValue.self, from: twice)
        XCTAssertEqual(root["model"]?.stringValue, "opus")
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?.arrayValue?.count, 1)
        let stopGroups = try XCTUnwrap(root["hooks"]?["Stop"]?.arrayValue)
        let stopCommands = stopGroups.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
        XCTAssertEqual(stopCommands, ["say done", "'\(helper)'"])
        let permission = try XCTUnwrap(root["hooks"]?["PermissionRequest"]?.arrayValue?.first)
        XCTAssertEqual(permission["hooks"]?.arrayValue?.first?["timeout"]?.doubleValue, 600)

        let removed = try ClaudeHookInstaller.removing(from: twice)
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(in: removed))
        let cleaned = try JSONDecoder().decode(JSONValue.self, from: removed)
        XCTAssertNil(cleaned["hooks"]?["PermissionRequest"])
        XCTAssertEqual(cleaned["hooks"]?["PreToolUse"]?.arrayValue?.count, 1)
        let remainingStop = cleaned["hooks"]?["Stop"]?.arrayValue?.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
        XCTAssertEqual(remainingStop, ["say done"])
    }

    func testInstallerRejectsInvalidJSONAndHandlesEmptyFile() throws {
        XCTAssertThrowsError(try ClaudeHookInstaller.installing(into: Data("{oops".utf8), helperPath: "/x/espazio-hook"))
        let fresh = try ClaudeHookInstaller.installing(into: Data(), helperPath: "/x/espazio-hook")
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(in: fresh))
    }

    func testShellQuoting() {
        XCTAssertEqual(ClaudeHookInstaller.shellQuoted("/a b/it's"), #"'/a b/it'\''s'"#)
    }
}
