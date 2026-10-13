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

    var body: some View {
        if case .connected = state.chatStatus {
            HStack(spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(state.chatSpaces) { space in
                            Button {
                                selectedSpace = space.id
                                actions.loadChatMessages(spaceID: space.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: space.isDirectMessage ? "person" : "number").font(.system(size: 10))
                                    Text(space.displayName).font(EZFont.body).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selectedSpace == space.id ? EZColor.notchRaised : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 170)
                messages
            }
        } else {
            ConnectorStatusView(status: state.chatStatus, service: "Google Chat", symbol: "bubble.left.and.bubble.right", actions: actions)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let spaceID = selectedSpace {
            VStack(spacing: 6) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.chatMessages[spaceID] ?? []) { message in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(message.sender).font(EZFont.captionEmphasis).foregroundStyle(EZColor.notchSecondary)
                                Text(message.text).font(EZFont.body).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if state.chatCanReply {
                    HStack(spacing: 6) {
                        TextField("Répondre…", text: $draft)
                            .textFieldStyle(.plain).font(EZFont.body)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(EZColor.notchRaised))
                            .onSubmit(send)
                        Button("Envoyer", action: send).buttonStyle(EZButtonStyle())
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        } else {
            EZPlaceholder(symbol: "bubble.left.and.bubble.right", title: "Choisissez une conversation")
        }
    }

    private func send() {
        guard let spaceID = selectedSpace else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.sendChatReply(spaceID: spaceID, text: text)
        draft = ""
    }
}
