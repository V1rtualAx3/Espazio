import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds the application hosting an agent process (Claude desktop, Terminal, VS Code…) so a click
/// on its session brings that application to front. Environment variables are not enough: Claude
/// desktop sets neither `TERM_PROGRAM` nor `__CFBundleIdentifier` for the processes it launches.
public enum HostApplication {
    /// Hint key carrying the host application's bundle path.
    public static let hintKey = "hostAppPath"

    /// Outermost `.app` bundle containing `executablePath`, e.g.
    /// `/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper`
    /// → `/Applications/Claude.app`. `nil` when the executable is not inside an application bundle.
    public static func bundlePath(containing executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        // The last component is the executable itself, never the bundle.
        guard let index = components.dropLast().firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    /// First application bundle among the executables of a process and its ancestors, nearest first.
    public static func bundlePath(inAncestry executablePaths: [String]) -> String? {
        for path in executablePaths {
            if let bundle = bundlePath(containing: path) { return bundle }
        }
        return nil
    }

    #if canImport(Darwin)
    /// Executable paths of the current process's ancestors, parent first (at most `limit`).
    public static func ancestorExecutablePaths(limit: Int = 12) -> [String] {
        var paths: [String] = []
        var pid = getppid()
        while pid > 1, paths.count < limit {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                paths.append(String(decoding: bytes, as: UTF8.self))
            }
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
        }
        return paths
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
    #endif
}
