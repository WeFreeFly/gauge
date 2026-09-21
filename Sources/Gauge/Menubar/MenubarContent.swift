// SPDX-License-Identifier: Apache-2.0
import AppKit
import GaugeKit

/// What one menu bar item should draw this tick.
///
/// Every module reduces to this shape so the renderer stays module-agnostic.
struct MenubarContent {
    /// One line renders at normal size; two lines stack at a smaller size, the
    /// way a download/upload pair needs to.
    var lines: [String] = []
    var series: [Double] = []
    /// Second series drawn behind the first, for up/down or read/write pairs.
    var secondarySeries: [Double] = []
    /// Fixed ceiling for the graph. Nil means auto-scale to the window's peak.
    var seriesMaximum: Double?
    var fraction: Double?
    var symbolName: String?
    /// Colours and fade, from the user's settings for this module.
    var appearance = GraphAppearance(primaryHex: "#0A84FF")
    /// Set when the value should be coloured by how loaded it is.
    var loadFraction: Double?
    var monospacedDigits = true

    // MARK: Resolved colours

    var primaryColor: NSColor {
        if appearance.usesLoadColor, let loadFraction {
            return Self.loadColor(loadFraction)
        }
        return NSColor(appearance.primaryHex) ?? .labelColor
    }

    var secondaryColor: NSColor {
        NSColor(appearance.secondaryHex) ?? .secondaryLabelColor
    }

    /// Colour of the first text line. Load-coloured modules tint the number;
    /// the rest stay in the menu bar's own colour so they read as system text.
    var textColor: NSColor {
        appearance.usesLoadColor && loadFraction != nil ? primaryColor : .labelColor
    }

    static func loadColor(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.5: .systemGreen
        case ..<0.75: .systemYellow
        case ..<0.9: .systemOrange
        default: .systemRed
        }
    }

    /// Identity for redraw suppression. Series values are quantised because a
    /// sub-pixel change in a 32-point sparkline is not worth a redraw.
    var signature: String {
        var parts: [String] = lines
        parts.append(symbolName ?? "")
        parts.append(fraction.map { String(Int($0 * 200)) } ?? "")
        parts.append(loadFraction.map { String(Int($0 * 100)) } ?? "")
        parts.append(appearance.primaryHex + appearance.secondaryHex
                     + appearance.fade.rawValue + String(Int(appearance.fadeOpacity * 100))
                     + (appearance.showsLine ? "L" : "-")
                     + (appearance.usesLoadColor ? "A" : "-"))
        parts.append(series.suffix(40).map { String(Int($0 * 100)) }.joined(separator: ","))
        parts.append(secondarySeries.suffix(40).map { String(Int($0 * 100)) }.joined(separator: ","))
        return parts.joined(separator: "|")
    }
}

extension NSColor {
    /// Builds a colour from "#RRGGBB". Returns nil rather than a wrong colour
    /// when the string is malformed.
    convenience init?(_ hex: String) {
        guard let rgba = RGBAColor(hex: hex) else { return nil }
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
