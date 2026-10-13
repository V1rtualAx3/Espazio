import AppKit
import EspazioCore
import SwiftUI

/// Intents of the first-launch welcome window.
@MainActor
public protocol WelcomeActions: AnyObject {
    func requestCalendarAccess()
    func requestRemindersAccess()
    func setClaudeHooksInstalled(_ installed: Bool)
    func openGoogleSettings()
    func finishWelcome()
}

/// Three skippable steps mirroring the README's "Premiers pas". Permissions are requested only
/// when the user presses the matching button.
public struct WelcomeView: View {
    let state: EspazioState
    let actions: WelcomeActions
    let icon: NSImage?
    @State private var step = 0

    private static let steps = 3

    public init(state: EspazioState, actions: WelcomeActions, icon: NSImage?) {
        self.state = state
        self.actions = actions
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                }
                Text("Bienvenue dans Espazio").font(.system(size: 22, weight: .semibold))
                Text("La notch de votre Mac, enfin utile. Trois réglages rapides — chacun peut attendre.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            StepIndicator(current: step, count: Self.steps)
            Group {
                switch step {
                case 0: modulesStep
                case 1: agentsStep
                default: googleStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
            .transition(.opacity)
            HStack {
                if step > 0 {
                    Button("Retour") { withAnimation { step -= 1 } }
                }
                Spacer()
                Button(step < Self.steps - 1 ? "Passer" : "Plus tard") { advance() }
                    .keyboardShortcut(.cancelAction)
                Button(step < Self.steps - 1 ? "Continuer" : "Terminer") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func advance() {
        if step < Self.steps - 1 {
            withAnimation { step += 1 }
        } else {
            actions.finishWelcome()
        }
    }

    // MARK: - Steps

    private var modulesStep: some View {
        StepCard(symbol: "calendar", title: "Calendrier et Rappels",
                 text: "Prochain rendez-vous, lien de réunion, rappels du jour. macOS vous demandera l’accès séparément pour chacun.") {
            AccessButton(title: "Calendrier", access: state.calendarAccess) { actions.requestCalendarAccess() }
            AccessButton(title: "Rappels", access: state.remindersAccess) { actions.requestRemindersAccess() }
        }
    }

    private var agentsStep: some View {
        StepCard(symbol: "sparkles", title: "Agents IA",
                 text: "Recevez les demandes d’autorisation de Claude Code dans la notch : « Refuser » ou « Autoriser une fois ». Votre configuration ~/.claude/settings.json est sauvegardée avant toute modification.") {
            Toggle("Installer les hooks Claude Code", isOn: Binding(
                get: { state.claudeHooksInstalled }, set: { actions.setClaudeHooksInstalled($0) }))
                .toggleStyle(.switch)
        }
    }

    private var googleStep: some View {
        StepCard(symbol: "envelope", title: "Google",
                 text: "Gmail, Google Chat et Agenda nécessitent votre propre client OAuth (aucune clé n’est intégrée). Le guide est dans docs/GOOGLE_OAUTH.md.") {
            Button("Ouvrir les réglages Google") { actions.openGoogleSettings() }
        }
    }
}

private struct StepIndicator: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Étape \(current + 1) sur \(count)")
    }
}

private struct StepCard<Controls: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { controls }.padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct AccessButton: View {
    let title: String
    let access: AccessState
    let request: () -> Void

    var body: some View {
        switch access {
        case .granted:
            Label("\(title) autorisé", systemImage: "checkmark").foregroundStyle(.secondary)
        case .notDetermined:
            Button("Autoriser \(title)", action: request)
        case .denied, .restricted:
            Label("\(title) refusé (Réglages Système)", systemImage: "xmark").foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class NoopWelcomeActions: WelcomeActions {
    func requestCalendarAccess() {}
    func requestRemindersAccess() {}
    func setClaudeHooksInstalled(_ installed: Bool) {}
    func openGoogleSettings() {}
    func finishWelcome() {}
}

struct WelcomePreviews: PreviewProvider {
    static var previews: some View {
        let state = PreviewData.state()
        state.calendarAccess = .notDetermined
        state.remindersAccess = .granted
        return WelcomeView(state: state, actions: NoopWelcomeActions(), icon: NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: nil))
    }
}
