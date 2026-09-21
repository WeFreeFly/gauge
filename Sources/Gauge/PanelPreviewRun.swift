import AppKit
import SwiftUI
import GaugeKit

/// Opens one dropdown on screen and leaves it there.
///
/// The glass materials are composited by the window server, so they cannot be
/// captured offscreen — the only way to see or check one is to put a real
/// window up. `--panel cpu [seconds]` does exactly that and nothing else.
@MainActor
enum PanelPreviewRun {
    static func run(module: ModuleID, seconds: TimeInterval, expand: Bool = false) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let hub = MonitorHub()
        hub.isShowingDetail = true
        hub.sampleNow()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        hub.sampleNow()
        hub.injectDemoHistory()
        if module == .weather {
            hub.settings.weatherEnabled = true
            hub.injectDemoWeather()
        }

        let content: AnyView
        if module == .sensors, expand {
            content = AnyView(
                SensorsPanel(initiallyExpanded: Set(SensorGroup.allCases))
                    .environmentObject(hub)
                    .environmentObject(hub.settings)
            )
        } else {
            content = AnyView(
                ModulePanelView(module: module)
                    .environmentObject(hub)
                    .environmentObject(hub.settings)
            )
        }

        let panel = PanelWindow(content: content)
        // No status item to hang it off, so place it near the top of the screen.
        panel.showCentred()

        print("Showing the \(module.title) panel for \(Int(seconds))s "
            + "(\(hub.settings.panel.material.title)).")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        panel.close()
    }
}
