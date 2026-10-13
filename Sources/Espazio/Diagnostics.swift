import Darwin
import EspazioUI
import Foundation

/// On-demand measurements (no timer). `phys_footprint` is the value Activity Monitor reports
/// as "Memory".
enum Diagnostics {
    static func snapshot(
        launchDate: Date, notchWindows: Int, activityItems: Int, artworkCacheItems: Int, bridgeRunning: Bool, codexRunning: Bool
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            residentMemoryMB: footprintMB(), cpuTimeSeconds: cpuSeconds(), uptimeSeconds: Date().timeIntervalSince(launchDate),
            notchWindows: notchWindows, activityItems: activityItems, artworkCacheItems: artworkCacheItems,
            bridgeRunning: bridgeRunning, codexProcessRunning: codexRunning)
    }

    /// `ri_phys_footprint` from `proc_pid_rusage` (same value as Activity Monitor's "Memory").
    static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(info.ri_phys_footprint) / 1_048_576
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
