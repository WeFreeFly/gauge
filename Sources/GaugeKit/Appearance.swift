import Foundation

/// How a graph is filled under its line.
public enum FadeStyle: String, Codable, CaseIterable, Sendable {
    /// Colour fading to transparent — the iStat Menus look.
    case gradient
    /// One flat translucent colour.
    case flat
    /// Line only, nothing underneath.
    case outline
    /// Fades between the two chosen colours instead of to transparent.
    case duotone

    public var title: String {
        switch self {
        case .gradient: "Fade to clear"
        case .flat: "Solid fill"
        case .outline: "Line only"
        case .duotone: "Fade between colours"
        }
    }
}

/// Per-module graph colours. Stored as hex so the settings file stays readable
/// and portable between machines.
public struct GraphAppearance: Codable, Equatable, Sendable {
    public var primaryHex: String
    public var secondaryHex: String
    public var fade: FadeStyle
    /// Opacity at the top of the fill, 0…1. The bottom is always clear for
    /// `.gradient` and this same value for `.flat`.
    public var fadeOpacity: Double
    /// Draw the line along the top of the fill.
    public var showsLine: Bool
    /// Colour the value by load instead of using `primaryHex`.
    public var usesLoadColor: Bool

    public init(primaryHex: String, secondaryHex: String = "#34C759",
                fade: FadeStyle = .gradient, fadeOpacity: Double = 0.45,
                showsLine: Bool = true, usesLoadColor: Bool = false) {
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
        self.fade = fade
        self.fadeOpacity = fadeOpacity
        self.showsLine = showsLine
        self.usesLoadColor = usesLoadColor
    }

    /// Defaults picked to read clearly in both light and dark menu bars.
    public static func standard(for module: ModuleID) -> GraphAppearance {
        switch module {
        case .cpu:      GraphAppearance(primaryHex: "#0A84FF", secondaryHex: "#30D158", usesLoadColor: true)
        case .gpu:      GraphAppearance(primaryHex: "#BF5AF2", secondaryHex: "#0A84FF", usesLoadColor: true)
        case .memory:   GraphAppearance(primaryHex: "#FF9F0A", secondaryHex: "#BF5AF2", usesLoadColor: true)
        case .disks:    GraphAppearance(primaryHex: "#0A84FF", secondaryHex: "#BF5AF2")
        case .network:  GraphAppearance(primaryHex: "#0A84FF", secondaryHex: "#30D158")
        case .sensors:  GraphAppearance(primaryHex: "#FF453A", secondaryHex: "#5AC8FA", usesLoadColor: true)
        case .battery:  GraphAppearance(primaryHex: "#30D158", secondaryHex: "#FF9F0A")
        case .time:     GraphAppearance(primaryHex: "#8E8E93", secondaryHex: "#8E8E93")
        case .weather:  GraphAppearance(primaryHex: "#5AC8FA", secondaryHex: "#FF9F0A")
        case .combined: GraphAppearance(primaryHex: "#0A84FF", secondaryHex: "#30D158", usesLoadColor: true)
        }
    }
}

/// A colour that survives a round trip through the settings file.
public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Accepts "#RRGGBB" and "#RRGGBBAA", with or without the hash.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt32(text, radix: 16) else { return nil }

        if text.count == 6 {
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xff) / 255
            green = Double((value >> 16) & 0xff) / 255
            blue = Double((value >> 8) & 0xff) / 255
            alpha = Double(value & 0xff) / 255
        }
    }

    public var hex: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Blend towards another colour; used for the duotone fade.
    public func blended(with other: RGBAColor, amount: Double) -> RGBAColor {
        let t = amount.clamped(to: 0...1)
        return RGBAColor(red: red + (other.red - red) * t,
                         green: green + (other.green - green) * t,
                         blue: blue + (other.blue - blue) * t,
                         alpha: alpha + (other.alpha - alpha) * t)
    }
}

/// How much the panel background lets through.
public enum PanelMaterial: String, Codable, CaseIterable, Sendable {
    case vibrant, opaque

    public var title: String {
        switch self {
        case .vibrant: "Translucent"
        case .opaque: "Solid"
        }
    }
}
