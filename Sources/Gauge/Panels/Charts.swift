// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import GaugeKit

// MARK: - Shared plumbing

/// A named series with its own colour, so one chart can draw several.
struct Plot: Identifiable {
    let id = UUID()
    var values: [Double]
    var color: Color
    var label: String = ""
    /// How a value reads in the hover box. Defaults to a plain number, which
    /// is wrong for bytes and percentages, so callers usually set it.
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    /// False where no sample was recorded — the machine was asleep, or the app
    /// was not running. Those points are left out instead of plotted as zero.
    var defined: [Bool]?

    var latest: Double { values.last ?? 0 }

    init(values: [Double], color: Color, label: String = "",
         format: @escaping (Double) -> String = { String(format: "%.1f", $0) },
         defined: [Bool]? = nil) {
        self.values = values
        self.color = color
        self.label = label
        self.format = format
        self.defined = defined
    }

    func hasValue(at index: Int) -> Bool {
        guard index >= 0, index < values.count else { return false }
        guard let defined, index < defined.count else { return true }
        return defined[index]
    }

    /// Runs of consecutive samples, so a gap breaks the line rather than
    /// dragging it through zero.
    var segments: [Range<Int>] {
        guard let defined else { return values.isEmpty ? [] : [0..<values.count] }
        var result: [Range<Int>] = []
        var start: Int?
        for index in values.indices {
            let present = index < defined.count ? defined[index] : true
            if present, start == nil { start = index }
            if !present, let begin = start {
                if index - begin > 1 { result.append(begin..<index) }
                start = nil
            }
        }
        if let begin = start, values.count - begin > 1 { result.append(begin..<values.count) }
        return result
    }
}

/// Where a chart's samples sit in time, so hovering can name the moment.
struct ChartTimeline {
    var start: Date
    var interval: TimeInterval
    var count: Int

    func date(at index: Int) -> Date {
        start.addingTimeInterval(interval * (Double(index) + 0.5))
    }

    /// "14:32" for anything inside a day, "Tue 14:32" beyond that.
    func label(at index: Int) -> String {
        let date = self.date(at: index)
        let formatter = DateFormatter()
        formatter.locale = .current
        let span = interval * Double(max(1, count))
        formatter.dateFormat = span > 86_400 ? "d MMM HH:mm" : (span > 3_600 ? "HH:mm" : "HH:mm:ss")
        return formatter.string(from: date)
    }

