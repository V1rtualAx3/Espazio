import Foundation

public enum PlaybackState: String, Sendable, Codable {
    case playing
    case paused
    case stopped
}

/// Now-playing information. Position is extrapolated from the last report so the UI never
/// polls the player (spec §3.2).
public struct NowPlaying: Sendable, Equatable, Codable {
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String?
    public var artworkURL: URL?
    public var state: PlaybackState
    /// Duration in seconds, when known.
    public var duration: TimeInterval?
    /// Position at `positionDate`, when known.
    public var position: TimeInterval?
    public var positionDate: Date

    public init(
        trackID: String, title: String, artist: String, album: String? = nil, artworkURL: URL? = nil,
        state: PlaybackState, duration: TimeInterval? = nil, position: TimeInterval? = nil, positionDate: Date
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.state = state
        self.duration = duration
        self.position = position
        self.positionDate = positionDate
    }

    /// Players report the position in seconds, but some versions / scripting paths return
    /// milliseconds; a value still past the end is dropped rather than shown as finished.
    public static func normalizedPosition(_ raw: Double?, duration: Double?) -> Double? {
        guard let raw, raw >= 0 else { return nil }
        guard let duration, duration > 0 else { return raw }
        if raw <= duration + 1 { return raw }
        let seconds = raw / 1000
        return seconds <= duration + 1 ? seconds : nil
    }

    public func position(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        var value = position
        if state == .playing { value += max(0, date.timeIntervalSince(positionDate)) }
        if let duration { value = min(value, duration) }
        return value
    }

    public func progress(at date: Date) -> Double? {
        guard let duration, duration > 0, let current = position(at: date) else { return nil }
        return min(max(current / duration, 0), 1)
    }
}

/// Availability of an observable value: Espazio never invents a state (spec §3.3).
public enum Observed<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case unavailable(reason: String)

    public var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }
}

public struct PowerStatus: Sendable, Equatable {
    /// 0...1
    public var level: Double
    public var isCharging: Bool
    public var isOnExternalPower: Bool
    public var hasBattery: Bool

    public init(level: Double, isCharging: Bool, isOnExternalPower: Bool, hasBattery: Bool) {
        self.level = level
        self.isCharging = isCharging
        self.isOnExternalPower = isOnExternalPower
        self.hasBattery = hasBattery
    }
}

/// Discrete hardware / system events turned into activities.
public enum SystemEvent: Sendable, Equatable {
    case volume(level: Double, muted: Bool, device: String?)
    case outputDeviceChanged(name: String)
    case power(PowerStatus, previous: PowerStatus?)
    case capsLock(isOn: Bool)
    case bluetooth(deviceName: String, connected: Bool)
}

public enum SystemEventMapper {
    public static let lowBatteryThreshold = 0.2
    public static let criticalBatteryThreshold = 0.1

    /// Converts a system event into a notch activity, or `nil` when it is not worth showing.
    /// The peek shows the symbol on one wing and the subtitle on the other (about 80 pt): the
    /// subtitle holds the short value only; the title completes it for VoiceOver.
    public static func activity(for event: SystemEvent, now: Date) -> ActivityItem? {
        switch event {
        case let .volume(level, muted, device):
            let clamped = min(max(level, 0), 1)
            let symbol: String
            if muted || clamped == 0 {
                symbol = "speaker.slash.fill"
            } else if clamped < 0.34 {
                symbol = "speaker.wave.1.fill"
            } else if clamped < 0.67 {
                symbol = "speaker.wave.2.fill"
            } else {
                symbol = "speaker.wave.3.fill"
            }
            return ActivityItem(
                source: .volume, priority: .p3, coalescingKey: "volume", title: muted ? "Muet" : "Volume",
                subtitle: device, symbol: symbol, progress: muted ? 0 : clamped, createdAt: now,
                expiresAt: now.addingTimeInterval(1.6))
        case let .outputDeviceChanged(name):
            return ActivityItem(
                source: .audioDevice, priority: .p3, coalescingKey: "audio-device", title: "Sortie audio",
                subtitle: name, symbol: symbolForAudioDevice(name), createdAt: now,
                expiresAt: now.addingTimeInterval(2.5))
        case let .power(status, previous):
            guard status.hasBattery else { return nil }
            if let previous, previous.isOnExternalPower != status.isOnExternalPower {
                return ActivityItem(
                    source: .power, priority: .p3, coalescingKey: "power",
                    title: status.isOnExternalPower ? "Alimentation connectée" : "Sur batterie",
                    subtitle: "\(Int((status.level * 100).rounded())) %",
                    symbol: status.isOnExternalPower ? "battery.100.bolt" : "battery.75",
                    progress: status.level, createdAt: now, expiresAt: now.addingTimeInterval(2.5))
            }
            guard !status.isOnExternalPower else { return nil }
            let crossed: (Double) -> Bool = { threshold in
                status.level <= threshold && (previous.map { $0.level > threshold } ?? true)
            }
            if crossed(criticalBatteryThreshold) {
                return ActivityItem(
                    source: .battery, priority: .p1, coalescingKey: "battery", title: "Batterie critique",
                    subtitle: "\(Int((status.level * 100).rounded())) %", symbol: "battery.0", progress: status.level,
                    createdAt: now, expiresAt: now.addingTimeInterval(8))
            }
            if crossed(lowBatteryThreshold) {
                return ActivityItem(
                    source: .battery, priority: .p3, coalescingKey: "battery", title: "Batterie faible",
                    subtitle: "\(Int((status.level * 100).rounded())) %", symbol: "battery.25", progress: status.level,
                    createdAt: now, expiresAt: now.addingTimeInterval(4))
            }
            return nil
        case let .capsLock(isOn):
            return ActivityItem(
                source: .keyboard, priority: .p3, coalescingKey: "capslock",
                title: "Verrouillage majuscules", subtitle: isOn ? "Activé" : "Désactivé",
                symbol: isOn ? "capslock.fill" : "capslock",
                createdAt: now, expiresAt: now.addingTimeInterval(1.5))
        case let .bluetooth(name, connected):
            return ActivityItem(
                source: .bluetooth, priority: .p3, coalescingKey: "bt:\(name)", title: connected ? "Connecté" : "Déconnecté",
                subtitle: name, symbol: connected ? bluetoothSymbol(name) : "wifi.slash", createdAt: now,
                expiresAt: now.addingTimeInterval(2.5))
        }
    }

    static func bluetoothSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("headphone") || lower.contains("casque") { return symbolForAudioDevice(name) }
        if lower.contains("keyboard") || lower.contains("clavier") { return "keyboard" }
        if lower.contains("mouse") || lower.contains("souris") { return "computermouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "dot.radiowaves.left.and.right"
    }

    static func symbolForAudioDevice(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("headphone") || lower.contains("casque") { return "headphones" }
        if lower.contains("tv") || lower.contains("hdmi") || lower.contains("display") { return "tv" }
        return "hifispeaker.fill"
    }
}
