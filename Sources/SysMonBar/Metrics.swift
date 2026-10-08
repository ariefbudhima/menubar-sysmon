import AppKit
import Darwin
import Foundation

// MARK: - Health level

/// Colour shown by the menu bar indicator.
enum HealthLevel {
    case ok
    case warn
    case critical

    var title: String {
        switch self {
        case .ok: return "NORMAL"
        case .warn: return "WARNING"
        case .critical: return "CRITICAL"
        }
    }

    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

// MARK: - Memory

struct MemorySnapshot {
    var totalBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedFileBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    /// Raw `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    /// 0 means "could not be read".
    var pressureRaw: Int = 0
    /// `kern.memorystatus_level`: the kernel's own free-memory percentage (0...1).
    /// This is the number `memory_pressure` prints as "System-wide memory free
    /// percentage". 0 means "could not be read".
    var availableFraction: Double = 0
    /// Pages pushed out to swap per second over the last sampling window.
    var pageOutRate: Double = 0

    /// "Memory used" the way Activity Monitor means it: app + wired + compressed.
    var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }
    var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    var swapFraction: Double { swapTotalBytes == 0 ? 0 : Double(swapUsedBytes) / Double(swapTotalBytes) }
    var compressedFraction: Double { totalBytes == 0 ? 0 : Double(compressedBytes) / Double(totalBytes) }

    /// The colour is the *memory pressure*, not "how full does RAM look".
    ///
    /// This used to be a hand-rolled heuristic over occupancy, swap and compression
    /// and it was wrong: swap used and compressor size never shrink on an 8 GB Mac,
    /// so those thresholds stayed tripped forever and the icon was pinned orange
    /// even while macOS itself reported normal pressure. Now the kernel's own
    /// pressure dispatch decides - the same signal Activity Monitor follows.
    var level: HealthLevel {
        // 1. Kernel pressure dispatch: 1 normal, 2 warning, 4 critical.
        if pressureRaw >= 4 { return .critical }
        if pressureRaw >= 2 { return .warn }

        // 2. Unambiguous thrashing. Healthy machines page out a few dozen pages a
        //    second at most; 1000 pages/s (16 MB/s) is not a momentary blip.
        if pageOutRate >= 1_000 { return .critical }

        // 3. Safety nets, and the whole story if the pressure sysctl is missing.
        if availableFraction > 0 {
            if availableFraction <= 0.10 { return .critical }
            if availableFraction <= 0.18 { return .warn }
        } else if usedFraction >= 0.95 {
            return .warn
        }
        return .ok
    }
}

struct ProcessUsage {
    var name: String
    var footprintBytes: UInt64
}

