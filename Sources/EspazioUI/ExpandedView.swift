import EspazioCore
import SwiftUI

/// Expanded notch: header row on both sides of the camera, then the selected tab.
struct ExpandedView: View {
    let presentation: NotchPresentation
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        let geometry = presentation.geometry
        VStack(spacing: 8) {
            header(notchWidth: geometry.notchRect.width, height: geometry.notchRect.height)
            Group {
                switch presentation.tab {
                case .home: HomeTab(state: state, actions: actions, presentation: presentation)
                case .agents: AgentsTab(state: state, actions: actions)
                case .mail: MailTab(state: state, actions: actions)
                case .chat: ChatTab(state: state, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .foregroundStyle(EZColor.notchPrimary)
        .onExitCommand { actions.collapseNotch() }
    }

    private func header(notchWidth: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(state.visibleTabs) { tab in
                TabButton(tab: tab, selected: presentation.tab == tab, badge: badge(for: tab)) {
                    presentation.tab = tab
                }
            }
            Spacer(minLength: notchWidth + 8)
            FocusMenu(mode: state.settings.focusMode, pending: state.pendingDecisionCount) { actions.setFocusMode($0) }
            EZIconButton("gearshape", label: "Réglages", size: 12) { actions.openSettings() }
        }
        .frame(height: max(height, 28))
    }

    private func badge(for tab: NotchTab) -> Int? {
        switch tab {
        case .agents: return state.pendingRequests.isEmpty ? nil : state.pendingRequests.count
        case .mail: return state.unreadCount.flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: selected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .foregroundStyle(selected ? EZColor.notchPrimary : EZColor.notchSecondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? EZColor.notchRaised : (hovering ? EZColor.notchRaised.opacity(0.5) : .clear)))
                if let badge {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Color.white))
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title + (badge.map { ", \($0)" } ?? ""))
        .help(tab.title)
    }
}

private struct FocusMenu: View {
    let mode: FocusMode
    let pending: Int
    let onSelect: @MainActor (FocusMode) -> Void

