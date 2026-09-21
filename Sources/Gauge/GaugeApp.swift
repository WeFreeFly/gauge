import AppKit
import GaugeKit

/// A thread-safe boolean for waiting on detached work from a run loop.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@main
struct GaugeApp {
    /// The entry point runs on the main thread, and everything it touches —
    /// NSApplication, the status items, the monitor hub — is main-actor bound.
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        // `--dump` runs one sampling pass and prints it, which is how the
        // collectors get checked against Activity Monitor, `ps` and `ioreg`
        // without launching any UI.
        if arguments.contains("--dump") {
            DiagnosticsDump.run(passes: 2)
            return
        }
        // `--preview <dir>` writes every menu bar style and every panel to PNG,
        // which is the only way to review the drawing without a screen.
        if let index = arguments.firstIndex(of: "--preview") {
            let directory = arguments.count > index + 1 ? arguments[index + 1] : "./preview"
            PreviewRenderer.run(outputDirectory: directory,
                                demo: arguments.contains("--demo"))
            return
        }
        // `--weather <place>` checks the provider end to end. It is the only
        // diagnostic that leaves the machine.
        if let index = arguments.firstIndex(of: "--weather") {
            let query = arguments.count > index + 1 ? arguments[index + 1] : "London"
            // main() is main-actor isolated, so blocking it on a semaphore
            // would deadlock the task that is supposed to signal it. Spin the
            // run loop instead and let the detached work finish.
            let finished = Flag()
            Task.detached {
                await WeatherProbe.run(query: query)
                finished.set()
            }
            while !finished.isSet {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return
        }
        // `--map-sensors` measures which thermal sensors respond to CPU load,
        // which is how the sensor grouping in GaugeKit was decided.
        if arguments.contains("--map-sensors") {
            SensorMapping.run()
            return
        }
        if arguments.contains("--bench") {
            Benchmark.run(iterations: 20)
            return
        }
        if arguments.contains("--version") {
            print("Gauge \(GaugeVersion.string)")
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu bar only: no Dock tile, no window on launch.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
