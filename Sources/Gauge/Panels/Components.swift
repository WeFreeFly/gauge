import SwiftUI
import Combine
import GaugeKit

/// Per-view local state, without `@State`.
///
/// In the macOS 26 SDK `@State` is a macro, and its plugin ships only with the
/// full Xcode install — a project built against the Command Line Tools alone
/// cannot expand it. `@StateObject` is an ordinary property wrapper with the
/// same per-view lifetime, so this box fills the gap; `$box.value` gives the
/// same `Binding` a `@State` property would.
final class UIState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Layout

/// Every dropdown uses the same width and rhythm so switching between them
/// does not feel like switching apps.
struct Panel<Content: View>: View {
    var width: CGFloat = 300
    @EnvironmentObject private var settings: GaugeSettings
    /// Measured height of the content, so the panel can be exactly as tall as
    /// it needs to be until it runs out of screen.
    @StateObject private var contentHeight = UIState<CGFloat>(0)
    @ViewBuilder var content: Content

    /// A dropdown hangs from the menu bar, so the room it has is the screen
    /// below that, less a margin. Expanding a long section — every sensor,
    /// say — used to push the rest off the bottom with no way to reach it.
    private var maximumHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 48)
    }

    private var isScrollable: Bool { contentHeight.value > maximumHeight + 1 }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(width: width, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight.value = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            contentHeight.value = height
                        }
                }
            )
        }
        .frame(width: width,
               height: min(max(contentHeight.value, 1), maximumHeight))
        .scrollIndicators(isScrollable ? .visible : .hidden)
        .scrollDisabled(!isScrollable)
        .panelChrome(settings.panel)
    }
}

/// The dropdown's background: Liquid Glass, the older vibrancy blur, or a
/// plain fill, with an optional tint and a hairline edge.
struct PanelChrome: ViewModifier {
    let appearance: PanelAppearance

    private var tint: Color? {
        guard let rgba = appearance.tint else { return nil }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue,
                     opacity: appearance.tintStrength)
    }

    /// Liquid Glass arrived in macOS 26. Asking for it on anything older
    /// falls back to the vibrancy blur, which is the closest thing available.
    private var resolvedMaterial: PanelMaterial {
        guard appearance.material.usesGlass else { return appearance.material }
        if #available(macOS 26.0, *) { return appearance.material }
        return .vibrant
    }

    func body(content: Content) -> some View {
        let radius = appearance.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        Group {
            switch resolvedMaterial {
            case .liquidGlass, .clearGlass:
                if #available(macOS 26.0, *) {
                    // Liquid Glass supplies its own shape, so it is applied
                    // rather than layered behind the content.
                    content.glassEffect(
                        (resolvedMaterial == .clearGlass ? Glass.clear : Glass.regular)
                            .tint(tint)
                            .interactive(appearance.interactive),
                        in: .rect(cornerRadius: radius))
                } else {
                    content.background { VisualEffectBackground() }.clipShape(shape)
                }
            case .vibrant:
                content
                    .background { VisualEffectBackground() }
                    .background { tint }
                    .clipShape(shape)
            case .opaque:
                content
                    .background(Color(nsColor: .windowBackgroundColor))
                    .background { tint }
                    .clipShape(shape)
            }
        }
        .overlay {
            if appearance.showsBorder {
                shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(appearance.shadowStrength),
                radius: 16 * appearance.shadowStrength, y: 6 * appearance.shadowStrength)
        // The shadow needs room outside the panel's own bounds.
        .padding(appearance.shadowStrength > 0 ? 14 : 0)
    }
}

extension View {
    func panelChrome(_ appearance: PanelAppearance) -> some View {
        modifier(PanelChrome(appearance: appearance))
    }
}

struct PanelHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.5)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var monospaced = true

    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var hovering = UIState(false)

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(hovering.value && settings.highlightRowsOnHover ? 0.07 : 0))
        )
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { hovering.value = $0 }
    }
}

// MARK: - Meters

