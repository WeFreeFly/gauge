import Foundation
import IOKit

public struct GPUSnapshot: Sendable {
    public var name: String = "GPU"
    public var utilization: Double = 0
    public var rendererUtilization: Double = 0
    public var tilerUtilization: Double = 0
    /// Unified-memory Macs report what the GPU currently holds, not a separate VRAM pool.
    public var inUseMemory: Double = 0
    public var allocatedMemory: Double = 0
    public var isAvailable: Bool = false
}

public final class GPUMonitor: @unchecked Sendable {
    public init() {}

    public func sample() -> GPUSnapshot {
        var snapshot = GPUSnapshot()
        guard let matching = IOServiceMatching("IOAccelerator") else { return snapshot }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return snapshot
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
                  let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue }

            snapshot.isAvailable = true
            snapshot.name = Self.deviceName(for: entry) ?? (properties["IOClass"] as? String ?? "GPU")

            // Integer percentages, 0…100.
            if let device = statistics["Device Utilization %"] as? Int {
                snapshot.utilization = Double(device) / 100
            }
            if let renderer = statistics["Renderer Utilization %"] as? Int {
                snapshot.rendererUtilization = Double(renderer) / 100
            }
            if let tiler = statistics["Tiler Utilization %"] as? Int {
                snapshot.tilerUtilization = Double(tiler) / 100
            }
            if let inUse = statistics["In use system memory"] as? Int {
                snapshot.inUseMemory = Double(inUse)
            }
            if let allocated = statistics["Alloc system memory"] as? Int {
                snapshot.allocatedMemory = Double(allocated)
            }
            // The first accelerator with statistics is the active GPU.
            break
        }
        return snapshot
    }

    /// The accelerator node itself has no marketing name; its parent device does.
    private static func deviceName(for entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }

        if let model = IORegistryEntryCreateCFProperty(parent, "model" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() {
            if let data = model as? Data, let name = String(data: data, encoding: .utf8) {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            }
            if let name = model as? String { return name }
        }
        return nil
    }
}
