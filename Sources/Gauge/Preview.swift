import AppKit
import SwiftUI
import GaugeKit

/// Renders the menu bar items and dropdown panels to PNG files.
///
/// Without this there is no way to check the drawing code except by looking at
/// a running menu bar, which a build machine cannot do.
@MainActor
enum PreviewRenderer {
    static func run(outputDirectory: String, demo: Bool = false) {
        let directory = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A GUI-less process still needs an NSApplication before AppKit will
        // lay anything out.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let hub = MonitorHub()
        // Panels render the live path, so preview them that way.
        hub.isShowingDetail = true
        // Two passes so every rate has a baseline to subtract from.
        hub.sampleNow()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        hub.sampleNow()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Two samples make a straight line; a demo history shows the shapes.
        if demo {
            hub.injectDemoHistory()
            hub.settings.weatherEnabled = true
            hub.injectDemoWeather()
        }

        let appearances = [
            ("light", NSAppearance(named: .aqua)!),
            ("dark", NSAppearance(named: .darkAqua)!),
        ]

        for module in ModuleID.allCases {
            let content = MenubarContentBuilder.content(for: module, hub: hub)
            for style in MenubarStyle.allCases {
                for (label, appearance) in appearances {
                    let image = MenubarRenderer.render(content, style: style, appearance: appearance)
                    let name = "menubar-\(module.rawValue)-\(style.rawValue)-\(label).png"
                    write(image, to: directory.appendingPathComponent(name), background: label == "dark"
                          ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1))
                }
            }
        }

        for module in ModuleID.allCases {
            for (label, appearance) in appearances {
                guard let image = renderPanel(module: module, hub: hub, appearance: appearance) else { continue }
                // A popover draws on the system's own material; without a
                // backing colour, dark-mode text is white on transparent.
                write(image, to: directory.appendingPathComponent("panel-\(module.rawValue)-\(label).png"),
                      background: backdrop(for: appearance))
            }
        }

        // The settings window is worth reviewing too, especially the colour
        // controls, which are the part most likely to look wrong.
        for (label, appearance) in appearances {
            if let image = renderSettings(hub: hub, appearance: appearance) {
                write(image, to: directory.appendingPathComponent("settings-appearance-\(label).png"),
                      background: backdrop(for: appearance))
            }
        }

        print("Wrote previews to \(directory.path)")
    }

    private static func backdrop(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    private static func renderSettings(hub: MonitorHub, appearance: NSAppearance) -> NSImage? {
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AppearanceSettingsPage()
            }
            .padding(20)
        }
        .frame(width: 460, height: 720)
        .environmentObject(hub)
        .environmentObject(hub.settings)

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.wantsLayer = true
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private static func renderPanel(module: ModuleID, hub: MonitorHub,
                                    appearance: NSAppearance) -> NSImage? {
        let root = ModulePanelView(module: module)
            .environmentObject(hub)
            .environmentObject(hub.settings)

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 320, height: 400) }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func write(_ image: NSImage, to url: URL, background: NSColor?) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        representation.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        if let background {
            background.setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
