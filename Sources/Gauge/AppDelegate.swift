import AppKit
import GaugeKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hub = MonitorHub()
    private lazy var statusItems = StatusItemController(hub: hub)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If every module is switched off there is nothing on screen and no way
        // back in, so make sure at least one item exists.
        if GaugeSettings.shared.enabledModules.isEmpty {
            GaugeSettings.shared.setModule(.combined) { $0.enabled = true }
        }
        hub.start()
        statusItems.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
        GaugeSettings.shared.save()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
