import SwiftUI
import GaugeKit

// MARK: - Shared plumbing

/// A named series with its own colour, so one chart can draw several.
struct Plot: Identifiable {
    let id = UUID()
    var values: [Double]
    var color: Color
    var label: String = ""

    var latest: Double { values.last ?? 0 }
}

/// Maps a series onto a rect. Pulled out so every chart type agrees on how a
/// value becomes a point — otherwise stacked and plain graphs drift apart.
private struct Scale {
    let ceiling: Double
    /// Bottom of the plot. Zero for anything measuring an amount; a tighter
    /// floor for things like temperature, where the interesting range is a few
    /// degrees wide and starting at zero would flatten the line.
    var floor: Double = 0
    let size: CGSize

    private var span: Double { Swift.max(0.0001, ceiling - floor) }

    func fraction(_ value: Double) -> Double {
        ((value - floor) / span).clamped(to: 0...1)
    }

    func point(_ index: Int, _ value: Double, count: Int) -> CGPoint {
        let x = count > 1 ? size.width * CGFloat(index) / CGFloat(count - 1) : size.width
        return CGPoint(x: x, y: size.height * (1 - CGFloat(fraction(value))))
    }

    func height(_ value: Double) -> CGFloat {
        size.height * CGFloat(fraction(value))
    }
}

private func autoCeiling(_ plots: [Plot], floor: Double = 1) -> Double {
    let peak = plots.flatMap(\.values).max() ?? 0
    return peak > 0 ? peak * 1.08 : floor
}

// MARK: - History graph

/// The workhorse: one or more series over the retention window, drawn the way
/// the module is configured. This is the shape iStat Menus puts at the top of
/// every dropdown.
struct HistoryGraph: View {
    var plots: [Plot]
    var shape: GraphShape = .area
    var ceiling: Double?
    /// Bottom of the value range. Leave at zero unless the series never goes
    /// near zero, as a temperature does not.
    var floor: Double = 0
    var height: CGFloat = 58
    var appearance: GraphAppearance?
    /// Horizontal rules behind the plot, as a fraction of the ceiling.
    var gridLines: [Double] = [0.25, 0.5, 0.75]
    var showsGrid = true

    private var style: GraphAppearance { appearance ?? GraphAppearance(primaryHex: "#0A84FF") }
    private var resolvedCeiling: Double { ceiling ?? autoCeiling(plots) }