struct BarMeter: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geometry.size.width * fraction.clamped(to: 0...1)))
            }
        }
        .frame(height: height)
    }
}

/// A stacked bar for memory, where the parts matter more than the total.
struct SegmentedMeter: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
        let label: String
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * (total > 0 ? segment.value / total : 0)))
                }
                Rectangle().fill(Color.primary.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
    }
}

// MARK: - Charts

/// A filled sparkline. Two series can share one plot — download over upload,
/// read over write — with the second drawn behind.
struct Sparkline: View {
    let values: [Double]
    var secondary: [Double] = []
    var ceiling: Double?
    var color: Color = .accentColor
    var secondaryColor: Color = .green
    var height: CGFloat = 46
    var showsBaseline = true
    /// When set, the fill style and opacity come from the user's settings.
    var appearance: GraphAppearance?

    private var resolvedCeiling: Double {
        if let ceiling, ceiling > 0 { return ceiling }
        let peak = max(values.max() ?? 0, secondary.max() ?? 0)
        return peak > 0 ? peak : 1
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))

            GeometryReader { geometry in
                if !secondary.isEmpty {
                    fill(secondary, in: geometry.size, color: secondaryColor, other: color)
                    if style.showsLine {
                        line(secondary, in: geometry.size)
                            .stroke(secondaryColor.opacity(0.85), lineWidth: 1)
                    }
                }
                if !values.isEmpty {
                    fill(values, in: geometry.size, color: color, other: secondaryColor)
                    if style.showsLine {
                        line(values, in: geometry.size)
                            .stroke(color, lineWidth: 1.4)
                    }
                }
            }
            .padding(.vertical, 2)

            if showsBaseline {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var style: GraphAppearance {
        appearance ?? GraphAppearance(primaryHex: "#0A84FF")
    }

    /// The fill under the line, in whichever style the module is set to.
    @ViewBuilder
    private func fill(_ series: [Double], in size: CGSize, color: Color, other: Color) -> some View {
        let opacity = style.fadeOpacity
        switch style.fade {
        case .gradient:
            area(series, in: size)
                .fill(LinearGradient(colors: [color.opacity(opacity), color.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        case .duotone:
            area(series, in: size)
                .fill(LinearGradient(colors: [color.opacity(opacity), other.opacity(opacity * 0.6)],
                                     startPoint: .top, endPoint: .bottom))
        case .flat:
            area(series, in: size).fill(color.opacity(opacity))
        case .outline:
            EmptyView()
        }
    }

    private func point(_ index: Int, _ value: Double, count: Int, size: CGSize) -> CGPoint {
        let x = count > 1 ? size.width * CGFloat(index) / CGFloat(count - 1) : size.width
        let fraction = (value / resolvedCeiling).clamped(to: 0...1)
        return CGPoint(x: x, y: size.height * (1 - CGFloat(fraction)))
    }

    private func line(_ series: [Double], in size: CGSize) -> Path {
        Path { path in
            guard series.count > 1 else { return }
            for (index, value) in series.enumerated() {
                let location = point(index, value, count: series.count, size: size)
                index == 0 ? path.move(to: location) : path.addLine(to: location)
            }
        }
    }

    private func area(_ series: [Double], in size: CGSize) -> Path {
        Path { path in
            guard series.count > 1 else { return }
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in series.enumerated() {
                path.addLine(to: point(index, value, count: series.count, size: size))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}

/// The span a history graph covers, captioned the way iStat Menus does it so
/// the axis is not left to guesswork.
struct GraphCaption: View {
    var trailing: String?
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        HStack {
            Text(settings.historyMinutes >= 60
                 ? "last \(settings.historyMinutes / 60) h"
                 : "last \(settings.historyMinutes) min")
            Spacer()
            if let trailing { Text(trailing) }
            Text("now")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }
}

/// Per-core load, drawn as a column per core with P and E cores separated.
struct CoreGrid: View {
    let cores: [CoreLoad]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(cores) { core in
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(color(for: core))
                                .frame(height: max(1, geometry.size.height * core.total))
                        }
                    }
                    // One letter is all that fits: "S" for Super, "E" for
                    // Efficiency, taken from the cluster's real name.
                    Text(core.clusterName.isEmpty ? "\(core.id)" : String(core.clusterName.prefix(1)))
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .help(core.label)
                }
            }
        }
        .frame(height: 44)
    }

    private func color(for core: CoreLoad) -> Color {
        let base: Color = core.kind == .efficiency ? .teal : .blue
        return base.opacity(0.35 + 0.65 * core.total)
    }
}

// MARK: - Process list

/// Icons are looked up from disk, which is far too slow to do while scrolling,
/// so each executable path is resolved once and kept.
enum ProcessIconCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func icon(forExecutable path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // "/Applications/Foo.app/Contents/MacOS/Foo" → the bundle, which is
        // what carries the icon; plain binaries fall back to their own.
        var target = path
        if let range = path.range(of: ".app/Contents/", options: .backwards) {
            target = String(path[path.startIndex..<range.lowerBound]) + ".app"
        }
        let image = NSWorkspace.shared.icon(forFile: target)
        image.size = NSSize(width: 16, height: 16)

        lock.lock()
        cache[path] = image
        lock.unlock()
        return image
    }
}