    var body: some View {
        Menu {
            Picker("Concentration", selection: Binding(get: { mode }, set: onSelect)) {
                Text("Normal").tag(FocusMode.normal)
                Text("Concentré (P0–P1 seulement)").tag(FocusMode.focused)
                Text("Silencieux").tag(FocusMode.silent)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(mode == .normal ? EZColor.notchSecondary : EZColor.notchPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 24)
        .accessibilityLabel("Mode de concentration")
        .help("Mode de concentration")
    }

    private var symbol: String {
        switch mode {
        case .normal: return "moon"
        case .focused: return "moon.fill"
        case .silent: return "bell.slash.fill"
        }
    }
}

// MARK: - Home

struct HomeTab: View {
    let state: EspazioState
    let actions: EspazioActions
    let presentation: NotchPresentation

    var body: some View {
        VStack(spacing: 8) {
            if !state.pendingRequests.isEmpty {
                Button {
                    presentation.tab = .agents
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.shield")
                        Text(state.pendingRequests.count == 1 ? "1 demande d’agent en attente" : "\(state.pendingRequests.count) demandes d’agents en attente")
                            .font(EZFont.bodyEmphasis)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EZColor.notchRaised))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if state.settings.modules.media {
                    MediaCard(state: state, actions: actions)
                }
                if state.settings.modules.calendar || state.settings.modules.googleCalendar {
                    NextEventCard(state: state, actions: actions)
                }
                if state.settings.modules.reminders {
                    RemindersCard(state: state, actions: actions)
                }
            }
        }
    }
}

struct MediaCard: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        EZCard {
            if let playing = state.nowPlaying {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        artwork
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playing.title).font(EZFont.title).lineLimit(1)
                            Text(playing.artist).font(EZFont.caption).foregroundStyle(EZColor.notchSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if playing.duration != nil, playing.position != nil {
                        MediaProgress(playing: playing)
                    }
                    HStack(spacing: 6) {
                        Spacer()
                        EZIconButton("backward.fill", label: "Piste précédente", size: 12) { actions.previousTrack() }
                        EZIconButton(playing.state == .playing ? "pause.fill" : "play.fill", label: playing.state == .playing ? "Pause" : "Lecture", size: 15) {
                            actions.togglePlayPause()
                        }
                        EZIconButton("forward.fill", label: "Piste suivante", size: 12) { actions.nextTrack() }
                        Spacer()
                    }
                }
            } else {
                EZPlaceholder(
                    symbol: "music.note", title: "Aucune lecture",
                    message: state.mediaAvailable ? "Spotify est en pause." : "Lancez Spotify pour afficher la lecture.",
                    actionTitle: "Ouvrir Spotify") { actions.openMediaApp() }
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = state.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(EZColor.notchTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(EZColor.notchRaisedHover)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Progress extrapolated locally; the timeline only ticks while the view is on screen and
/// the track is playing (no polling of the player).
struct MediaProgress: View {
    let playing: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let progress = playing.progress(at: playing.state == .playing ? context.date : playing.positionDate) ?? 0
            VStack(spacing: 3) {
                EZProgressBar(value: progress)
                HStack {
                    Text(format(playing.position(at: context.date) ?? 0))
                    Spacer()
                    Text(format(playing.duration ?? 0))
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(EZColor.notchTertiary)
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct NextEventCard: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        EZCard {
            if state.calendarAccess == .granted || (state.settings.modules.googleCalendar && !state.events.isEmpty) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let event = state.nextEvent(now: context.date) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Prochain événement", systemImage: "calendar")
                                .font(EZFont.caption).foregroundStyle(EZColor.notchSecondary)
                            Text(event.title).font(EZFont.title).lineLimit(2)
                            Text(CountdownFormatter.string(until: event.start, end: event.end, now: context.date))
                                .font(EZFont.bodyEmphasis)
                            Text(event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened))
                                .font(EZFont.caption).foregroundStyle(EZColor.notchTertiary)
                            Spacer(minLength: 0)
                            HStack(spacing: 6) {
                                if let url = event.meetingURL {
                                    Button("Rejoindre") { actions.joinMeeting(url) }.buttonStyle(EZButtonStyle())
                                }
                                Button("Ouvrir") { actions.openEvent(event) }.buttonStyle(EZButtonStyle(.subtle))
                            }
                        }
                    } else {
                        EZPlaceholder(symbol: "calendar", title: "Rien de prévu", message: "Aucun événement dans les 24 h.")
                    }
                }
            } else if state.calendarAccess == .notDetermined {
                EZPlaceholder(symbol: "calendar", title: "Calendrier", message: "Autorisez l’accès pour voir vos rendez-vous.",
                              actionTitle: "Autoriser") { actions.requestCalendarAccess() }
            } else {
                EZPlaceholder(symbol: "calendar.badge.exclamationmark", title: "Accès refusé",
                              message: "Réglages Système › Confidentialité › Calendriers.")
            }
        }
    }
}

struct RemindersCard: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        EZCard {
            switch state.remindersAccess {
            case .granted:
                if state.reminders.isEmpty {
                    EZPlaceholder(symbol: "checklist", title: "Tout est fait", message: "Aucun rappel aujourd’hui.",
                                  actionTitle: "Rappels") { actions.openReminders() }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Rappels (\(state.reminders.count))", systemImage: "checklist")
                            .font(EZFont.caption).foregroundStyle(EZColor.notchSecondary)
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(state.reminders.overdue) { ReminderRow(reminder: $0, overdue: true, actions: actions) }
                                ForEach(state.reminders.today) { ReminderRow(reminder: $0, overdue: false, actions: actions) }
                            }
                        }
                    }
                }
            case .notDetermined:
                EZPlaceholder(symbol: "checklist", title: "Rappels", message: "Autorisez l’accès pour voir vos tâches du jour.",
                              actionTitle: "Autoriser") { actions.requestRemindersAccess() }
            default:
                EZPlaceholder(symbol: "checklist", title: "Accès refusé", message: "Réglages Système › Confidentialité › Rappels.")
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderItem
    let overdue: Bool
    let actions: EspazioActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                actions.completeReminder(id: reminder.id)
            } label: {
                Image(systemName: "circle").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Terminer \(reminder.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title).font(EZFont.body).lineLimit(1)
                if let due = reminder.due {
                    Text((overdue ? "En retard · " : "") + (reminder.hasDueTime ? due.formatted(date: overdue ? .abbreviated : .omitted, time: .shortened) : due.formatted(date: .abbreviated, time: .omitted)))
                        .font(.system(size: 10, weight: overdue ? .semibold : .regular))
                        .foregroundStyle(overdue ? EZColor.notchPrimary : EZColor.notchTertiary)
                }
            }
        }
    }
}
