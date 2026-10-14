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

/// Unread Google Chat conversations only: Espazio says there is something to read, the user
/// reads and answers in Google Chat.
struct ChatTab: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        if case .connected = state.chatStatus {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(header).font(EZFont.captionEmphasis).foregroundStyle(EZColor.notchSecondary)
                    Spacer()
                    EZIconButton("arrow.clockwise", label: "Actualiser", size: 10) { actions.refreshGoogle() }
                }
                if state.chatUnread.isEmpty {
                    EZPlaceholder(symbol: "checkmark.bubble", title: "Aucun message non lu")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(state.chatUnread) { chat in
                                ChatUnreadRow(chat: chat) { actions.openChat(chat) }
                            }
                        }
                    }
                }
            }
        } else {
            ConnectorStatusView(status: state.chatStatus, service: "Google Chat", symbol: "bubble.left.and.bubble.right", actions: actions)
        }
    }

    private var header: String {
        let count = state.chatUnread.count
        return count == 0 ? "Google Chat" : "\(count) conversation\(count > 1 ? "s" : "") non lue\(count > 1 ? "s" : "")"
    }
}

private struct ChatUnreadRow: View {
    let chat: ChatUnread
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: chat.space.isDirectMessage ? "person.fill" : "number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EZColor.notchSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(EZColor.notchRaised))
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(chat.title).font(EZFont.bodyEmphasis).lineLimit(1)
                        if chat.messages.count > 1 {
                            Text(BadgeCount.text(chat.messages.count))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(EZColor.notchBackground)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(EZColor.notchSecondary))
                        }
                        Spacer()
                        if let date = chat.date {
                            Text(CompactTime.string(for: date, now: Date()))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(EZColor.notchTertiary)
                        }
                    }
                    Text(chat.preview).font(EZFont.caption).foregroundStyle(EZColor.notchTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? EZColor.notchRaised : EZColor.notchRaised.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(chat.title), \(chat.messages.count) non lu\(chat.messages.count > 1 ? "s" : ""), \(chat.preview)")
        .accessibilityHint("Ouvre la conversation dans Google Chat")
    }
}
