import Darwin
import os
import UIKit

/// The keyboard's memory as iOS judges it, for the device log.
///
/// `phys_footprint` is the number jetsam compares with the extension's limit (dirty
/// and compressed memory; clean mapped files such as the engine's models mostly do
/// not count), and `os_proc_available_memory` is how far below that limit the process
/// is. Their sum is the limit itself. Nothing leaves the device: this goes to the
/// unified log only, read with `idevicesyslog -m OBADH-MEM`.
final class MemoryProbe {
    private static let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "memory")

    /// Keyboard controllers alive in this process. iOS makes a new one for every
    /// presentation and should free the last; a count that only grows is a leak.
    private static let liveControllers = OSAllocatedUnfairLock(initialState: 0)
    private var controllerAddress: String?
    private var loadedAt: UInt64 = 0
    private var previousTime: UInt64 = 0
    private var previousFootprint: UInt64 = 0
    private var recordedFirstLayout = false

    func controllerDidLoad(_ controller: AnyObject) {
        // Store only an address string: diagnostics must not keep the controller alive.
        if controllerAddress == nil {
            controllerAddress = String(describing: Unmanaged.passUnretained(controller).toOpaque())
            let count = Self.liveControllers.withLock { $0 += 1; return $0 }
            Self.log.notice("OBADH-MEM controllers alive: \(count, privacy: .public) controller=\(self.controllerAddress!, privacy: .public)")
        }
        loadedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        previousTime = loadedAt
        previousFootprint = Self.physicalFootprint()
        recordedFirstLayout = false
    }

    deinit {
        guard let controllerAddress else { return }
        let count = Self.liveControllers.withLock { $0 -= 1; return $0 }
        Self.log.notice("OBADH-MEM controller freed; alive: \(count, privacy: .public) controller=\(controllerAddress, privacy: .public)")
    }

    func record(_ moment: StaticString) {
        guard let controllerAddress else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsedMS = Double(now - loadedAt) / 1_000_000
        let phaseMS = Double(now - previousTime) / 1_000_000
        let footprint = Self.physicalFootprint()
        let available = os_proc_available_memory()
        let megabyte = 1_048_576.0
        let footprintMB = Double(footprint) / megabyte
        let availableMB = Double(available) / megabyte
        let deltaMB = (Double(footprint) - Double(previousFootprint)) / megabyte
        Self.log.notice("OBADH-MEM \(moment, privacy: .public): controller=\(controllerAddress, privacy: .public) elapsed=\(elapsedMS, format: .fixed(precision: 2), privacy: .public) ms phase=\(phaseMS, format: .fixed(precision: 2), privacy: .public) ms footprint \(footprintMB, format: .fixed(precision: 2), privacy: .public) MB delta=\(deltaMB, format: .fixed(precision: 2), privacy: .public) MB headroom \(availableMB, format: .fixed(precision: 1), privacy: .public) MB limit \(footprintMB + availableMB, format: .fixed(precision: 1), privacy: .public) MB")
        previousTime = now
        previousFootprint = footprint
    }

    /// Counts, not allocation sizes. Render-server surfaces and shared caches are
    /// not measurable from a view traversal; use Allocations + VM Tracker for bytes.
    @MainActor
    func recordFirstLayout(of root: UIView) {
        guard !recordedFirstLayout else { return }
        recordedFirstLayout = true
        record("first layout")
        var viewCounts: [String: Int] = [:]
        var layerCounts: [String: Int] = [:]
        func visitView(_ view: UIView) {
            viewCounts[String(describing: type(of: view)), default: 0] += 1
            view.subviews.forEach(visitView)
        }
        func visitLayer(_ layer: CALayer) {
            layerCounts[String(describing: type(of: layer)), default: 0] += 1
            layer.sublayers?.forEach(visitLayer)
            if let mask = layer.mask { visitLayer(mask) }
        }
        visitView(root)
        visitLayer(root.layer)
        let views = viewCounts.keys.sorted().map { "\($0)=\(viewCounts[$0]!)" }.joined(separator: ",")
        let layers = layerCounts.keys.sorted().map { "\($0)=\(layerCounts[$0]!)" }.joined(separator: ",")
        Self.log.notice("OBADH-MEM hierarchy controller=\(self.controllerAddress ?? "unknown", privacy: .public) views=[\(views, privacy: .public)] layers=[\(layers, privacy: .public)]")
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
