import Darwin
import Foundation
import IOKit

struct TemperatureReading {
    var cpuCelsius: Double?
    var gpuCelsius: Double?

    var isAvailable: Bool { cpuCelsius != nil || gpuCelsius != nil }
}

/// CPU and GPU temperature.
///
/// macOS has no public API for this, and the usual trick - reading `AppleSMC`
/// with the classic Intel keys (`TC0P`, `Tp09`, `Tg0f`) - does not work on this
/// machine: those keys return `result = 132` (not found), every `Tg*`/`TG*` key
/// reads 0, and the only SMC keys that carry live numbers are `Tp*` / `Te*` /
/// `Tc*`. The GPU is not in the SMC key space at all.
///
/// The sensors that do carry the useful numbers live in the HID sensor hub, the
/// same private API `asitop` and friends use. Which sensor means what was not
/// guessed: the CPU was loaded and the sensors that moved were
/// `pACC MTR Temp Sensor*` (performance cores, +8 to +13 C) and
/// `eACC MTR Temp Sensor*` (efficiency cores, +4 to +6 C), while
/// `GPU MTR Temp Sensor*` stayed flat - that is the GPU.
///
/// The service list is resolved once and cached; re-enumerating all 142 HID
/// services on every tick would be the expensive part.
final class TemperatureSampler {
    enum Family {
        case cpuPerformance
        case cpuEfficiency
        case gpu
    }

    private struct Sensor {
        let label: String
        let service: UnsafeMutableRawPointer
        let family: Family
    }

    private typealias ClientCreateFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    private static let eventTypeTemperature: Int64 = 15
    private static let fieldTemperatureLevel: Int32 = 15 << 16
    /// Sensors move slowly; there is nothing to gain from reading them every tick.
    private static let cacheLifetime: TimeInterval = 2
    private static let resolveRetryInterval: TimeInterval = 60
    /// The HID hub reports exactly 30.0 for a block that is powered down: on this
    /// M1 the ANE and ISP sensors read 30.0 permanently, and the GPU sensors flip
    /// between real values and 30.0 with power state. Anything at or below this is
    /// "no reading", not a temperature. Verified by loading the GPU with a Metal
    /// compute loop - real sensors went 52 -> 69 C while ANE/ISP stayed at 30.0.
    private static let minimumPlausibleCelsius = 31.0

    private let createClient: ClientCreateFn?
    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?

    /// Kept alive for the process lifetime: the cached sensor pointers point into
    /// this service list.
    private var client: UnsafeMutableRawPointer?
    private var services: CFArray?
    private var sensors: [Sensor] = []

    private var lastResolve = Date.distantPast
    private var lastRead = Date.distantPast
    private var cached = TemperatureReading()

    init() {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let handle = dlopen(path, RTLD_NOW)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        createClient = symbol("IOHIDEventSystemClientCreate", as: ClientCreateFn.self)
        copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloatFn.self)
    }

    func read() -> TemperatureReading {
        let now = Date()
        if now.timeIntervalSince(lastRead) < Self.cacheLifetime { return cached }
        return sample(at: now)
    }

    /// Bypasses the cache. Used by `--self-test` to measure the real cost.
    func readNow() -> TemperatureReading {
        sample(at: Date())
    }

    private func sample(at now: Date) -> TemperatureReading {
        lastRead = now

        if sensors.isEmpty, now.timeIntervalSince(lastResolve) > Self.resolveRetryInterval {
            resolveSensors()
        }
        guard !sensors.isEmpty else { return cached }

        var cpu: Double?
        var gpu: Double?
        for sensor in sensors {
            guard let value = temperature(of: sensor.service),
                  value > Self.minimumPlausibleCelsius, value < 150 else { continue }
            switch sensor.family {
            case .cpuPerformance, .cpuEfficiency:
                cpu = max(cpu ?? 0, value)
            case .gpu:
                gpu = max(gpu ?? 0, value)
            }
        }

        cached = TemperatureReading(cpuCelsius: cpu, gpuCelsius: gpu)
        return cached
    }

    // MARK: - Internals

    private func resolveSensors() {
        lastResolve = Date()
        guard let createClient, let copyServices, let copyProperty else { return }
        guard let client = createClient(nil) else { return }
        self.client = client
        guard let list = copyServices(client)?.takeRetainedValue() else { return }
        services = list

        var found: [Sensor] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let property = copyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                  let label = property as? String,
                  let family = Self.family(for: label)
            else { continue }
            found.append(Sensor(label: label, service: service, family: family))
        }
        sensors = found
    }

    private static func family(for label: String) -> Family? {
        if label.hasPrefix("pACC MTR Temp Sensor") { return .cpuPerformance }
        if label.hasPrefix("eACC MTR Temp Sensor") { return .cpuEfficiency }
        if label.hasPrefix("GPU MTR Temp Sensor") { return .gpu }
        return nil
    }

    private func temperature(of service: UnsafeMutableRawPointer) -> Double? {
        guard let copyEvent, let getFloat,
              let event = copyEvent(service, Self.eventTypeTemperature, 0, 0)?.takeRetainedValue()
        else { return nil }
        let pointer = Unmanaged.passUnretained(event).toOpaque()
        return getFloat(UnsafeMutableRawPointer(mutating: pointer), Self.fieldTemperatureLevel)
    }

    /// Sensor names, for `--self-test`.
    var sensorSummary: String {
        sensors
            .map { "\($0.label)" }
            .sorted()
            .joined(separator: ", ")
    }
}
