// SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env swift
//
// Draws the app icon and writes an .icns. Run from the project root:
//   swift Scripts/make-icon.swift
//
// Kept as a script rather than a checked-in binary asset so the artwork stays
// reviewable in the diff.

import AppKit
import Foundation

let projectRoot = FileManager.default.currentDirectoryPath
let iconsetURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("build/AppIcon.iconset")
let outputURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("Resources/AppIcon.icns")

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)

    // Rounded-square backdrop, dark so the dial reads at small sizes.
    let corner = size * 0.2237      // matches the macOS icon grid
    let backdrop = NSBezierPath(roundedRect: inset, xRadius: corner, yRadius: corner)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)])?
        .draw(in: backdrop, angle: -90)

    let center = CGPoint(x: rect.midX, y: rect.midY - size * 0.05)
    let radius = size * 0.29
    let lineWidth = size * 0.075

    // Dial track: a 240° sweep, the shape of an analogue gauge.
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 210, endAngle: -30, clockwise: true)
    track.lineWidth = lineWidth
    track.lineCapStyle = .round
    NSColor(calibratedWhite: 1, alpha: 0.13).setStroke()
    track.stroke()

    // Filled portion, green through to red as the needle climbs.
    let sweep: CGFloat = 0.68
    let filled = NSBezierPath()
    filled.appendArc(withCenter: center, radius: radius,
                     startAngle: 210, endAngle: 210 - 240 * sweep, clockwise: true)
    filled.lineWidth = lineWidth
    filled.lineCapStyle = .round
    NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.50, alpha: 1).setStroke()
    filled.stroke()

    // Needle.
    let angle = (210 - 240 * sweep) * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: CGPoint(x: center.x + cos(angle) * radius * 0.86,
                            y: center.y + sin(angle) * radius * 0.86))
    needle.lineWidth = size * 0.045
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()

    // Hub.
    let hubRadius = size * 0.045
    let hub = NSBezierPath(ovalIn: CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                          width: hubRadius * 2, height: hubRadius * 2))
    NSColor.white.setFill()
    hub.fill()

    return image
}

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = drawIcon(size: CGFloat(pixels))
    guard let data = png(image, pixels: pixels) else { continue }
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote \(outputURL.path)" : "iconutil failed")
