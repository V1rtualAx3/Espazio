import Foundation

/// A file change shown in the decision card (spec §7: context displayed before deciding).
public struct FileDiff: Sendable, Equatable, Codable {
    public enum LineKind: String, Sendable, Codable {
        case context
        case added
        case removed
        /// `@@ … @@` hunk header or elision marker.
        case hunk
    }

    public struct Line: Sendable, Equatable, Codable {
        public var kind: LineKind
        public var text: String

        public init(_ kind: LineKind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public var path: String
    public var lines: [Line]
    /// True when lines were dropped to respect the display bound.
    public var truncated: Bool

    public init(path: String, lines: [Line], truncated: Bool = false) {
        self.path = path
        self.lines = lines
        self.truncated = truncated
    }

    public var addedCount: Int { lines.lazy.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.lazy.filter { $0.kind == .removed }.count }
}

/// Bounded line diff (LCS) and unified-diff parsing. Inputs are capped so a huge file never
/// costs more than a few milliseconds or a few hundred kilobytes.
public enum DiffEngine {
    public static let maxInputLines = 600
    public static let maxOutputLines = 400
    public static let contextLines = 3

    /// Diff between two texts with `contextLines` of context around changes.
    public static func diff(path: String, old: String, new: String) -> FileDiff {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard oldLines.count <= maxInputLines, newLines.count <= maxInputLines else {
            // Too large for an LCS: show removals then additions, bounded.
            let lines = oldLines.map { FileDiff.Line(.removed, $0) } + newLines.map { FileDiff.Line(.added, $0) }
            return bounded(path: path, lines)
        }
        return bounded(path: path, withContext(lcsDiff(oldLines, newLines)))
    }

    /// Parses a unified diff (as produced by `git diff` / Codex `fileChange` items).
    public static func parseUnified(_ text: String, fallbackPath: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var currentPath: String?
        var current: [FileDiff.Line] = []
        func flush() {
            if !current.isEmpty || currentPath != nil {
                files.append(bounded(path: currentPath ?? fallbackPath, current))
            }
            current = []
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                flush()
                currentPath = raw.components(separatedBy: " b/").last
            } else if raw.hasPrefix("+++ ") {
                let path = String(raw.dropFirst(4))
                if path != "/dev/null" { currentPath = path.hasPrefix("b/") ? String(path.dropFirst(2)) : path }
            } else if raw.hasPrefix("--- ") || raw.hasPrefix("index ") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") {
                continue
            } else if raw.hasPrefix("@@") {
                current.append(.init(.hunk, raw))
            } else if raw.hasPrefix("+") {
                current.append(.init(.added, String(raw.dropFirst())))
            } else if raw.hasPrefix("-") {
                current.append(.init(.removed, String(raw.dropFirst())))
            } else if raw.hasPrefix(" ") {
                current.append(.init(.context, String(raw.dropFirst())))
            } else if !raw.isEmpty, current.isEmpty, currentPath == nil {
                // Not a unified diff: treat the whole text as new content.
                return [bounded(path: fallbackPath, text.components(separatedBy: "\n").map { .init(.added, $0) })]
            }
        }
        flush()
        return files.filter { !$0.lines.isEmpty }
    }

    // MARK: - Private

    private static func lcsDiff(_ a: [String], _ b: [String]) -> [FileDiff.Line] {
        let n = a.count, m = b.count
        // lengths[i][j] = LCS of a[i...] and b[j...]
        var lengths = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var result: [FileDiff.Line] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(.init(.context, a[i])); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(.init(.removed, a[i])); i += 1
            } else {
                result.append(.init(.added, b[j])); j += 1
            }
        }
        while i < n { result.append(.init(.removed, a[i])); i += 1 }
        while j < m { result.append(.init(.added, b[j])); j += 1 }
        return result
    }

    /// Keeps `contextLines` around changes, replacing long unchanged runs with an elision marker.
    private static func withContext(_ lines: [FileDiff.Line]) -> [FileDiff.Line] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - contextLines)...min(lines.count - 1, index + contextLines) { keep.insert(k) }
        }
        var result: [FileDiff.Line] = []
        var previous: Int?
        for index in keep.sorted() {
            if index > (previous.map { $0 + 1 } ?? 0) { result.append(.init(.hunk, "…")) }
            result.append(lines[index])
            previous = index
        }
        if let previous, previous < lines.count - 1 { result.append(.init(.hunk, "…")) }
        return result
    }

    private static func bounded(path: String, _ lines: [FileDiff.Line]) -> FileDiff {
        let clipped = lines.prefix(maxOutputLines).map { line in
            FileDiff.Line(line.kind, line.text.count > 400 ? String(line.text.prefix(400)) + "…" : line.text)
        }
        return FileDiff(path: path, lines: Array(clipped), truncated: lines.count > maxOutputLines)
    }
}