    var body: some View {
        Canvas { context, size in
            let scale = Scale(ceiling: resolvedCeiling, floor: floor, size: size)

            if showsGrid, shape != .mirrored { drawGrid(context, size) }

            switch shape {
            case .area, .line, .columns:
                for plot in plots { draw(plot, shape: shape, scale: scale, in: context, size: size) }
            case .stacked:
                drawStacked(context, scale: scale, size: size)
            case .mirrored:
                drawMirrored(context, size: size)
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: Pieces

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        for fraction in gridLines {
            let y = size.height * (1 - CGFloat(fraction))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
        }
    }

    private func draw(_ plot: Plot, shape: GraphShape,
                      scale: Scale, in context: GraphicsContext, size: CGSize) {
        guard plot.values.count > 1 else { return }

        if shape == .columns {
            // One column per sample, with a hairline gap so they stay legible.
            let step = size.width / CGFloat(plot.values.count)
            let width = max(1, step - 1)
            for (index, value) in plot.values.enumerated() {
                let barHeight = scale.height(value)
                guard barHeight > 0.5 else { continue }
                let rect = CGRect(x: CGFloat(index) * step, y: size.height - barHeight,
                                  width: width, height: barHeight)
                context.fill(Path(rect), with: .color(plot.color.opacity(style.fadeOpacity + 0.35)))
            }
            return
        }

        let line = linePath(plot.values, scale: scale)
        if shape == .area, style.fade != .outline {
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: fillShading(plot.color, size: size))
        }
        if style.showsLine || shape == .line {
            context.stroke(line, with: .color(plot.color), lineWidth: 1.4)
        }
    }

    private func drawStacked(_ context: GraphicsContext, scale: Scale, size: CGSize) {
        guard let count = plots.first?.values.count, count > 1 else { return }

        // Accumulate upwards so each band sits on the one below it.
        var lower = [Double](repeating: 0, count: count)
        for plot in plots {
            var upper = lower
            for index in 0..<min(count, plot.values.count) {
                upper[index] = lower[index] + plot.values[index]
            }

            var band = Path()
            band.move(to: scale.point(0, upper[0], count: count))
            for index in 1..<count { band.addLine(to: scale.point(index, upper[index], count: count)) }
            for index in stride(from: count - 1, through: 0, by: -1) {
                band.addLine(to: scale.point(index, lower[index], count: count))
            }
            band.closeSubpath()

            context.fill(band, with: .color(plot.color.opacity(0.75)))
            lower = upper
        }
    }

    private func drawMirrored(_ context: GraphicsContext, size: CGSize) {
        guard plots.count >= 2 else { return }
        let half = CGSize(width: size.width, height: size.height / 2)
        let scale = Scale(ceiling: resolvedCeiling, floor: floor, size: half)

        // Upper half grows up from the middle, lower half grows down — the
        // shape iStat Menus uses for upload against download.
        var top = linePath(plots[0].values, scale: scale)
        top.addLine(to: CGPoint(x: size.width, y: half.height))
        top.addLine(to: CGPoint(x: 0, y: half.height))
        top.closeSubpath()
        context.fill(top, with: .color(plots[0].color.opacity(style.fadeOpacity + 0.2)))
        context.stroke(linePath(plots[0].values, scale: scale), with: .color(plots[0].color), lineWidth: 1.2)

        var bottom = context
        bottom.translateBy(x: 0, y: size.height)
        bottom.scaleBy(x: 1, y: -1)
        var lower = linePath(plots[1].values, scale: scale)
        lower.addLine(to: CGPoint(x: size.width, y: half.height))
        lower.addLine(to: CGPoint(x: 0, y: half.height))
        lower.closeSubpath()
        bottom.fill(lower, with: .color(plots[1].color.opacity(style.fadeOpacity + 0.2)))
        bottom.stroke(linePath(plots[1].values, scale: scale), with: .color(plots[1].color), lineWidth: 1.2)

        var centre = Path()
        centre.move(to: CGPoint(x: 0, y: size.height / 2))
        centre.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(centre, with: .color(.primary.opacity(0.18)), lineWidth: 1)
    }

    private func linePath(_ values: [Double], scale: Scale) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (index, value) in values.enumerated() {
                let point = scale.point(index, value, count: values.count)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }

    private func fillShading(_ color: Color, size: CGSize) -> GraphicsContext.Shading {
        switch style.fade {
        case .gradient:
            .linearGradient(Gradient(colors: [color.opacity(style.fadeOpacity), color.opacity(0.02)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
        case .duotone:
            .linearGradient(Gradient(colors: [color.opacity(style.fadeOpacity),
                                              style.secondary.opacity(style.fadeOpacity * 0.6)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
        case .flat, .outline:
            .color(color.opacity(style.fadeOpacity))
        }
    }
}

// MARK: - Graph section

/// A graph with the title/value header iStat Menus puts above every one.
struct GraphSection<Trailing: View>: View {
    let title: String
    var value: String?
    var valueColor: Color = .primary
    var legend: [(String, Color)] = []
    var caption: String?
    @ViewBuilder var graph: Trailing

    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.5)
                Spacer(minLength: 6)
                if let value {
                    Text(value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(valueColor)
                }
            }

            graph

            if !legend.isEmpty || caption != nil {
                HStack(spacing: 10) {
                    ForEach(legend.indices, id: \.self) { index in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(legend[index].1)
                                .frame(width: 7, height: 7)
                            Text(legend[index].0)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(caption ?? timeSpan)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var timeSpan: String {
        settings.historyMinutes >= 60
            ? "\(settings.historyMinutes / 60) h"
            : "\(settings.historyMinutes) min"
    }
}

extension GraphSection where Trailing == EmptyView {
    init(title: String, value: String? = nil) {
        self.init(title: title, value: value, graph: { EmptyView() })
    }
}

// MARK: - Ring gauge

/// A donut with a value in the middle. Used where a proportion matters more
/// than its history — disk capacity, battery charge.
struct RingGauge: View {
    var fraction: Double
    var color: Color
    var track: Color = .primary.opacity(0.1)
    var lineWidth: CGFloat = 7
    var diameter: CGFloat = 62
    var label: String?
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction.clamped(to: 0...1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if let label {
                    Text(label)
                        .font(.system(size: diameter * 0.24, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: diameter * 0.13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Per-core history grid

/// A miniature history graph for every core, laid out in rows. Bars alone say
/// what a core is doing now; these say what it has been doing.
struct CoreHistoryGrid: View {
    let cores: [CoreLoad]
    let histories: [[Double]]
    var columns: Int = 5
    var color: (CoreLoad) -> Color

    var body: some View {
        let rows = stride(from: 0, to: cores.count, by: columns).map { start in
            Array(cores[start..<min(start + columns, cores.count)])
        }
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(rows[rowIndex]) { core in
                        VStack(spacing: 2) {
                            HistoryGraph(
                                plots: [Plot(values: history(for: core), color: color(core))],
                                shape: .area, ceiling: 1, height: 26,
                                appearance: GraphAppearance(primaryHex: "#0A84FF", fadeOpacity: 0.5),
                                gridLines: [0.5]
                            )
                            Text("\(core.clusterName.isEmpty ? "" : String(core.clusterName.prefix(1)))\(core.id)"
                                 + "  \(Int(core.total * 100))%")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .help("\(core.label): \(Int(core.total * 100))%")
                    }
                    // Keep the last row aligned with the ones above it.
                    if rows[rowIndex].count < columns {
                        ForEach(0..<(columns - rows[rowIndex].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func history(for core: CoreLoad) -> [Double] {
        core.id < histories.count ? histories[core.id] : []
    }
}

// MARK: - Temperature strip

/// Temperature history as a colour band: cool blue through to hot red. Reads
/// at a glance in a way a line does not.
struct HeatStrip: View {
    let values: [Double]
    var range: ClosedRange<Double> = 30...100
    var height: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let fraction = ((value - range.lowerBound) /
                                (range.upperBound - range.lowerBound)).clamped(to: 0...1)
                let rect = CGRect(x: CGFloat(index) * step, y: 0,
                                  width: step + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(Self.color(for: fraction)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    /// Blue → green → yellow → red, interpolated rather than stepped so a
    /// slow warm-up reads as a gradient instead of four bands.
    static func color(for fraction: Double) -> Color {
        // Hue runs from cyan (0.55) down through green and yellow to red (0.0).
        let t = fraction.clamped(to: 0...1)
        let hue = 0.55 * (1 - pow(t, 0.85))
        let saturation = 0.55 + 0.35 * t
        let brightness = 0.8 + 0.15 * t
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

// MARK: - Forecast chart

/// High and low temperatures as a band with a line through the middle.
struct ForecastChart: View {
    let days: [WeatherDay]
    var unit: TemperatureUnit
    var height: CGFloat = 60
    var highColor: Color = .orange
    var lowColor: Color = .blue

    var body: some View {
        Canvas { context, size in
            guard days.count > 1 else { return }
            let highs = days.map(\.high)
            let lows = days.map(\.low)
            let upper = (highs.max() ?? 1) + 1
            let lower = (lows.min() ?? 0) - 1
            let span = max(0.1, upper - lower)

            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat(index) / CGFloat(days.count - 1),
                        y: size.height * CGFloat(1 - (value - lower) / span))
            }

            var band = Path()
            band.move(to: point(0, highs[0]))
            for index in 1..<days.count { band.addLine(to: point(index, highs[index])) }
            for index in stride(from: days.count - 1, through: 0, by: -1) {
                band.addLine(to: point(index, lows[index]))
            }
            band.closeSubpath()
            context.fill(band, with: .linearGradient(
                Gradient(colors: [highColor.opacity(0.35), lowColor.opacity(0.2)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            for (values, color) in [(highs, highColor), (lows, lowColor)] {
                var line = Path()
                for index in values.indices {
                    let location = point(index, values[index])
                    index == 0 ? line.move(to: location) : line.addLine(to: location)
                }
                context.stroke(line, with: .color(color), lineWidth: 1.4)
                for index in values.indices {
                    let location = point(index, values[index])
                    context.fill(Path(ellipseIn: CGRect(x: location.x - 2, y: location.y - 2,
                                                        width: 4, height: 4)),
                                 with: .color(color))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Hourly bars

/// Precipitation chance per hour, as a small column chart.
struct HourlyBars: View {
    let hours: [WeatherHour]
    var color: Color = .blue
    var height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            guard !hours.isEmpty else { return }
            let step = size.width / CGFloat(hours.count)
            for (index, hour) in hours.enumerated() {
                let probability = hour.precipitationProbability ?? 0
                let barHeight = max(1, size.height * CGFloat(probability))
                let rect = CGRect(x: CGFloat(index) * step + 1, y: size.height - barHeight,
                                  width: max(1, step - 2), height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(color.opacity(0.25 + 0.6 * probability)))
            }
        }
        .frame(height: height)
    }
}
