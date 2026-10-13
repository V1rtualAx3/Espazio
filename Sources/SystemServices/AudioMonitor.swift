import CoreAudio
import AudioToolbox
import EspazioCore
import Foundation

/// Observes the default output device, its volume and mute state through CoreAudio property
/// listeners (event-driven, no polling). Emits only user-visible changes.
@MainActor
public final class AudioMonitor {
    public var onEvent: ((SystemEvent) -> Void)?

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceName: String?
    private var lastVolume: Double?
    private var lastMuted: Bool?
    private var started = false
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultDeviceListener = listener
        bind(to: Self.defaultOutputDevice(), announce: false)
    }

    public func stop() {
        guard started else { return }
        started = false
        if let listener = defaultDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        defaultDeviceListener = nil
        unbindDevice()
    }

    public var currentDeviceName: String? { deviceName }

    // MARK: - Private

    private func defaultDeviceChanged() {
        bind(to: Self.defaultOutputDevice(), announce: true)
    }

    private func bind(to device: AudioObjectID, announce: Bool) {
        guard device != kAudioObjectUnknown, device != deviceID else { return }
        unbindDevice()
        deviceID = device
        let name = Self.name(of: device)
        let previousName = deviceName
        deviceName = name
        lastVolume = Self.volume(of: device)
        lastMuted = Self.isMuted(device)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volumeChanged() }
        }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(device, &address) {
                AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
            }
        }
        volumeListener = listener
        if announce, let name, name != previousName {
            onEvent?(.outputDeviceChanged(name: name))
        }
    }

    private func unbindDevice() {
        guard deviceID != kAudioObjectUnknown, let listener = volumeListener else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(deviceID, &address) {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, listener)
            }
        }
        volumeListener = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func volumeChanged() {
        let volume = Self.volume(of: deviceID)
        let muted = Self.isMuted(deviceID) ?? false
        defer {
            lastVolume = volume
            lastMuted = muted
        }
        guard let volume else { return }
        // Ignore notifications that do not change the displayed value (e.g. balance changes).
        if let lastVolume, abs(lastVolume - volume) < 0.005, lastMuted == muted { return }
        onEvent?(.volume(level: volume, muted: muted, device: deviceName))
    }

    // MARK: - CoreAudio helpers

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func name(of device: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func volume(of device: AudioObjectID) -> Double? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? Double(volume) : nil
    }

    static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr ? muted != 0 : nil
    }
}
