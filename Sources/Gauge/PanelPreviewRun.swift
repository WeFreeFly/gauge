// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import GaugeKit

/// Puts one dropdown on screen and leaves it there.
///
/// The glass materials are composited by the window server, so they cannot be
/// captured offscreen — the only way to see or photograph one is to put a real
/// window up. `--panel cpu [seconds]` does that; `--shot` adds a backdrop and
/// a fixed material so the screenshots in the README are reproducible.
@MainActor
enum PanelPreviewRun {
    struct Options {
        var module: ModuleID = .cpu
        var seconds: TimeInterval = 10
        /// Overrides the saved material for this run only.
        var material: PanelMaterial?
        /// Draws a wallpaper-like gradient in the same window, which is the
        /// only way glass has anything to refract in a window-only capture.
        var backdrop = false
    }

    static func run(_ options: Options) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        // A screenshot run uses its own defaults, so forcing a material never
        // touches what the person has actually chosen.
        let settings: GaugeSettings
        if options.material != nil || options.backdrop {
            let suite = "gauge.screenshot.\(UUID().uuidString)"
            settings = GaugeSettings(defaults: UserDefaults(suiteName: suite)!)
        } else {
            settings = .shared
        }
        if let material = options.material {
            settings.panel = PanelAppearance(material: material,
                                             tintHex: settings.panel.tintHex,
                                             tintStrength: settings.panel.tintStrength,
                                             cornerRadius: settings.panel.cornerRadius,
                                             showsBorder: settings.panel.showsBorder,
                                             shadowStrength: settings.panel.shadowStrength)
        }

        let hub = MonitorHub(settings: settings)
        hub.isShowingDetail = true
        hub.sampleNow()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        hub.sampleNow()
        hub.injectDemoHistory()
        if options.module == .weather {
            settings.weatherEnabled = true
            hub.injectDemoWeather()
        }

        let panel = ModulePanelView(module: options.module)
            .environmentObject(hub)
            .environmentObject(settings)

        let content: AnyView = options.backdrop
            ? AnyView(
                ZStack {
                    ScreenshotBackdrop()
                    // The panel already limits itself to the screen height;
                    // a wide margin here would push the pair past it and the
                    // footer would be cropped out of the shot.
                    panel.padding(14)
                }
                .fixedSize()
              )
            : AnyView(panel)

        let window = PanelWindow(content: content)
        window.showCentred()

        // The screenshot script captures by window id rather than by region,
        // which needs no screen-recording permission.
        print("window-id: \(window.windowNumber)")
        print("\(options.module.title) · \(settings.panel.material.title)"
            + " · \(Int(options.seconds))s")
        fflush(stdout)
        RunLoop.current.run(until: Date().addingTimeInterval(options.seconds))
        window.close()
    }
}

/// Something for the glass to refract. A flat colour would show nothing, and a
/// real desktop would make the screenshots depend on whose Mac took them.
struct ScreenshotBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#2B1C63"), Color(hex: "#1367A6"),
                                    Color(hex: "#149E8C"), Color(hex: "#C7761B")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            // Soft shapes give the refraction something to bend, which is what
            // makes glass read as glass.
            GeometryReader { geometry in
                ForEach(0..<7) { index in
                    Circle()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.16 : 0.09))
                        .frame(width: geometry.size.width * 0.42)
                        .offset(x: geometry.size.width * (0.08 * Double(index) - 0.15),
                                y: geometry.size.height * (0.13 * Double(index) - 0.1))
                        .blur(radius: 26)
                }
            }
        }
    }
}