    /// How long ago that sample was, which is often what the reader wants.
    func ago(at index: Int) -> String {
        let seconds = Date().timeIntervalSince(date(at: index))
        guard seconds > 1 else { return "now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        if seconds < 5_400 { return "\(Int(seconds / 60))m ago" }
        if seconds < 172_800 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
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
/// the module is configured. Every dropdown opens with one of these.
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
    /// Supplying this turns on the hover crosshair and its readout.
    var timeline: ChartTimeline?
    /// Only used by `--preview`, which has no pointer to hover with.
    var previewHover: CGPoint?

    @StateObject private var hover = UIState<CGPoint?>(nil)

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
        .overlay { crosshair }
        .onAppear { if let previewHover { hover.value = previewHover } }
        .onContinuousHover { phase in
            guard timeline != nil else { return }
            switch phase {
            case .active(let location): hover.value = location
            case .ended: hover.value = nil
            }
        }
    }

    // MARK: Hover

    private var sampleCount: Int {
        plots.map(\.values.count).max() ?? 0
    }

    /// A vertical rule, a dot on each series and a floating readout, drawn
    /// only while the pointer is over the plot.
    @ViewBuilder
    private var crosshair: some View {
        GeometryReader { geometry in
            if let location = hover.value, let timeline, sampleCount > 1 {
                let count = sampleCount
                let step = geometry.size.width / CGFloat(count - 1)
                let index = Int((location.x / max(step, 0.001)).rounded())
                    .clamped(to: 0...(count - 1))
                let x = step * CGFloat(index)

                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                .stroke(Color.primary.opacity(0.35), lineWidth: 1)

                ForEach(plots) { plot in
                    if plot.hasValue(at: index) {
                        let fraction = ((plot.values[index] - floor) /
                                        max(0.0001, resolvedCeiling - floor)).clamped(to: 0...1)
                        Circle()
                            .fill(plot.color)
                            .frame(width: 5, height: 5)
                            .position(x: x, y: geometry.size.height * (1 - fraction))
                    }
                }

                readout(index: index, timeline: timeline, at: x, in: geometry.size)
            }
        }
    }

    private func readout(index: Int, timeline: ChartTimeline,
                         at x: CGFloat, in size: CGSize) -> some View {
        let box = VStack(alignment: .leading, spacing: 1) {
            Text("\(timeline.label(at: index))  ·  \(timeline.ago(at: index))")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            ForEach(plots) { plot in
                if index < plot.values.count {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(plot.color)
                            .frame(width: 6, height: 6)
                        if !plot.label.isEmpty {
                            Text(plot.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text(plot.hasValue(at: index) ? plot.format(plot.values[index]) : "no data")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(plot.hasValue(at: index) ? .primary : .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        )
        .fixedSize()

        // Keep the box inside the plot: flip it to the left near the right edge.
        let width: CGFloat = 96
        let alignsLeft = x < size.width - width - 8
        return box
            .offset(x: alignsLeft ? x + 8 : x - width - 8, y: 4)
            .allowsHitTesting(false)
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
                guard plot.hasValue(at: index) else { continue }
                let barHeight = scale.height(value)
                guard barHeight > 0.5 else { continue }
                let rect = CGRect(x: CGFloat(index) * step, y: size.height - barHeight,
                                  width: width, height: barHeight)
                context.fill(Path(rect), with: .color(plot.color.opacity(style.fadeOpacity + 0.35)))
            }
            return
        }

        let segments = plot.segments
        guard !segments.isEmpty else { return }

        if shape == .area, style.fade != .outline {
            var area = Path()
            for segment in segments {
                let count = plot.values.count
                area.move(to: CGPoint(x: scale.point(segment.lowerBound, 0, count: count).x,
                                      y: size.height))
                for index in segment {
                    area.addLine(to: scale.point(index, plot.values[index], count: count))
                }
                area.addLine(to: CGPoint(x: scale.point(segment.upperBound - 1, 0, count: count).x,
                                         y: size.height))
                area.closeSubpath()
            }
            context.fill(area, with: fillShading(plot.color, size: size))
        }
        if style.showsLine || shape == .line {
            var line = Path()
            for segment in segments {
                for (offset, index) in segment.enumerated() {
                    let point = scale.point(index, plot.values[index], count: plot.values.count)
                    offset == 0 ? line.move(to: point) : line.addLine(to: point)
                }
            }
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

        // Upper half grows up from the middle, lower half grows down, which
        // is the only way to read a duplex rate without two charts.
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

/// A graph with a title on the left and its current value on the right.
struct GraphSection<Trailing: View>: View {
    let title: String
    var value: String?
    var valueColor: Color = .primary
    var legend: [(String, Color)] = []
    var caption: String?
    /// Identifier for the range menu. Omit it and no menu is shown.
    var chart: String?
    @ViewBuilder var graph: Trailing

    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.5)
                if let chart { RangeMenu(chart: chart) }
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

/// The time-range picker that sits next to a graph's title.
struct RangeMenu: View {
    let chart: String
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        Menu {
            ForEach(HistoryRange.allCases) { range in
                Button {
                    settings.setChartRange(chart, range)
                } label: {
                    if settings.chartRange(chart) == range {
                        Label(range.title, systemImage: "checkmark")
                    } else {
                        Text(range.title)
                    }
                }
            }
            Divider()
            Button("Use default (\(settings.defaultChartRange.short))") {
                settings.chartRanges[chart] = nil
            }
        } label: {
            // The borderless menu style draws its own indicator ahead of the
            // label, so the label is just the range.
            Text(settings.chartRange(chart).short)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .fixedSize()
        .help("Time range for this graph")
    }
}

/// A history graph wired to the long-term store: it reads its own range from
/// settings, fetches the matching resolution, and carries the timeline the
/// hover readout needs.
struct MetricChart: View {
    struct Source {
        var metric: String
        var color: Color
        var label: String = ""
        var format: (Double) -> String = { String(format: "%.1f", $0) }
    }

    let chart: String
    let title: String
    var sources: [Source]
    var shape: GraphShape = .area
    var ceiling: Double?
    var floorValue: Double = 0
    /// Scale to the tallest sample in the window instead of a fixed ceiling.
    var autoScale = false
    var height: CGFloat = 56
    var appearance: GraphAppearance
    var value: String?
    var valueColor: Color = .primary
    var showsLegend = true
    var caption: String?
    var gridLines: [Double] = [0.25, 0.5, 0.75]

    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let range = settings.chartRange(chart)
        let series = sources.map { hub.series($0.metric, range: range) }
        let timeline = series.first.map {
            ChartTimeline(start: $0.start, interval: $0.interval, count: $0.buckets.count)
        }
        let plots = zip(sources, series).map { source, data in
            Plot(values: data.averages, color: source.color,
                 label: source.label, format: source.format,
                 defined: data.buckets.map { !$0.isEmpty })
        }

        GraphSection(
            title: title,
            value: value,
            valueColor: valueColor,
            legend: showsLegend && sources.count > 1
                ? sources.map { ($0.label, $0.color) } : [],
            caption: caption ?? peakCaption(series),
            chart: chart
        ) {
            HistoryGraph(
                plots: plots,
                shape: shape,
                ceiling: autoScale ? nil : ceiling,
                floor: floorValue,
                height: height,
                appearance: appearance,
                gridLines: gridLines,
                timeline: timeline
            )
        }
    }

    /// The window's peak is the number people look for after the current
    /// value. A stacked chart's peak is the tallest total, not the tallest
    /// single band, which would read as far too low.
    private func peakCaption(_ series: [HistorySeries]) -> String? {
        guard let format = sources.first?.format else { return nil }

        let peak: Double
        if shape == .stacked, series.count > 1 {
            let length = series.map(\.buckets.count).min() ?? 0
            peak = (0..<length).reduce(0.0) { best, index in
                max(best, series.reduce(0) { $0 + $1.buckets[index].maximum })
            }
        } else {
            peak = series.map(\.peak).max() ?? 0
        }
        guard peak > 0 else { return nil }
        return "peak \(format(peak))"
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
