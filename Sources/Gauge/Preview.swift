// SPDX-License-Identifier: Apache-2.0
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
        // Liquid Glass and vibrancy are composited by the window server and
        // come out empty in an offscreen bitmap, so the previews use a solid
        // background. The material itself has to be judged on screen.
        hub.settings.panel = PanelAppearance(material: .opaque,
                                             tintHex: hub.settings.panel.tintHex,
                                             tintStrength: hub.settings.panel.tintStrength,
                                             cornerRadius: hub.settings.panel.cornerRadius,
                                             showsBorder: hub.settings.panel.showsBorder,
                                             shadowStrength: 0)

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

        for (label, appearance) in appearances {
            if let image = render(view: AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { AboutSettings() }.padding(20)
                }
                .frame(width: 460, height: 520)
                .environmentObject(hub)
                .environmentObject(hub.settings)
            ), appearance: appearance) {
                write(image, to: directory.appendingPathComponent("settings-about-\(label).png"),
                      background: backdrop(for: appearance))
            }
            if let image = render(view: AnyView(
                ChartGallery().environmentObject(hub).environmentObject(hub.settings)
            ), appearance: appearance) {
                write(image, to: directory.appendingPathComponent("charts-\(label).png"),
                      background: backdrop(for: appearance))
            }
        }

        // One strip showing the menu bar items together, which is the first
        // thing anyone wants to see.
        for (label, appearance) in appearances {
            if let image = menubarStrip(hub: hub, appearance: appearance) {
                write(image, to: directory.appendingPathComponent("menubar-strip-\(label).png"),
                      background: nil)
            }
        }

        print("Wrote previews to \(directory.path)")
    }

    /// Lays the enabled modules out the way they sit in a real menu bar.
    private static func menubarStrip(hub: MonitorHub, appearance: NSAppearance) -> NSImage? {
        let modules: [ModuleID] = [.combined, .cpu, .gpu, .memory, .disks, .network,
                                   .sensors, .battery, .weather, .time]
        let styles: [ModuleID: MenubarStyle] = [
            .combined: .textAndGraph, .cpu: .textAndGraph, .gpu: .text,
            .memory: .textAndGraph, .disks: .text, .network: .textAndGraph,
            .sensors: .text, .battery: .gauge, .weather: .text, .time: .text,
        ]

        var images: [NSImage] = []
        for module in modules {
            let content = MenubarContentBuilder.content(for: module, hub: hub)
            images.append(MenubarRenderer.render(content, style: styles[module] ?? .text,
                                                 graphWidth: hub.settings.menubarGraphWidth,
                                                 appearance: appearance))
        }

        let spacing: CGFloat = 10
        let padding: CGFloat = 16
        let height = max(28, (images.map(\.size.height).max() ?? 22) + 10)
        let width = images.reduce(0) { $0 + $1.size.width }
            + spacing * CGFloat(images.count - 1) + padding * 2

        let strip = NSImage(size: NSSize(width: width, height: height))
        strip.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            // A menu bar sits on the desktop, so the strip gets a backdrop
            // rather than floating on nothing.
            let isDark = appearance.name == .darkAqua
            (isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                         xRadius: 6, yRadius: 6).fill()

            var x = padding
            for image in images {
                image.draw(in: CGRect(x: x, y: (height - image.size.height) / 2,
                                      width: image.size.width, height: image.size.height))
                x += image.size.width + spacing
            }
        }
        strip.unlockFocus()
        return strip
    }

    private static func backdrop(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    /// Lays a SwiftUI view out offscreen and captures it.
    private static func render(view: AnyView, appearance: NSAppearance) -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 380, height: 600) }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
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
        // The panel measures its own content, so the size only settles after a
        // couple of layout passes with the run loop turning between them.
        var size = NSSize(width: 320, height: 400)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let measured = hosting.fittingSize
            if measured.width > 10, measured.height > 10 { size = measured }
            hosting.frame = NSRect(origin: .zero, size: size)
        }
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
