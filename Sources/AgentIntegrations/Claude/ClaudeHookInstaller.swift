import EspazioCore
import Foundation

/// Adds / removes Espazio's command hooks in Claude Code's user settings
/// (`~/.claude/settings.json`). Only entries whose command points to `espazio-hook` are touched;
/// every other setting and hook is preserved. A backup is written before any change.
public enum ClaudeHookInstaller {
    public enum InstallError: Error, Equatable {
        case invalidSettingsFile
        case unreadableSettingsFile
        case helperNotFound(String)
    }

    public static let marker = "espazio-hook"
    /// Seconds Claude waits for the PermissionRequest hook. Espazio itself denies earlier
    /// (settings `agentRequestTimeout`), so Claude's own timeout is only a safety net.
    public static let permissionHookTimeout = 600
    public static let eventHookTimeout = 5

    public static func defaultSettingsURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
    }

    /// Returns the settings JSON with Espazio hooks installed (idempotent).
    public static func installing(into data: Data?, helperPath: String) throws -> Data {
        var root = try parse(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = shellQuoted(helperPath)
        for event in ClaudeHookEvent.allCases {
            var groups = removingEspazio(from: hooks[event.rawValue] as? [[String: Any]] ?? [])
            var handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": event.isBlocking ? permissionHookTimeout : eventHookTimeout,
            ]
            if !event.isBlocking { handler["statusMessage"] = "Espazio" }
            var group: [String: Any] = ["hooks": [handler]]
            if event == .permissionRequest || event == .notification { group["matcher"] = "*" }
            groups.append(group)
            hooks[event.rawValue] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Returns the settings JSON without any Espazio hook.
    public static func removing(from data: Data?) throws -> Data {
        var root = try parse(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try serialize(root) }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = removingEspazio(from: groups)
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any],
            let groups = hooks[ClaudeHookEvent.permissionRequest.rawValue] as? [[String: Any]]
        else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    /// Applies the change to disk with a backup next to the file.
    public static func apply(install: Bool, helperPath: String, settingsURL: URL = defaultSettingsURL()) throws {
        let manager = FileManager.default
        if install, !manager.isExecutableFile(atPath: helperPath) { throw InstallError.helperNotFound(helperPath) }
        // Write through symlinks (dotfiles setups) instead of replacing them.
        let target = settingsURL.resolvingSymlinksInPath()
        let existing = try ConfigFile.read(target)
        let updated = install ? try installing(into: existing, helperPath: helperPath) : try removing(from: existing)
        try ConfigFile.write(updated, to: target, original: existing)
    }

    // MARK: - Private

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty,
            !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.invalidSettingsFile
        }
        return object
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func removingEspazio(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var group = group
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter {
                ($0["command"] as? String)?.contains(marker) != true
            }
            if handlers.isEmpty { return nil }
            group["hooks"] = handlers
            return group
        }
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Safe read / write of a user configuration file.
public enum ConfigFile {
    /// `nil` only when the file does not exist; any other read error aborts the change so the
    /// file is never rewritten from scratch.
    public static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ClaudeHookInstaller.InstallError.unreadableSettingsFile
        }
    }

    /// Keeps the *first* backup (`<file>.espazio-backup`), so the original survives repeated
    /// install / uninstall cycles.
    public static func write(_ data: Data, to url: URL, original: Data?) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("espazio-backup")
        if let original, !manager.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
