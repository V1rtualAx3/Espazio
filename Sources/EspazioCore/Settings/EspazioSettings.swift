import Foundation

/// Keyboard shortcut stored as a virtual key code + Carbon-style modifier flags.
public struct KeyShortcut: Sendable, Codable, Equatable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        // Values match Carbon's cmdKey/shiftKey/optionKey/controlKey.
        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥Space
    public static let defaultQuickActions = KeyShortcut(keyCode: 49, modifiers: [.control, .option])
    /// ⌃⌥N
    public static let defaultToggleNotch = KeyShortcut(keyCode: 45, modifiers: [.control, .option])

    /// A shortcut needs at least one of ⌘ ⌥ ⌃ to avoid hijacking normal typing.
    public var isValid: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "#\(keyCode)")
    }

    /// ANSI virtual key codes (Carbon `kVK_*`) → printable names.
    public static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Espace", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Keys that can never be a global shortcut on their own (handled by the recorder).
    public static let reservedKeyCodes: Set<UInt32> = [53, 51]
}

/// Per-module switches (spec: "préférences par module").
public struct ModuleSettings: Sendable, Codable, Equatable {
    public var media = true
    /// Players followed when `media` is on.
    public var spotify = true
    public var appleMusic = true
    public var volume = true
    public var audioDevice = true
    public var battery = true
    public var keyboard = true
    /// Requires Bluetooth permission: opt-in.
    public var bluetooth = false
    public var calendar = true
    public var reminders = true
    public var gmail = false
    public var googleChat = false
    /// Direct Google Calendar API: only when the account is not synced in macOS Calendar.
    public var googleCalendar = false
    public var claudeCode = true
    public var codex = true
    public var chatGPT = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ModuleSettings()
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? d.media
        spotify = try c.decodeIfPresent(Bool.self, forKey: .spotify) ?? d.spotify
        appleMusic = try c.decodeIfPresent(Bool.self, forKey: .appleMusic) ?? d.appleMusic
        volume = try c.decodeIfPresent(Bool.self, forKey: .volume) ?? d.volume
        audioDevice = try c.decodeIfPresent(Bool.self, forKey: .audioDevice) ?? d.audioDevice
        battery = try c.decodeIfPresent(Bool.self, forKey: .battery) ?? d.battery
        keyboard = try c.decodeIfPresent(Bool.self, forKey: .keyboard) ?? d.keyboard
        bluetooth = try c.decodeIfPresent(Bool.self, forKey: .bluetooth) ?? d.bluetooth
        calendar = try c.decodeIfPresent(Bool.self, forKey: .calendar) ?? d.calendar
        reminders = try c.decodeIfPresent(Bool.self, forKey: .reminders) ?? d.reminders
        gmail = try c.decodeIfPresent(Bool.self, forKey: .gmail) ?? d.gmail
        googleChat = try c.decodeIfPresent(Bool.self, forKey: .googleChat) ?? d.googleChat
        googleCalendar = try c.decodeIfPresent(Bool.self, forKey: .googleCalendar) ?? d.googleCalendar
        claudeCode = try c.decodeIfPresent(Bool.self, forKey: .claudeCode) ?? d.claudeCode
        codex = try c.decodeIfPresent(Bool.self, forKey: .codex) ?? d.codex
        chatGPT = try c.decodeIfPresent(Bool.self, forKey: .chatGPT) ?? d.chatGPT
    }

    /// Activity sources that must not be queued at all.
    public var mutedSources: Set<ActivitySource> {
        var muted: Set<ActivitySource> = []
        if !media { muted.insert(.media) }
        if !volume { muted.insert(.volume) }
        if !audioDevice { muted.insert(.audioDevice) }
        if !battery { muted.formUnion([.battery, .power]) }
        if !keyboard { muted.insert(.keyboard) }
        if !bluetooth { muted.insert(.bluetooth) }
        if !calendar && !googleCalendar { muted.insert(.calendar) }
        if !reminders { muted.insert(.reminders) }
        if !gmail { muted.insert(.mail) }
        if !googleChat { muted.insert(.chat) }
        return muted
    }
}

