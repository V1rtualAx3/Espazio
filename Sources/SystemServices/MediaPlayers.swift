import AppKit
import EspazioCore
import ImageIO

/// How a scriptable player is observed and driven. Only documented mechanisms are used: the
/// player's distributed notification (event-driven) and its AppleScript dictionary (Apple
/// Events). Scripts run only while the player is running, so Espazio never launches it.
public struct PlayerDefinition: Sendable {
    public enum Artwork: Sendable {
        /// Script returning an https URL.
        case urlScript(String)
        /// Script returning raw image data.
        case dataScript(String)
    }

    public let id: String
    public let displayName: String
    public let bundleID: String
    /// Name used in `tell application "…"`.
    public let scriptName: String
    public let notification: String
    /// Notification user-info key holding a stable track identifier.
    public let trackIDKey: String
    /// Notification key for the duration, in milliseconds.
    public let durationKey: String
    /// Notification key for the position in seconds, when the player sends it.
    public let positionKey: String?
    /// The state script reports the duration in milliseconds (Spotify) or seconds (Music).
    public let scriptDurationInMilliseconds: Bool
    public let artwork: Artwork

    public static let spotify = PlayerDefinition(
        id: "spotify", displayName: "Spotify", bundleID: "com.spotify.client", scriptName: "Spotify",
        notification: "com.spotify.client.PlaybackStateChanged", trackIDKey: "Track ID", durationKey: "Duration",
        positionKey: "Playback Position", scriptDurationInMilliseconds: true,
        artwork: .urlScript("tell application \"Spotify\" to return artwork url of current track"))

    public static let appleMusic = PlayerDefinition(
        id: "music", displayName: "Musique", bundleID: "com.apple.Music", scriptName: "Music",
        notification: "com.apple.Music.playerInfo", trackIDKey: "PersistentID", durationKey: "Total Time",
        positionKey: nil, scriptDurationInMilliseconds: false,
        artwork: .dataScript("tell application \"Music\" to return raw data of artwork 1 of current track"))

    var stateScript: String {
        let idProperty = id == "spotify" ? "id" : "persistent ID"
        return """
            tell application "\(scriptName)"
                set s to player state as string
                set t to current track
                return s & "\\n" & (\(idProperty) of t) & "\\n" & (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & (duration of t) & "\\n" & (player position as string)
            end tell
            """
    }

    var positionScript: String { "tell application \"\(scriptName)\" to return player position as string" }
}

/// One scriptable player.
@MainActor
public final class PlayerProvider {
    public let definition: PlayerDefinition
    public var onChange: ((PlayerProvider) -> Void)?
    public var onArtwork: ((PlayerProvider) -> Void)?
    public private(set) var nowPlaying: NowPlaying?
    public private(set) var artwork: NSImage?
    public private(set) var lastPlayingDate = Date.distantPast
    public private(set) var artworkCacheCount = 0

    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var artworkCache = BoundedCache<String, NSImage>(countLimit: 12, costLimit: 2_000_000)
    private var artworkTask: Task<Void, Never>?
    private var currentArtworkTrack: String?

