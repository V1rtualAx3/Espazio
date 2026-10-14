import EspazioCore
import SwiftUI

/// Connector status placeholder shared by Gmail and Chat.
struct ConnectorStatusView: View {
    let status: ConnectorStatus
    let service: String
    let symbol: String
    let actions: EspazioActions

    var body: some View {
        switch status {
        case .disconnected:
            EZPlaceholder(symbol: symbol, title: "\(service) non connecté", message: "Connectez votre compte Google dans les réglages.",
                          actionTitle: "Connecter") { actions.connectGoogle() }
        case .connecting:
            EZPlaceholder(symbol: "hourglass", title: "Connexion…")
        case let .unsupported(reason):
            EZPlaceholder(symbol: "nosign", title: "Non pris en charge pour ce compte", message: reason)
        case let .error(message, retryAt):
            EZPlaceholder(
                symbol: "exclamationmark.triangle", title: "Synchronisation interrompue",
                message: message + (retryAt.map { " · Nouvel essai " + $0.formatted(date: .omitted, time: .shortened) } ?? ""),
                actionTitle: "Réessayer") { actions.refreshGoogle() }
        case .needsReauthorization:
            EZPlaceholder(symbol: "person.badge.key", title: "Autorisation expirée", message: "Reconnectez votre compte Google.",
                          actionTitle: "Reconnecter") { actions.connectGoogle() }
        case .connected:
            EmptyView()
        }
    }
}

struct MailTab: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        if case .connected = state.gmailStatus {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.unreadCount.map { "\($0) non lu\($0 > 1 ? "s" : "")" } ?? "Boîte de réception")
                        .font(EZFont.captionEmphasis).foregroundStyle(EZColor.notchSecondary)
                    Spacer()
                    EZIconButton("arrow.clockwise", label: "Actualiser", size: 10) { actions.refreshGoogle() }
                }
                if state.mail.isEmpty {
                    EZPlaceholder(symbol: "tray", title: "Aucun message non lu")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(state.mail) { mail in
                                MailRow(mail: mail, canModify: state.gmailCanModify, actions: actions)
                            }
                        }
                    }
                }
            }
        } else {
            ConnectorStatusView(status: state.gmailStatus, service: "Gmail", symbol: "envelope", actions: actions)
        }
    }
}

struct MailRow: View {
    let mail: MailSummary
    let canModify: Bool
    let actions: EspazioActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                actions.openMail(mail)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(mail.senderName).font(EZFont.bodyEmphasis).lineLimit(1)
                        Spacer()
                        if let date = mail.date {
                            Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(EZColor.notchTertiary)
                        }
                    }
                    Text(mail.subject.isEmpty ? "(Sans objet)" : mail.subject).font(EZFont.body).lineLimit(1)
                    Text(mail.snippet).font(EZFont.caption).foregroundStyle(EZColor.notchTertiary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                EZIconButton("envelope.open", label: canModify ? "Marquer comme lu" : "Marquer comme lu (autorisation supplémentaire requise)", size: 10) {
                    actions.markMailRead(mail)
                }
                EZIconButton("archivebox", label: "Archiver", size: 10) { actions.archiveMail(mail) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? EZColor.notchRaised : EZColor.notchRaised.opacity(0.5)))
        .onHover { hovering = $0 }
    }
}

struct ChatTab: View {
    let state: EspazioState
    let actions: EspazioActions
    @State private var selectedSpace: String?
    @State private var draft = ""

    /// Selected conversation, or the most recent one: the tab never opens on an empty pane.
    private var activeSpace: ChatSpace? {
        state.chatSpaces.first { $0.id == selectedSpace } ?? state.chatSpaces.first
    }

    var body: some View {
        if case .connected = state.chatStatus {
            if state.chatSpaces.isEmpty {
                EZPlaceholder(symbol: "bubble.left.and.bubble.right", title: "Aucune conversation")
            } else {
                HStack(spacing: 10) {
                    spaceList.frame(width: 190)
                    Rectangle().fill(EZColor.notchRaised).frame(width: 1)
                    if let space = activeSpace {
                        conversation(space)
                            .task(id: space.id) { actions.loadChatMessages(spaceID: space.id) }
                    }
                }
            }
        } else {
            ConnectorStatusView(status: state.chatStatus, service: "Google Chat", symbol: "bubble.left.and.bubble.right", actions: actions)
        }
    }

    private var spaceList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(state.chatSpaces) { space in
                    ChatSpaceRow(
                        space: space, selected: space.id == activeSpace?.id,
                        unread: state.chatUnread.contains(space.id),
                        preview: state.chatMessages[space.id]?.last
                    ) {
                        selectedSpace = space.id
                    }
                }
            }
        }
    }

    private func conversation(_ space: ChatSpace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(space.displayName).font(EZFont.bodyEmphasis).lineLimit(1)
                Spacer()
                EZIconButton("arrow.up.right.square", label: "Ouvrir dans Google Chat", size: 10) { actions.openChatSpace(space) }
            }
            let messages = state.chatMessages[space.id] ?? []
            if messages.isEmpty {
                EZPlaceholder(symbol: "hourglass", title: "Chargement…")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                ChatMessageRow(message: message, showsSender: !space.isDirectMessage).id(message.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                    .onChange(of: messages.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if state.chatCanReply {
                HStack(spacing: 6) {
                    TextField("Répondre…", text: $draft)
                        .textFieldStyle(.plain).font(EZFont.body)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(EZColor.notchRaised))
                        .onSubmit { send(to: space.id) }
                    EZIconButton("arrow.up.circle.fill", label: "Envoyer", size: 16) { send(to: space.id) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send(to spaceID: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.sendChatReply(spaceID: spaceID, text: text)
        draft = ""
    }
}

private struct ChatSpaceRow: View {
    let space: ChatSpace
    let selected: Bool
    let unread: Bool
    let preview: ChatMessage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(EZColor.notchRaised)
                    Image(systemName: space.isDirectMessage ? "person.fill" : "number")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(EZColor.notchSecondary)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(space.displayName)
                            .font(unread ? EZFont.bodyEmphasis : EZFont.body)
                            .foregroundStyle(unread || selected ? EZColor.notchPrimary : EZColor.notchSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let date = space.lastActive {
                            Text(CompactTime.string(for: date, now: Date()))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(EZColor.notchTertiary)
                        }
                    }
                    if let preview {
                        Text(preview.text)
                            .font(EZFont.caption)
                            .foregroundStyle(EZColor.notchTertiary)
                            .lineLimit(1)
                    }
                }
                Circle()
                    .fill(EZColor.notchPrimary)
                    .frame(width: 6, height: 6)
                    .opacity(unread ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? EZColor.notchRaised : hovering ? EZColor.notchRaised.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(space.displayName + (unread ? ", nouveaux messages" : ""))
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let showsSender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if showsSender {
                    Text(message.sender).font(EZFont.captionEmphasis).foregroundStyle(EZColor.notchSecondary).lineLimit(1)
                }
                if let date = message.createTime {
                    Text(CompactTime.string(for: date, now: Date()))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(EZColor.notchTertiary)
                }
            }
            Text(message.text)
                .font(EZFont.body)
                .foregroundStyle(EZColor.notchPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EZColor.notchRaised))
        }
    }
}