struct SystemSnapshot {
    var memory = MemorySnapshot()
    var temperatures = TemperatureReading()
    var cpuPercent: Double = 0
    var loadAverage: [Double] = []
    var diskFreeBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0
    var uptime: TimeInterval = 0
    var thermal: String = "-"
    var topProcesses: [ProcessUsage] = []
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let amount = Double(value)
        if amount >= gb { return String(format: "%.2f GB", amount / gb) }
        if amount >= mb { return String(format: "%.0f MB", amount / mb) }
        if amount >= kb { return String(format: "%.0f KB", amount / kb) }
        return "\(value) B"
    }

    /// `value` is already a percentage (0...100).
    static func pct(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Sampler

/// Reads everything straight out of Mach / sysctl.
///
/// Deliberately never shells out to `top`, `vm_stat`, `ps` or `sysctl`: forking
/// those ships on every tick is what makes most "light" monitors heavy. These
/// calls are in-process, allocation-free after warm-up, and take microseconds.
final class SystemSampler {
    private var previousCPUTicks: [UInt32] = []
    private var lastCPUPercent: Double = 0
    private var previousPageOuts: UInt64 = 0
    private var previousPageOutTime: Date?
    private let pageSize: UInt64
    let temperatures = TemperatureSampler()

    init() {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        pageSize = UInt64(size)
    }

    // MARK: Memory

    func memorySnapshot() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.totalBytes = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        if result == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeablePages = UInt64(stats.purgeable_count)
            snapshot.appBytes = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
            snapshot.wiredBytes = UInt64(stats.wire_count) * pageSize
            snapshot.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
            snapshot.cachedFileBytes = UInt64(stats.external_page_count) * pageSize
            snapshot.freeBytes = UInt64(stats.free_count) * pageSize
            snapshot.pageOutRate = pageOutRate(counter: UInt64(stats.pageouts))
        }

        if let swap = Self.swapUsage() {
            snapshot.swapTotalBytes = swap.total
            snapshot.swapUsedBytes = swap.used
        }

        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
            snapshot.pressureRaw = Int(pressure)
        }

        // The kernel's own free-memory percentage - the same number `memory_pressure`
        // reports as "System-wide memory free percentage".
        var available: Int32 = -1
        var availableSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &available, &availableSize, nil, 0) == 0,
           available >= 0, available <= 100 {
            snapshot.availableFraction = Double(available) / 100
        }

        return snapshot
    }

    /// `pageouts` is a cumulative counter, so the rate is what matters. A machine
    /// that is paging out hard stays flat everywhere else for a while.
    private func pageOutRate(counter: UInt64) -> Double {
        let now = Date()
        defer {
            previousPageOuts = counter
            previousPageOutTime = now
        }
        guard let lastTime = previousPageOutTime, counter >= previousPageOuts else { return 0 }
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0.5 else { return 0 }
        return Double(counter - previousPageOuts) / elapsed
    }

    static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (UInt64(usage.xsu_total), UInt64(usage.xsu_used))
    }

    // MARK: CPU

    /// Percentage across all cores, computed from tick deltas between calls.
    func cpuPercent() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return lastCPUPercent }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let states = Int(CPU_STATE_MAX)
        let slotCount = Int(cpuCount) * states
        var current = [UInt32](repeating: 0, count: slotCount)
        for index in 0..<slotCount {
            current[index] = UInt32(bitPattern: info[index])
        }
        defer { previousCPUTicks = current }

        guard previousCPUTicks.count == slotCount else { return lastCPUPercent }

        var busy: Double = 0
        var total: Double = 0
        for core in 0..<Int(cpuCount) {
            let base = core * states
            for state in 0..<states {
                let delta = Double(max(0, Int64(current[base + state]) - Int64(previousCPUTicks[base + state])))
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        guard total > 0 else { return lastCPUPercent }
        lastCPUPercent = min(100, max(0, busy / total * 100))
        return lastCPUPercent
    }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return [] }
        return values
    }

    static func diskUsage(path: String = "/") -> (free: UInt64, total: UInt64)? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let blockSize = UInt64(stats.f_bsize)
        return (UInt64(stats.f_bavail) * blockSize, UInt64(stats.f_blocks) * blockSize)
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "-"
        }
    }

    // MARK: Snapshot

    /// Cheap path: memory, CPU, load, disk, uptime, temperatures. Runs on every tick.
    func snapshot(topProcesses: [ProcessUsage]) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.memory = memorySnapshot()
        snapshot.temperatures = temperatures.read()
        snapshot.cpuPercent = cpuPercent()
        snapshot.loadAverage = Self.loadAverage()
        if let disk = Self.diskUsage() {
            snapshot.diskFreeBytes = disk.free
            snapshot.diskTotalBytes = disk.total
        }
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.thermal = Self.thermalState()
        snapshot.topProcesses = topProcesses
        return snapshot
    }

    // MARK: Processes

    /// Physical footprint per process via libproc, grouped by name so helper
    /// processes do not flood the list. Only ever called while the panel is
    /// open, off the main thread.
    static func topProcesses(limit: Int = 4) -> [ProcessUsage] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: count + 64)
        let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard filled > 0 else { return [] }

        var byName: [String: UInt64] = [:]
        byName.reserveCapacity(64)

        for index in 0..<min(filled, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            guard result == 0, usage.ri_phys_footprint > 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let name = Self.displayName(String(cString: nameBuffer))
            guard !name.isEmpty else { continue }

            byName[name, default: 0] += usage.ri_phys_footprint
        }

        return byName
            .map { ProcessUsage(name: $0.key, footprintBytes: $0.value) }
            .sorted { $0.footprintBytes > $1.footprintBytes }
            .prefix(limit)
            .map { $0 }
    }

    /// Rolls helper processes into their parent app and trims reverse-DNS noise,
    /// so the list reads "Google Chrome" instead of four separate helpers.
    static func displayName(_ raw: String) -> String {
        var name = raw
        if let helper = name.range(of: " Helper") {
            name = String(name[name.startIndex..<helper.lowerBound])
        }
        if name.hasPrefix("com.apple.") {
            name.removeFirst("com.apple.".count)
        }
        return name
    }
}
