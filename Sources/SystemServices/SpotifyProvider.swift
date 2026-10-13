import AppKit
import EspazioCore
import ImageIO

/// Spotify integration using documented, public mechanisms only:
/// - `com.spotify.client.PlaybackStateChanged` distributed notifications (event-driven);
/// - AppleScript (Spotify's scripting dictionary) for controls and artwork URL, only while
///   Spotify is running so Espazio never launches it implicitly.
/// No private MediaRemote API is used.
@MainActor
public final class SpotifyProvider {
    public nonisolated static let bundleID = "com.spotify.client"

    public var onChange: ((NowPlaying?) -> Void)?
    public var onArtwork: ((NSImage?) -> Void)?
    public private(set) var nowPlaying: NowPlaying?
    public private(set) var artworkCacheCount = 0

    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var artworkCache = BoundedCache<String, NSImage>(countLimit: 12, costLimit: 2_000_000)
    private var artworkTask: Task<Void, Never>?
    private var currentArtworkTrack: String?

    public init() {}

    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    public func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo.map(Self.sendableInfo) ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if bundleID == Self.bundleID { self?.update(nil) }
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
    }

    // MARK: - Controls

    public func playPause() { run("tell application \"Spotify\" to playpause") }
    public func next() { run("tell application \"Spotify\" to next track") }
    public func previous() { run("tell application \"Spotify\" to previous track") }

    public func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Private

    private nonisolated static func sendableInfo(_ info: [AnyHashable: Any]) -> [String: String] {
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
        guard state != .stopped, let trackID = info["Track ID"], let title = info["Name"] else {
            update(nil)
            return
        }
        let durationMS = info["Duration"].flatMap(Double.init)
        let position = info["Playback Position"].flatMap(Double.init)
        let playing = NowPlaying(
            trackID: trackID, title: title, artist: info["Artist"] ?? "", album: info["Album"], state: state,
            duration: durationMS.map { $0 / 1000 }, position: position, positionDate: Date())
        update(playing)
    }

    private func update(_ playing: NowPlaying?) {
        nowPlaying = playing
        onChange?(playing)
        guard let playing else {
            currentArtworkTrack = nil
            onArtwork?(nil)
            return
        }
        if playing.trackID != currentArtworkTrack {
            currentArtworkTrack = playing.trackID
            loadArtwork(for: playing.trackID)
        }
    }

    /// Initial state when Spotify is already running at launch.
    private func refreshFromScript() {
        let script = """
            tell application "Spotify"
                set s to player state as string
                set t to current track
                return s & "\\n" & (id of t) & "\\n" & (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & (duration of t) & "\\n" & (player position as string)
            end tell
            """
        guard let output = runReturningString(script) else { return }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 7 else { return }
        let state = parts[0] == "playing" ? "Playing" : (parts[0] == "paused" ? "Paused" : "Stopped")
        handle([
            "Player State": state, "Track ID": parts[1], "Name": parts[2], "Artist": parts[3], "Album": parts[4],
            "Duration": parts[5], "Playback Position": parts[6].replacingOccurrences(of: ",", with: "."),
        ])
    }

    private func loadArtwork(for trackID: String) {
        artworkTask?.cancel()
        if let cached = artworkCache.value(for: trackID) {
            onArtwork?(cached)
            return
        }
        onArtwork?(nil)
        guard isRunning,
            let urlString = runReturningString("tell application \"Spotify\" to return artwork url of current track"),
            let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https"
        else { return }
        artworkTask = Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                let image = Self.thumbnail(from: data, maxPixel: 96)
            else { return }
            guard !Task.isCancelled, let self else { return }
            let cost = 96 * 96 * 4
            self.artworkCache.insert(image, for: trackID, cost: cost)
            self.artworkCacheCount = self.artworkCache.count
            if self.currentArtworkTrack == trackID { self.onArtwork?(image) }
        }
    }

    /// Decodes a small thumbnail directly (never keeps the full-size 640 px image in memory).
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
        _ = runReturningString(source)
    }

    private func runReturningString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}
