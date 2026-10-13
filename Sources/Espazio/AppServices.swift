import AppKit
import ServiceManagement
import Sparkle

/// Login item through `SMAppService` (macOS 13+). The system may require approval in
/// System Settings › General › Login Items; the status is always read back from the system.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns a user-facing message when the change did not take effect.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return enabled
                ? "Impossible d’ajouter Espazio aux éléments de connexion (installez l’app dans /Applications)."
                : "Impossible de retirer Espazio des éléments de connexion."
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Autorisez Espazio dans Réglages Système › Général › Ouverture."
        }
        return nil
    }
}

/// Sparkle updater. Started only when the build carries an EdDSA public key and a feed URL, so
/// development and ad-hoc builds never contact the network for updates.
@MainActor
final class UpdateController {
    private var controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (info["SUFeedURL"] as? String) ?? ""
        guard !key.isEmpty, URL(string: feed)?.scheme == "https" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isConfigured: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}
