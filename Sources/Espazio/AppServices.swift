import AppKit
import os
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
    /// Held here: Sparkle keeps only a weak reference to its delegate.
    private let channels = UpdateChannels()

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (info["SUFeedURL"] as? String) ?? ""
        guard !key.isEmpty, URL(string: feed)?.scheme == "https" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: channels, userDriverDelegate: nil)
    }

    /// Beta versions are offered only when this is on; stable versions always are.
    var includesBetas: Bool {
        get { channels.includesBetas }
        set { channels.includesBetas = newValue }
    }

    var isConfigured: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Outcome of the last check, shown under « Rechercher maintenant » (the Sparkle windows can
    /// open behind other apps, and an error would otherwise go unnoticed).
    var onStatus: (@MainActor (String) -> Void)? {
        didSet {
            let report = onStatus
            channels.onStatus = { status in
                DispatchQueue.main.async { MainActor.assumeIsolated { report?(status) } }
            }
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        guard controller.updater.canCheckForUpdates else {
            onStatus?("Une vérification est déjà en cours.")
            return
        }
        onStatus?("Recherche en cours…")
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

/// Appcast channels: stable items carry no channel, betas the "beta" channel.
final class UpdateChannels: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var betas = false

    var includesBetas: Bool {
        get { lock.withLock { betas } }
        set { lock.withLock { betas = newValue } }
    }

    /// Called from Sparkle's callbacks with a user-facing status.
    var onStatus: (@Sendable (String) -> Void)? {
        get { lock.withLock { status } }
        set { lock.withLock { status = newValue } }
    }

    private var status: (@Sendable (String) -> Void)?
    private static let log = Logger(subsystem: "app.espazio", category: "updates")

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesBetas ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log.info("update found: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
        onStatus?("Version \(item.displayVersionString) disponible.")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Self.log.info("no update: \(error.localizedDescription, privacy: .public)")
        onStatus?("Espazio est à jour (\(Self.checkedAt())).")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        // Sparkle ends a check that finds nothing newer with this "error" (SUNoUpdateError).
        if error.domain == "SUSparkleErrorDomain", error.code == 1001 {
            Self.log.info("no update")
            onStatus?("Espazio est à jour (\(Self.checkedAt())).")
            return
        }
        Self.log.error("update aborted: \(String(describing: error), privacy: .public)")
        onStatus?("Échec de la mise à jour : \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Self.log.error("download failed: \(String(describing: error), privacy: .public)")
        onStatus?("Téléchargement impossible : \(error.localizedDescription)")
    }

    private static func checkedAt() -> String {
        Date().formatted(date: .omitted, time: .shortened)
    }
}
