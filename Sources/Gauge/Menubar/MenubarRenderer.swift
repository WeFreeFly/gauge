// SPDX-License-Identifier: Apache-2.0
import AppKit
import GaugeKit

/// Draws a menu bar item into an image.
///
/// Rendering to an image rather than composing subviews keeps each item a
/// single layer the system can position, and makes the graph styles possible
/// at all — the menu bar gives no layout control beyond a width.
enum MenubarRenderer {
    static let gaugeWidth: CGFloat = 20
    private static let horizontalPadding: CGFloat = 4
    private static let spacing: CGFloat = 4

    static func render(_ content: MenubarContent, style: MenubarStyle,
                       graphWidth: CGFloat = 32,
                       appearance: NSAppearance) -> NSImage {
        let height = max(18, NSStatusBar.system.thickness - 2)
        var segments: [(width: CGFloat, draw: (CGRect) -> Void)] = []

        let wantsSymbol = style == .icon || (content.lines.isEmpty && content.series.isEmpty)
        if wantsSymbol, let symbolName = content.symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let size = NSSize(width: height - 4, height: height - 4)
            segments.append((size.width, { rect in
                symbol.isTemplate = true
                symbol.draw(in: CGRect(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
            }))
        }

        if style == .gauge, let fraction = content.fraction {
            segments.append((gaugeWidth, { rect in
                drawRing(in: rect, fraction: fraction, color: content.primaryColor)
            }))
        }

        let showsText = style == .text || style == .textAndGraph
            || (style == .gauge && !content.lines.isEmpty)
        if showsText, !content.lines.isEmpty {
            let attributed = attributedText(content)
            let textWidth = ceil(attributed.map { $0.size().width }.max() ?? 0)
            segments.append((textWidth, { rect in
                drawLines(attributed, in: rect)
            }))
        }

        let showsGraph = style == .graph || style == .textAndGraph
        if showsGraph, !content.series.isEmpty || !content.secondarySeries.isEmpty {
            segments.append((graphWidth, { rect in
                drawGraph(content, in: rect)
            }))
        }

        // Nothing to draw yet (first tick, before any sample) — keep the slot.
        if segments.isEmpty {
            segments.append((14, { rect in
                NSColor.tertiaryLabelColor.setFill()
                CGRect(x: rect.midX - 5, y: rect.midY - 1, width: 10, height: 2).fill()
            }))
        }

        let contentWidth = segments.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, segments.count - 1))
        let totalWidth = contentWidth + horizontalPadding * 2

        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocusFlipped(false)
        appearance.performAsCurrentDrawingAppearance {
            var x = horizontalPadding
            for segment in segments {
                segment.draw(CGRect(x: x, y: 0, width: segment.width, height: height))
                x += segment.width + spacing
            }
        }
        image.unlockFocus()
        // Not a template: the chosen colours are the point.
        image.isTemplate = false
        return image
    }

    // MARK: Text

    private static func attributedText(_ content: MenubarContent) -> [NSAttributedString] {
        let twoLine = content.lines.count > 1
        let size: CGFloat = twoLine ? 9 : 12
        let weight: NSFont.Weight = twoLine ? .medium : .regular
        let font = content.monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)

        return content.lines.enumerated().map { index, line in
            // In a two-line pair the second line takes the secondary colour, so
            // download and upload are told apart at a glance.
            let color = twoLine
                ? (index == 0 ? NSColor(content.appearance.primaryHex) ?? .labelColor
                              : content.secondaryColor)
                : content.textColor
            return NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
        }
    }

    private static func drawLines(_ lines: [NSAttributedString], in rect: CGRect) {
        guard !lines.isEmpty else { return }
        if lines.count == 1 {
            let size = lines[0].size()
            lines[0].draw(at: CGPoint(x: rect.minX, y: rect.midY - size.height / 2))
            return
        }
        // Stack from the top so the pair stays optically centred.
        let lineHeight = lines[0].size().height
        let total = lineHeight * CGFloat(lines.count)
        var y = rect.midY + total / 2 - lineHeight
        for line in lines {
            line.draw(at: CGPoint(x: rect.minX, y: y))
            y -= lineHeight
        }
    }

    // MARK: Graph

    private static func drawGraph(_ content: MenubarContent, in rect: CGRect) {
        let inset = rect.insetBy(dx: 0, dy: 3)

        NSColor.quaternaryLabelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 2, yRadius: 2).fill()

        let ceiling = content.seriesMaximum ?? autoCeiling(content)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inset, xRadius: 2, yRadius: 2).addClip()

        if !content.secondarySeries.isEmpty {
            draw(series: content.secondarySeries, in: inset, ceiling: ceiling,
                 color: content.secondaryColor, appearance: content.appearance)
        }
        if !content.series.isEmpty {
            draw(series: content.series, in: inset, ceiling: ceiling,
                 color: content.primaryColor, appearance: content.appearance)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Rate graphs have no natural ceiling, so scale to the window's own peak
    /// with a floor that stops idle noise from filling the chart.
    private static func autoCeiling(_ content: MenubarContent) -> Double {
        let peak = max(content.series.max() ?? 0, content.secondarySeries.max() ?? 0)
        return peak > 0 ? peak : 1
    }

    private static func draw(series: [Double], in rect: CGRect, ceiling: Double,
                             color: NSColor, appearance: GraphAppearance) {
        guard series.count > 1, ceiling > 0 else { return }

        let step = rect.width / CGFloat(series.count - 1)
        func point(_ index: Int) -> CGPoint {
            let fraction = (series[index] / ceiling).clamped(to: 0...1)
            return CGPoint(x: rect.minX + step * CGFloat(index),
                           y: rect.minY + rect.height * CGFloat(fraction))
        }

        if appearance.fade != .outline {
            let fill = NSBezierPath()
            fill.move(to: CGPoint(x: rect.minX, y: rect.minY))
            for index in series.indices { fill.line(to: point(index)) }
            fill.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            fill.close()

            switch appearance.fade {
            case .gradient:
                NSGraphicsContext.saveGraphicsState()
                fill.addClip()
                NSGradient(starting: color.withAlphaComponent(appearance.fadeOpacity),
                           ending: color.withAlphaComponent(0.02))?
                    .draw(in: rect, angle: -90)
                NSGraphicsContext.restoreGraphicsState()
            case .duotone:
                NSGraphicsContext.saveGraphicsState()
                fill.addClip()
                let other = NSColor(appearance.secondaryHex) ?? color
                NSGradient(starting: color.withAlphaComponent(appearance.fadeOpacity),
                           ending: other.withAlphaComponent(appearance.fadeOpacity * 0.6))?
                    .draw(in: rect, angle: -90)
                NSGraphicsContext.restoreGraphicsState()
            case .flat:
                color.withAlphaComponent(appearance.fadeOpacity).setFill()
                fill.fill()
            case .outline:
                break
            }
        }

        guard appearance.showsLine else { return }
        let line = NSBezierPath()
        for index in series.indices {
            index == 0 ? line.move(to: point(index)) : line.line(to: point(index))
        }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
    }

    // MARK: Gauge

    private static func drawRing(in rect: CGRect, fraction: Double, color: NSColor) {
        let diameter = min(rect.width, rect.height) - 4
        let box = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                         width: diameter, height: diameter)
        let lineWidth: CGFloat = 2.5
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = diameter / 2 - lineWidth / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        guard fraction > 0 else { return }
        let sweep = 360 * CGFloat(fraction.clamped(to: 0...1))
        let progress = NSBezierPath()
        // Start at the top and run clockwise, which reads as "filling up".
        progress.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        color.setStroke()
        progress.stroke()
    }
}
