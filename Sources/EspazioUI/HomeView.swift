import EspazioCore
import SwiftUI

/// Home tab, "Dynamic Island" style: no boxed cards, sections separated by space and a hairline,
/// strong typographic hierarchy, empty modules collapsed to a single quiet line.
struct HomeTab: View {
    let state: EspazioState
    let actions: EspazioActions
    let presentation: NotchPresentation

    private var showsMedia: Bool { state.settings.modules.media }
    private var showsAgenda: Bool {
        state.settings.modules.calendar || state.settings.modules.googleCalendar || state.settings.modules.reminders
    }

    var body: some View {
        VStack(spacing: 10) {
            if !state.pendingRequests.isEmpty {
                PendingBanner(count: state.pendingRequests.count) { presentation.tab = .agents }
            }
            HStack(alignment: .top, spacing: 0) {
                if showsMedia {
                    NowPlayingSection(state: state, actions: actions)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsMedia && showsAgenda {
                    Rectangle()
                        .fill(EZColor.notchStroke)
                        .frame(width: EZMetrics.hairline)
                        .padding(.horizontal, 18)
                }
                if showsAgenda {
                    AgendaSection(state: state, actions: actions)
                        .frame(width: showsMedia ? 190 : nil, alignment: .leading)
                        .frame(maxWidth: showsMedia ? nil : .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct PendingBanner: View {
    let count: Int
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
                Text(count == 1 ? "Un agent attend votre décision" : "\(count) agents attendent votre décision")
                    .font(EZFont.bodyEmphasis)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(EZColor.notchTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Now playing

struct NowPlayingSection: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        if let playing = state.nowPlaying {
            HStack(alignment: .top, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 0) {
                    Text(playing.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(playing.artist)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(EZColor.notchSecondary)
                        .lineLimit(1)
                        .padding(.top, 1)
                    Spacer(minLength: 8)
                    if playing.duration != nil, playing.position != nil {
                        MediaProgress(playing: playing)
                    }
                    HStack(spacing: 22) {
                        control("backward.fill", "Piste précédente", size: 14) { actions.previousTrack() }
                        control(playing.state == .playing ? "pause.fill" : "play.fill",
                                playing.state == .playing ? "Pause" : "Lecture", size: 20) { actions.togglePlayPause() }
                        control("forward.fill", "Piste suivante", size: 14) { actions.nextTrack() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .frame(height: 64 + 36, alignment: .top)
            }
        } else {
            QuietLine(symbol: "music.note", text: state.mediaAvailable ? "\(state.mediaPlayerName) en pause" : "Aucune lecture",
                      actionTitle: "Ouvrir \(state.mediaPlayerName)") { actions.openMediaApp() }
        }
    }

    private var artwork: some View {
        Group {
            if let image = state.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 22, weight: .light)).foregroundStyle(EZColor.notchTertiary)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EZColor.notchStroke, lineWidth: EZMetrics.hairline))
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        MediaControl(symbol: symbol, label: label, size: size, action: action)
    }
}

private struct MediaControl: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 10)
                .foregroundStyle(hovering ? EZColor.notchPrimary : EZColor.notchPrimary.opacity(0.85))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Thin scrubber with elapsed / remaining time. Extrapolated locally; ticks only while visible
/// and playing.
struct MediaProgress: View {
    let playing: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let date = playing.state == .playing ? context.date : playing.positionDate
            let position = playing.position(at: date) ?? 0
            let duration = playing.duration ?? 0
            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(width: 30, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: max(3, proxy.size.width * (playing.progress(at: date) ?? 0)))
                    }
                }
                .frame(height: 3)
                Text("-" + Self.format(max(0, duration - position)))
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(EZColor.notchTertiary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Agenda

struct AgendaSection: View {
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.settings.modules.calendar || state.settings.modules.googleCalendar {
                event
            }
            if state.settings.modules.reminders {
                reminders
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var event: some View {
        if state.calendarAccess == .granted || (state.settings.modules.googleCalendar && !state.events.isEmpty) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let event = state.nextEvent(now: context.date) {
                    EventBlock(event: event, now: context.date, actions: actions)
                } else {
                    QuietLine(symbol: "calendar", text: "Rien de prévu", actionTitle: nil, action: nil)
                }
            }
        } else if state.calendarAccess == .notDetermined {
            QuietLine(symbol: "calendar", text: "Calendrier", actionTitle: "Autoriser") { actions.requestCalendarAccess() }
        } else {
            QuietLine(symbol: "calendar", text: "Accès Calendrier refusé", actionTitle: nil, action: nil)
        }
    }

    @ViewBuilder
    private var reminders: some View {
        switch state.remindersAccess {
        case .granted:
            let all = state.reminders.overdue + state.reminders.today
            if all.isEmpty {
                QuietLine(symbol: "checkmark.circle", text: "Aucun rappel aujourd’hui", actionTitle: nil, action: nil)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(all.prefix(2)) { reminder in
                        ReminderLine(reminder: reminder, overdue: state.reminders.overdue.contains(reminder), actions: actions)
                    }
                    if all.count > 2 {
                        Button("+ \(all.count - 2) autre\(all.count - 2 > 1 ? "s" : "")") { actions.openReminders() }
                            .buttonStyle(.plain)
                            .font(EZFont.caption)
                            .foregroundStyle(EZColor.notchTertiary)
                            .padding(.leading, 19)
                    }
                }
            }
        case .notDetermined:
            QuietLine(symbol: "checklist", text: "Rappels", actionTitle: "Autoriser") { actions.requestRemindersAccess() }
        default:
            QuietLine(symbol: "checklist", text: "Accès Rappels refusé", actionTitle: nil, action: nil)
        }
    }
}

private struct EventBlock: View {
    let event: CalendarEvent
    let now: Date
    let actions: EspazioActions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                actions.openEvent(event)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.isAllDay ? "Journée" : event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(hovering ? EZColor.notchPrimary : EZColor.notchPrimary.opacity(0.92))
                    Text(CountdownFormatter.string(until: event.start, end: event.end, now: now))
                        .font(EZFont.caption)
                        .foregroundStyle(EZColor.notchTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Ouvrir dans Calendrier")
            if let url = event.meetingURL {
                Button {
                    actions.joinMeeting(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rejoindre la réunion")
                .help("Rejoindre la réunion")
            }
        }
    }
}

private struct ReminderLine: View {
    let reminder: ReminderItem
    let overdue: Bool
    let actions: EspazioActions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                actions.completeReminder(id: reminder.id)
            } label: {
                Image(systemName: hovering ? "checkmark.circle" : "circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(EZColor.notchSecondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("Terminer \(reminder.title)")
            Text(reminder.title)
                .font(EZFont.body)
                .lineLimit(1)
            if overdue {
                Text("en retard").font(.system(size: 10, weight: .semibold)).foregroundStyle(EZColor.notchTertiary)
            }
        }
    }
}

/// Single discreet line used for empty / permission states instead of a big placeholder.
struct QuietLine: View {
    let symbol: String
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text).font(EZFont.body).lineLimit(1)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(EZFont.captionEmphasis)
                    .foregroundStyle(EZColor.notchPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .foregroundStyle(EZColor.notchTertiary)
    }
}
