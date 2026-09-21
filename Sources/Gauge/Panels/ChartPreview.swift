import SwiftUI
import GaugeKit

/// A sheet of every chart type with the hover readout switched on.
///
/// The crosshair only appears under a real pointer, which an offscreen render
/// does not have, so this seeds it — otherwise the one interactive part of the
/// charts could never be reviewed from a build.
struct ChartGallery: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    private var timeline: ChartTimeline {
        let series = hub.series(MonitorHub.Metric.cpu, range: .h1)
        return ChartTimeline(start: series.start, interval: series.interval,
                             count: series.buckets.count)
    }

    var body: some View {
        let look = settings.graph(.cpu)
        let network = settings.graph(.network)
        let cpu = hub.series(MonitorHub.Metric.cpu, range: .h1).averages
        let user = hub.series(MonitorHub.Metric.cpuUser, range: .h1).averages
        let system = hub.series(MonitorHub.Metric.cpuSystem, range: .h1).averages
        let down = hub.series(MonitorHub.Metric.networkDown, range: .h1).averages
        let up = hub.series(MonitorHub.Metric.networkUp, range: .h1).averages

        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(GraphShape.allCases.enumerated()), id: \.offset) { index, shape in
                VStack(alignment: .leading, spacing: 4) {
                    Text(shape.title.uppercased() + (index == 0 ? "  ·  hover readout shown" : ""))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    HistoryGraph(
                        plots: shape == .mirrored
                            ? [Plot(values: down, color: network.primary, label: "Down",
                                    format: { Format.rate($0) }),
                               Plot(values: up, color: network.secondary, label: "Up",
                                    format: { Format.rate($0) })]
                            : (shape == .stacked
                               ? [Plot(values: user, color: look.primary, label: "User",
                                       format: { Format.percent($0, decimals: 1) }),
                                  Plot(values: system, color: look.secondary, label: "System",
                                       format: { Format.percent($0, decimals: 1) })]
                               : [Plot(values: cpu, color: look.primary, label: "CPU",
                                       format: { Format.percent($0, decimals: 1) })]),
                        shape: shape,
                        ceiling: shape == .mirrored ? nil : 1,
                        height: 56,
                        appearance: look,
                        timeline: timeline,
                        // Park the crosshair a third of the way in.
                        previewHover: CGPoint(x: 96, y: 20)
                    )
                }
            }

            HStack(spacing: 16) {
                RingGauge(fraction: 0.62, color: look.primary, label: "62%", caption: "ring")
                VStack(alignment: .leading, spacing: 4) {
                    Text("HEAT STRIP").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    HeatStrip(values: hub.series(MonitorHub.Metric.temperature, range: .h1).averages)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