    public init(definition: PlayerDefinition) {
        self.definition = definition
    }

    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: definition.bundleID).isEmpty
    }

    public func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(definition.notification), object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo.map(PlayerProvider.sendableInfo) ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        let bundleID = definition.bundleID
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let terminated = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if terminated == bundleID { self?.update(nil) }
            }
        }
        if isRunning { refreshFromScript() }
    }

    public func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        observer = nil
        terminationObserver = nil
        artworkTask?.cancel()
        artworkCache.removeAll()
        artworkCacheCount = 0
        nowPlaying = nil
        artwork = nil
    }

    // MARK: - Controls

    public func playPause() { run("tell application \"\(definition.scriptName)\" to playpause") }
    public func next() { run("tell application \"\(definition.scriptName)\" to next track") }
    public func previous() { run("tell application \"\(definition.scriptName)\" to previous track") }

    public func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: definition.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: definition.bundleID) != nil }

    // MARK: - Private

    nonisolated static func sendableInfo(_ info: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in info {
            guard let key = key as? String else { continue }
            if let string = value as? String {
                result[key] = string
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    private func handle(_ info: [String: String]) {
        let state: PlaybackState
        switch info["Player State"] {
        case "Playing": state = .playing
        case "Paused": state = .paused
        default: state = .stopped
        }
        guard state != .stopped, let title = info["Name"] else {
            update(nil)
            return
        }
        let trackID = info[definition.trackIDKey] ?? "\(title)|\(info["Artist"] ?? "")"
        let duration = info[definition.durationKey].flatMap(Double.init).map { $0 / 1000 }
        var rawPosition = definition.positionKey.flatMap { info[$0] }.flatMap(Double.init)
        if rawPosition == nil, isRunning, let text = runReturningString(definition.positionScript) {
            // Music does not send the position: one Apple Event on each state change, no polling.
            rawPosition = Double(text.replacingOccurrences(of: ",", with: "."))
        }
        update(NowPlaying(
            trackID: trackID, title: title, artist: info["Artist"] ?? "", album: info["Album"], state: state,
            duration: duration, position: NowPlaying.normalizedPosition(rawPosition, duration: duration), positionDate: Date()))
    }

    private func update(_ playing: NowPlaying?) {
        nowPlaying = playing
        if playing?.state == .playing { lastPlayingDate = Date() }
        if let playing {
            if playing.trackID != currentArtworkTrack {
                currentArtworkTrack = playing.trackID
                loadArtwork(for: playing.trackID)
            }
        } else {
            currentArtworkTrack = nil
            artwork = nil
            onArtwork?(self)
        }
        onChange?(self)
    }

    /// Initial state when the player is already running at launch.
    private func refreshFromScript() {
        guard let output = runReturningString(definition.stateScript) else { return }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 7 else { return }
        let state = parts[0] == "playing" ? "Playing" : (parts[0] == "paused" ? "Paused" : "Stopped")
        let rawDuration = Double(parts[5].replacingOccurrences(of: ",", with: "."))
        let durationMS = rawDuration.map { definition.scriptDurationInMilliseconds ? $0 : $0 * 1000 }
        var info = [
            "Player State": state, definition.trackIDKey: parts[1], "Name": parts[2], "Artist": parts[3], "Album": parts[4],
        ]
        if let durationMS { info[definition.durationKey] = String(durationMS) }
        if let positionKey = definition.positionKey { info[positionKey] = parts[6].replacingOccurrences(of: ",", with: ".") }
        handle(info)
    }

    private func loadArtwork(for trackID: String) {
        artworkTask?.cancel()
        if let cached = artworkCache.value(for: trackID) {
            artwork = cached
            onArtwork?(self)
            return
        }
        artwork = nil
        onArtwork?(self)
        guard isRunning else { return }
        switch definition.artwork {
        case let .urlScript(script):
            guard let text = runReturningString(script),
                let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https"
            else { return }
            artworkTask = Task { [weak self] in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                    (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000
                else { return }
                self?.storeArtwork(data, trackID: trackID)
            }
        case let .dataScript(script):
            guard let data = runReturningDescriptor(script)?.data, data.count < 8_000_000 else { return }
            storeArtwork(data, trackID: trackID)
        }
    }

    private func storeArtwork(_ data: Data, trackID: String) {
        guard !Task.isCancelled, let image = Self.thumbnail(from: data, maxPixel: 128) else { return }
        artworkCache.insert(image, for: trackID, cost: 128 * 128 * 4)
        artworkCacheCount = artworkCache.count
        guard currentArtworkTrack == trackID else { return }
        artwork = image
        onArtwork?(self)
    }

    /// Decodes a small thumbnail directly (never keeps a full-size image in memory).
    nonisolated static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    private func run(_ source: String) {
        guard isRunning else { return }
        _ = runReturningDescriptor(source)
    }

    private func runReturningString(_ source: String) -> String? {
        runReturningDescriptor(source)?.stringValue
    }

    private func runReturningDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

/// Follows every enabled player and exposes the one that matters: the most recently playing,
/// otherwise the most recently paused.
@MainActor
public final class MediaHub {
    public var onChange: ((NowPlaying?, String) -> Void)?
    public var onArtwork: ((NSImage?) -> Void)?
    public private(set) var players: [PlayerProvider] = []
    private var active: PlayerProvider?

    public init() {}

    public func configure(spotify: Bool, appleMusic: Bool) {
        let wanted: [PlayerDefinition] = (spotify ? [.spotify] : []) + (appleMusic ? [.appleMusic] : [])
        for player in players where !wanted.contains(where: { $0.id == player.definition.id }) { player.stop() }
        players = wanted.map { definition in
            if let existing = players.first(where: { $0.definition.id == definition.id }) { return existing }
            let player = PlayerProvider(definition: definition)
            player.onChange = { [weak self] _ in self?.reselect() }
            player.onArtwork = { [weak self] provider in
                if provider === self?.active { self?.onArtwork?(provider.artwork) }
            }
            player.start()
            return player
        }
        reselect()
    }

    public func stopAll() {
        players.forEach { $0.stop() }
        players = []
        reselect()
    }

    public var activeName: String { active?.definition.displayName ?? players.first(where: \.isInstalled)?.definition.displayName ?? "Spotify" }
    public var isAnyRunning: Bool { players.contains(where: \.isRunning) }
    public var artworkCacheCount: Int { players.reduce(0) { $0 + $1.artworkCacheCount } }

    public func playPause() { active?.playPause() }
    public func next() { active?.next() }
    public func previous() { active?.previous() }

    public func openApp() {
        (active ?? players.first(where: \.isInstalled) ?? players.first)?.openApp()
    }

    private func reselect() {
        let candidates = players.filter { $0.nowPlaying != nil }
        let playing = candidates.filter { $0.nowPlaying?.state == .playing }.max { $0.lastPlayingDate < $1.lastPlayingDate }
        let selected = playing ?? (active.flatMap { current in candidates.first { $0 === current } }) ?? candidates.first
        let changedPlayer = selected !== active
        active = selected
        onChange?(selected?.nowPlaying, activeName)
        if changedPlayer { onArtwork?(selected?.artwork) }
    }
}