/// All user preferences. Decoding is tolerant: unknown keys are ignored and missing keys take
/// default values, so older/newer settings files never crash the app.
public struct EspazioSettings: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public var version = EspazioSettings.currentVersion
    public var displayMode: DisplayMode = .mainOnly
    public var hideInFullScreen = false
    public var expandOnHover = true
    /// Seconds the pointer must rest on the notch before expanding.
    public var hoverDelay: Double = 0.2
    public var focusMode: FocusMode = .normal
    /// Context-aware focus: reduce interruptions during meetings / full screen.
    public var contextualFocus = true
    public var modules = ModuleSettings()
    /// Information kept visible in the notch at rest.
    public var live = LiveActivitySettings()
    /// Gmail / Chat sync interval in seconds (clamped to 60...3600).
    public var googleSyncInterval: Double = 180
    /// Seconds before an unanswered agent request is denied (clamped to 15...600).
    public var agentRequestTimeout: Double = 300
    public var quickActionsShortcut: KeyShortcut = .defaultQuickActions
    public var toggleNotchShortcut: KeyShortcut = .defaultToggleNotch
    public var diagnosticsEnabled = false
    /// Google OAuth client identifier supplied by the user (not a secret).
    public var googleClientID: String = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EspazioSettings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        displayMode = (try? c.decodeIfPresent(DisplayMode.self, forKey: .displayMode)) ?? d.displayMode
        hideInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen) ?? d.hideInFullScreen
        expandOnHover = try c.decodeIfPresent(Bool.self, forKey: .expandOnHover) ?? d.expandOnHover
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? d.hoverDelay
        focusMode = (try? c.decodeIfPresent(FocusMode.self, forKey: .focusMode)) ?? d.focusMode
        contextualFocus = try c.decodeIfPresent(Bool.self, forKey: .contextualFocus) ?? d.contextualFocus
        modules = (try? c.decodeIfPresent(ModuleSettings.self, forKey: .modules)) ?? d.modules
        live = (try? c.decodeIfPresent(LiveActivitySettings.self, forKey: .live)) ?? d.live
        googleSyncInterval = try c.decodeIfPresent(Double.self, forKey: .googleSyncInterval) ?? d.googleSyncInterval
        agentRequestTimeout = try c.decodeIfPresent(Double.self, forKey: .agentRequestTimeout) ?? d.agentRequestTimeout
        quickActionsShortcut = (try? c.decodeIfPresent(KeyShortcut.self, forKey: .quickActionsShortcut)) ?? d.quickActionsShortcut
        toggleNotchShortcut = (try? c.decodeIfPresent(KeyShortcut.self, forKey: .toggleNotchShortcut)) ?? d.toggleNotchShortcut
        diagnosticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .diagnosticsEnabled) ?? d.diagnosticsEnabled
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? d.googleClientID
        normalize()
    }

    /// Clamps values to safe ranges.
    public mutating func normalize() {
        version = Self.currentVersion
        hoverDelay = min(max(hoverDelay, 0), 2)
        googleSyncInterval = min(max(googleSyncInterval, 60), 3600)
        agentRequestTimeout = min(max(agentRequestTimeout, 15), ApprovalCenter.maximumTimeout)
        if !quickActionsShortcut.isValid { quickActionsShortcut = .defaultQuickActions }
        if !toggleNotchShortcut.isValid { toggleNotchShortcut = .defaultToggleNotch }
        googleClientID = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func normalized() -> EspazioSettings {
        var copy = self
        copy.normalize()
        return copy
    }

    public static func decode(_ data: Data?) -> EspazioSettings {
        guard let data, let settings = try? JSONDecoder().decode(EspazioSettings.self, from: data) else {
            return EspazioSettings()
        }
        return settings
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(normalized())) ?? Data()
    }
}
