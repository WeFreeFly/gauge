import SwiftUI
import GaugeKit

struct WeatherPanel: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        Panel(width: 320) {
            if !settings.weatherEnabled {
                disabledState
            } else if let report = hub.weather {
                forecast(report)
            } else {
                pendingState
            }

            PanelFooter(
                onSettings: { SettingsWindowController.shared.show(hub: hub, selecting: .weather) },
                extraLabel: settings.weatherEnabled ? "Refresh" : nil,
                extraAction: settings.weatherEnabled ? { hub.refreshWeather(force: true) } : nil
            )
        }
    }

    // MARK: States

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Weather", subtitle: "Turned off", symbol: "cloud.slash")
            Text("""
                 Weather is the only part of Gauge that needs an outside service, \
                 and it sends your chosen coordinates to reach it. Everything else \
                 the app shows is read from this Mac.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up weather…") {
                SettingsWindowController.shared.show(hub: hub, selecting: .weather)
            }
            .controlSize(.small)
        }
    }

    private var pendingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "Weather",
                        subtitle: settings.weatherLocation?.name ?? "No location",
                        symbol: "cloud.sun")
            if let error = hub.weatherError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func forecast(_ report: WeatherReport) -> some View {
        let unit = settings.temperatureUnit

        PanelHeader(title: report.location.name,
                    subtitle: [report.location.country, report.now.condition.text]
                        .compactMap { $0 }.joined(separator: " · "),
                    symbol: report.now.condition.symbolName)

        let look = settings.graph(.weather)

        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.temperature(report.now.temperature, unit: unit))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                if let feels = report.now.feelsLike {
                    Text("Feels like \(Format.temperature(feels, unit: unit))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: report.now.condition.symbolName)
                .font(.system(size: 34))
                .symbolRenderingMode(.multicolor)
        }

        if report.daily.count > 1 {
            GraphSection(title: "7-day range",
                         value: "\(Format.temperature(report.daily.map(\.low).min() ?? 0, unit: unit))"
                              + "–\(Format.temperature(report.daily.map(\.high).max() ?? 0, unit: unit))",
                         legend: [("High", look.secondary), ("Low", look.primary)],
                         caption: " ") {
                ForecastChart(days: report.daily, unit: unit,
                              highColor: look.secondary, lowColor: look.primary)
            }
        }

        VStack(spacing: 2) {
            if let humidity = report.now.humidity {
                StatRow(label: "Humidity", value: Format.percent(humidity))
            }
            if let wind = report.now.windSpeed {
                let direction = report.now.windDirection.map { " \(compass($0))" } ?? ""
                StatRow(label: "Wind", value: String(format: "%.0f km/h", wind) + direction)
            }
            if let pressure = report.now.pressure {
                StatRow(label: "Pressure", value: String(format: "%.0f hPa", pressure))
            }
            if let uv = report.now.uvIndex {
                StatRow(label: "UV index", value: String(format: "%.0f", uv))
            }
            if let precipitation = report.now.precipitation, precipitation > 0 {
                StatRow(label: "Precipitation", value: String(format: "%.1f mm", precipitation))
            }
        }

        if !report.hourly.isEmpty {
            Divider()
            let hours = Array(report.hourly.prefix(12))
            GraphSection(title: "Next 12 hours",
                         value: "\(Format.temperature(hours.map(\.temperature).min() ?? 0, unit: unit))"
                              + "–\(Format.temperature(hours.map(\.temperature).max() ?? 0, unit: unit))",
                         caption: "bars show chance of rain") {
                VStack(spacing: 3) {
                    HistoryGraph(
                        plots: [Plot(values: hours.map(\.temperature), color: look.secondary)],
                        shape: .area,
                        ceiling: (hours.map(\.temperature).max() ?? 30) + 1,
                        floor: (hours.map(\.temperature).min() ?? 20) - 2,
                        height: 38,
                        appearance: look,
                        gridLines: [0.5]
                    )
                    HourlyBars(hours: hours, color: look.primary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(hours) { hour in
                        VStack(spacing: 3) {
                            Text(hour.date, format: .dateTime.hour())
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Image(systemName: hour.condition.symbolName)
                                .font(.system(size: 12))
                                .symbolRenderingMode(.multicolor)
                            Text(Format.temperature(hour.temperature, unit: unit))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }

        if !report.daily.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Forecast")
                ForEach(report.daily.prefix(7)) { day in
                    HStack(spacing: 8) {
                        Text(day.date, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 11))
                            .frame(width: 34, alignment: .leading)
                        Image(systemName: day.condition.symbolName)
                            .font(.system(size: 10))
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 16)
                        if let probability = day.precipitationProbability, probability > 0.05 {
                            Text(Format.percent(probability))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.blue)
                                .frame(width: 28, alignment: .leading)
                        } else {
                            Spacer().frame(width: 28)
                        }
                        Spacer(minLength: 0)
                        Text(Format.temperature(day.low, unit: unit))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(Format.temperature(day.high, unit: unit))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
            }
        }

        HStack(spacing: 4) {
            if hub.isRefreshingWeather {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Text("\(report.attribution) · updated \(report.fetchedAt, format: .dateTime.hour().minute())")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    private func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % points.count
        return points[max(0, index)]
    }
}