struct ProcessList: View {
    let title: String
    let processes: [ProcessUsage]
    let showsMemory: Bool
    var accent: Color = .secondary
    /// Bar behind each row showing its share of the largest value, the way
    /// iStat Menus ranks them.
    var showsBars = true

    private var peak: Double {
        let values = processes.map { showsMemory ? $0.memory : $0.cpu }
        return max(values.max() ?? 1, .leastNonzeroMagnitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: title)
            if processes.isEmpty {
                Text("Collecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(processes) { process in
                ProcessRow(process: process, showsMemory: showsMemory,
                           share: (showsMemory ? process.memory : process.cpu) / peak,
                           accent: accent, showsBar: showsBars)
            }
        }
    }
}

struct ProcessRow: View {
    let process: ProcessUsage
    let showsMemory: Bool
    let share: Double
    var accent: Color
    var showsBar: Bool

    @StateObject private var hovering = UIState(false)

    var body: some View {
        HStack(spacing: 6) {
            if let icon = ProcessIconCache.icon(forExecutable: process.path) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            Text(process.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(showsMemory ? Format.bytes(process.memory)
                             : String(format: "%.1f%%", process.cpu * 100))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(hovering.value ? 0.07 : 0))
                    if showsBar {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(accent.opacity(0.14))
                            .frame(width: max(0, geometry.size.width * share.clamped(to: 0...1)))
                    }
                }
            }
        }
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { hovering.value = $0 }
        .help(process.path.isEmpty ? process.name : process.path)
    }
}

// MARK: - Footer

struct PanelFooter: View {
    let onSettings: () -> Void
    var extraLabel: String?
    var extraAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if let extraLabel, let extraAction {
                Button(extraLabel, action: extraAction)
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            Spacer(minLength: 0)
            Button {
                onSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Gauge GaugeSettings")
        }
    }
}

extension Color {
    /// Shared load ramp so meters, graphs and the menu bar agree.
    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: .green
        case ..<0.75: .yellow
        case ..<0.9: .orange
        default: .red
        }
    }

    init(hex: String, fallback: Color = .accentColor) {
        guard let rgba = RGBAColor(hex: hex) else {
            self = fallback
            return
        }
        self = Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension GraphAppearance {
    var primary: Color { Color(hex: primaryHex) }
    var secondary: Color { Color(hex: secondaryHex, fallback: .green) }

    /// The colour a headline value should take: the load ramp when the module
    /// is set to follow load, otherwise the chosen colour.
    func valueColor(load: Double) -> Color {
        usesLoadColor ? .load(load) : primary
    }
}

/// The translucent backing a menu bar dropdown has on macOS. Plain SwiftUI has
/// no equivalent, so the AppKit view is wrapped directly.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
