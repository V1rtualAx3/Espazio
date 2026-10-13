import EspazioCore
import SwiftUI

/// Monochrome diff (spec §2: no colour outside the two decision buttons). Additions are bright
/// on a light band, removals dimmed and struck through.
struct DiffView: View {
    let diffs: [FileDiff]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 10))
                            Text(diff.path).font(EZFont.captionEmphasis).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("+\(diff.addedCount)  −\(diff.removedCount)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(EZColor.notchTertiary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(line: line)
                        }
                        if diff.lines.isEmpty {
                            Text("Contenu non communiqué").font(EZFont.caption).foregroundStyle(EZColor.notchTertiary).padding(8)
                        }
                        if diff.truncated {
                            Text("… tronqué — voir le terminal").font(EZFont.caption).foregroundStyle(EZColor.notchTertiary).padding(8)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
        .accessibilityLabel(diffs.map { "\($0.path) : \($0.addedCount) ajouts, \($0.removedCount) suppressions" }.joined(separator: ", "))
    }
}

private struct DiffLineView: View {
    let line: FileDiff.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).frame(width: 10, alignment: .center).foregroundStyle(EZColor.notchTertiary)
            Text(line.text.isEmpty ? " " : line.text)
                .strikethrough(line.kind == .removed, color: EZColor.notchTertiary)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(line.kind == .hunk ? EZFont.caption : EZFont.mono)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(line.kind == .added ? Color.white.opacity(0.10) : .clear)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .hunk: return ""
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .added: return EZColor.notchPrimary
        case .removed: return EZColor.notchTertiary
        case .context: return EZColor.notchSecondary
        case .hunk: return EZColor.notchTertiary
        }
    }
}
