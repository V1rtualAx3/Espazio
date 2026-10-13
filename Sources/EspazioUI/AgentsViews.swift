import EspazioCore
import SwiftUI

struct AgentsTab: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        if let request = state.pendingRequests.first {
            ApprovalCard(
                request: request, position: 1, total: state.pendingRequests.count,
                session: state.sessions.first { $0.id == request.sessionID }, actions: actions)
                .id(request.id)
        } else {
            SessionList(state: state, actions: actions)
        }
    }
}

/// Decision card. Shows everything needed before deciding (spec §7): provider, project,
/// session, tool, full command, directory and context. No keyboard shortcut approves: the
/// user must click "Autoriser une fois".
public struct ApprovalCard: View {
    let request: AgentRequest
    let position: Int
    let total: Int
    let session: AgentSession?
    let actions: EspazioActions
    @State private var answer = ""

    public init(request: AgentRequest, position: Int, total: Int, session: AgentSession?, actions: EspazioActions) {
        self.request = request
        self.position = position
        self.total = total
        self.session = session
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ProviderStyle.symbol(request.provider)).font(.system(size: 12, weight: .semibold))
                Text(request.provider.displayName).font(EZFont.title)
                Text("·").foregroundStyle(EZColor.notchTertiary)
                Text(session?.projectName ?? request.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Session")
                    .font(EZFont.bodyEmphasis).lineLimit(1)
                Text(kindLabel)
                    .font(EZFont.captionEmphasis)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(EZColor.notchRaisedHover))
                Spacer(minLength: 4)
                if total > 1 {
                    Text("\(position)/\(total)").font(EZFont.caption).foregroundStyle(EZColor.notchTertiary)
                }
                DeadlineLabel(deadline: request.deadline)
            }

            Group {
                if request.diffs.isEmpty {
                    ScrollView(.vertical) {
                        Text(request.summary)
                            .font(EZFont.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 64)
                    .accessibilityLabel("Commande : \(request.summary)")
                } else {
                    DiffView(diffs: request.diffs).frame(maxHeight: 96)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EZColor.notchRaised))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                if let cwd = request.workingDirectory {
                    Label(cwd, systemImage: "folder").lineLimit(1).truncationMode(.head)
                }
                if let detail = request.detail, !detail.isEmpty {
                    Text(detail).lineLimit(2)
                }
                Text("Session \(String(request.sessionID.prefix(8))) · \(request.toolName)")
                    .foregroundStyle(EZColor.notchTertiary)
            }
            .font(EZFont.caption)
            .foregroundStyle(EZColor.notchSecondary)

            Spacer(minLength: 0)
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        if case let .question(options) = request.kind {
            HStack(spacing: 6) {
                ForEach(options.prefix(3), id: \.self) { option in
                    Button(option) { actions.resolve(request, response: .answer(option)) }.buttonStyle(EZButtonStyle())
                }
                TextField("Réponse", text: $answer)
                    .textFieldStyle(.plain)
                    .font(EZFont.body)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(EZColor.notchRaised))
                    .onSubmit(sendAnswer)
                Button("Envoyer", action: sendAnswer).buttonStyle(EZButtonStyle()).disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Ignorer") { actions.resolve(request, response: .deny(.user)) }.buttonStyle(EZButtonStyle(.subtle))
            }
        } else {
            HStack(spacing: 8) {
                if let session, session.clientHint != nil {
                    Button("Ouvrir le terminal") { actions.openSession(session) }.buttonStyle(EZButtonStyle(.subtle))
                }
                Spacer()
                Button("Refuser") { actions.resolve(request, response: .deny(.user)) }
                    .buttonStyle(EZButtonStyle(.deny))
                    .accessibilityHint("Refuse cette action de l’agent")
                Button("Autoriser une fois") { actions.resolve(request, response: .allowOnce) }
                    .buttonStyle(EZButtonStyle(.allow))
                    .accessibilityHint("Autorise uniquement cette action")
            }
        }
    }

    private func sendAnswer() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.resolve(request, response: .answer(text))
    }

    private var kindLabel: String {
        switch request.kind {
        case .command: return "Commande"
        case .fileChange: return "Fichiers"
        case .tool: return request.toolName
        case .question: return "Question"
        }
    }
}

/// "Refus auto 4:32" countdown; ticks once per second only while displayed.
struct DeadlineLabel: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            Text("Refus auto \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(EZColor.notchTertiary)
        }
        .accessibilityLabel("Refus automatique à l’expiration du délai")
    }
}

struct SessionList: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        VStack(spacing: 6) {
            if state.sessions.isEmpty {
                EZPlaceholder(
                    symbol: "sparkles", title: "Aucune session IA",
                    message: state.claudeHooksInstalled
                        ? "Les sessions Claude Code et Codex apparaîtront ici."
                        : "Activez l’intégration Claude Code dans les réglages.",
                    actionTitle: state.claudeHooksInstalled ? nil : "Réglages", action: state.claudeHooksInstalled ? nil : { actions.openSettings() })
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(state.sessions) { session in
                            SessionRow(session: session) { actions.openSession(session) }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                if state.settings.modules.codex {
                    Button {
                        actions.startCodexSession()
                    } label: {
                        Label("Session Codex", systemImage: "plus")
                    }
                    .buttonStyle(EZButtonStyle())
                }
                if state.settings.modules.chatGPT {
                    Button {
                        actions.openChatGPT()
                    } label: {
                        Label(state.chatGPTRunning ? "ChatGPT (ouvert)" : "ChatGPT", systemImage: "bubble.left")
                    }
                    .buttonStyle(EZButtonStyle(.subtle))
                }
                Spacer()
            }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: ProviderStyle.symbol(session.provider))
                    .font(.system(size: 12, weight: .semibold)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.projectName).font(EZFont.bodyEmphasis).lineLimit(1)
                        if session.control == .observeOnly {
                            Text("Lecture seule").font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().strokeBorder(EZColor.notchTertiary, lineWidth: 0.5))
                                .foregroundStyle(EZColor.notchTertiary)
                        }
                    }
                    if let message = session.lastMessage {
                        Text(message).font(EZFont.caption).foregroundStyle(EZColor.notchTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                StateBadge(state: session.state)
                Text(session.lastActivity, style: .relative)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(EZColor.notchTertiary)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? EZColor.notchRaised : EZColor.notchRaised.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(session.provider.displayName), \(session.projectName), \(StateBadge.label(session.state))")
    }
}

struct StateBadge: View {
    let state: AgentSessionState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(Self.label(state)).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(state == .waiting ? EZColor.notchPrimary : EZColor.notchSecondary)
    }

    private var symbol: String {
        switch state {
        case .active: return "circle.fill"
        case .waiting: return "hand.raised.fill"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .ended: return "stop.fill"
        }
    }

    static func label(_ state: AgentSessionState) -> String {
        switch state {
        case .active: return "Actif"
        case .waiting: return "En attente"
        case .completed: return "Terminé"
        case .failed: return "Échec"
        case .ended: return "Fermé"
        }
    }
}

enum ProviderStyle {
    static func symbol(_ provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .chatGPT: return "bubble.left"
        }
    }
}
