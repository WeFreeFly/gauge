import Foundation
import Darwin

public struct ProcessUsage: Identifiable, Sendable, Hashable {
    public let id: pid_t
    public let name: String
    public let path: String
    /// Fraction of a single core, so a process using two cores reports 2.0.
    public let cpu: Double
    public let memory: Double        // resident bytes
    public let threads: Int
    public let diskRead: Double      // bytes/sec
    public let diskWrite: Double     // bytes/sec
}

/// Samples per-process CPU and memory through libproc.
///
/// CPU time is cumulative per process, so a percentage only exists relative to
/// the previous sample; the first call after launch reports zero.
public final class ProcessMonitor: @unchecked Sendable {
    private struct Previous {
        var cpuSeconds: Double
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private var previous: [pid_t: Previous] = [:]
    private var previousTimestamp: Date?
    private var nameCache: [pid_t: (name: String, path: String)] = [:]

    public init() {}

    public struct Sample: Sendable {
        public var byCPU: [ProcessUsage] = []
        public var byMemory: [ProcessUsage] = []
        public var processCount = 0
        public var threadCount = 0
    }

    public func sample(limit: Int = 8) -> Sample {
        let now = Date()
        let elapsed = previousTimestamp.map { now.timeIntervalSince($0) } ?? 0
        defer { previousTimestamp = now }

        guard let pids = Self.allPIDs() else { return Sample() }

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(pids.count)
        var totalThreads = 0
        var current: [pid_t: Previous] = [:]
        current.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let resource = Self.resourceUsage(pid) else { continue }

            let cpuSeconds = Double(resource.ri_user_time + resource.ri_system_time) / 1_000_000_000
            let snapshot = Previous(cpuSeconds: cpuSeconds,
                                    diskRead: resource.ri_diskio_bytesread,
                                    diskWrite: resource.ri_diskio_byteswritten)
            current[pid] = snapshot

            var cpu = 0.0
            var readRate = 0.0
            var writeRate = 0.0
            if elapsed > 0, let last = previous[pid] {
                cpu = max(0, cpuSeconds - last.cpuSeconds).safeDivided(by: elapsed)
                readRate = Double(snapshot.diskRead &- last.diskRead).safeDivided(by: elapsed)
                writeRate = Double(snapshot.diskWrite &- last.diskWrite).safeDivided(by: elapsed)
            }

            var threads = 0
            var taskInfo = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo,
                            Int32(MemoryLayout<proc_taskinfo>.stride)) == Int32(MemoryLayout<proc_taskinfo>.stride) {
                threads = Int(taskInfo.pti_threadnum)
                totalThreads += threads
            }

            let identity = identity(for: pid)
            usages.append(ProcessUsage(
                id: pid,
                name: identity.name,
                path: identity.path,
                cpu: cpu,
                // Phys footprint is what Activity Monitor's "Memory" column shows.
                memory: Double(resource.ri_phys_footprint),
                threads: threads,
                diskRead: readRate,
                diskWrite: writeRate
            ))
        }

        previous = current
        // Drop cached names for processes that have exited.
        if nameCache.count > pids.count * 2 {
            nameCache = nameCache.filter { current[$0.key] != nil }
        }

        return Sample(
            byCPU: Array(usages.sorted { $0.cpu > $1.cpu }.prefix(limit)),
            byMemory: Array(usages.sorted { $0.memory > $1.memory }.prefix(limit)),
            processCount: usages.count,
            threadCount: totalThreads
        )
    }

    // MARK: libproc plumbing

    private static func looksLikeVersion(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Directory names that describe layout rather than the program itself.
    private static let genericDirectories: Set<String> = [
        "versions", "version", "bin", "sbin", "libexec", "current", "releases",
        "Contents", "MacOS", "Resources", "Frameworks", "Helpers", "share", "lib",
    ]

    private static func meaningfulAncestor(of path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<4 {
            let component = url.lastPathComponent
            if component.isEmpty || component == "/" { return nil }
            if !genericDirectories.contains(component), !looksLikeVersion(component) {
                return component
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func allPIDs() -> [pid_t]? {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return nil }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.stride))
    }

    private static func resourceUsage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// Executable paths do not change, so resolve each pid once.
    private func identity(for pid: pid_t) -> (name: String, path: String) {
        if let cached = nameCache[pid] { return cached }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var path = ""
        if proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 {
            path = String(cString: buffer)
        }

        let executable = (path as NSString).lastPathComponent
        var name = executable
        // "/Applications/Foo.app/Contents/MacOS/Foo" reads better as "Foo".
        if let range = path.range(of: ".app/Contents/", options: .backwards) {
            let bundle = String(path[path.startIndex..<range.lowerBound])
            name = (bundle as NSString).lastPathComponent
        }
        // Some tools install their binary as the version number
        // (".../claude/versions/2.1.276"), which on its own says nothing about
        // what is running. Walk up to the first directory that names something.
        if Self.looksLikeVersion(name) {
            name = Self.meaningfulAncestor(of: path) ?? executable
        }
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &short, 256) > 0 { name = String(cString: short) }
        }
        if name.isEmpty { name = "pid \(pid)" }

        let identity = (name: name, path: path)
        nameCache[pid] = identity
        return identity
    }
}
