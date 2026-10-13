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

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
