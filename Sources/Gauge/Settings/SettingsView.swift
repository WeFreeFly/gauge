import SwiftUI
import ServiceManagement
import GaugeKit

enum SettingsSection: Hashable {
    case general
    case appearance
    case module(ModuleID)
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .module(let module): module.title
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .module(let module): module.symbolName
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    let initialSelection: SettingsSection?
    @EnvironmentObject private var settings: GaugeSettings
    @EnvironmentObject private var hub: MonitorHub
    @StateObject private var selectionState = UIState(SettingsSection.general)

    private static let sections: [SettingsSection] =
        [.general, .appearance] + ModuleID.allCases.map { .module($0) } + [.about]

    var body: some View {
        NavigationSplitView {
            List(Self.sections, id: \.self, selection: $selectionState.value) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detail
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if let initialSelection { selectionState.value = initialSelection } }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectionState.value {
        case .general:
            GeneralSettings()
        case .appearance:
            AppearanceSettingsPage()
        case .module(let module):
            ModuleSettingsView(module: module)
        case .about:
            AboutSettings()
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var loginItemError = UIState<String?>(nil)

    var body: some View {
        SettingsGroup("Sampling") {
            LabeledContent("Update every") {
                HStack {
                    Slider(value: $settings.updateInterval, in: 0.5...10, step: 0.5)
                        .frame(width: 200)
                    Text(String(format: "%.1f s", settings.updateInterval))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text("Faster sampling costs a little CPU of its own. Two seconds is a good balance.")
                .settingsFootnote()

            LabeledContent("Menu bar graph window") {
                Picker("", selection: $settings.historyMinutes) {
                    ForEach([5, 10, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Text("How much history the small graphs in the menu bar show.")
                .settingsFootnote()
        }

        SettingsGroup("Chart history") {
            LabeledContent("Default range") {
                Picker("", selection: $settings.defaultChartRange) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Text("Each graph has its own range menu next to its title; this is what "
               + "they use until one is chosen. Ranges beyond an hour come from history "
               + "kept on disk, so they fill in as the app keeps running.")
                .settingsFootnote()

            HStack {
                Button("Reset every graph to the default") { settings.resetChartRanges() }
                    .controlSize(.small)
                Spacer()
            }

            Text("Stored at three resolutions: two seconds for the last hour, one minute "
               + "for a day, fifteen minutes out to four weeks — about 2.5 MB in total.")
                .settingsFootnote()
        }

        SettingsGroup("Units") {
            Picker("Temperature", selection: $settings.temperatureUnit) {
                ForEach(TemperatureUnit.allCases, id: \.self) {
                    Text($0 == .celsius ? "Celsius" : "Fahrenheit").tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Toggle("Show network speeds in bits per second", isOn: $settings.networkUnitBits)
            Toggle("Show a per-core graph in the CPU panel", isOn: $settings.showPerCoreGraph)
        }

        SettingsGroup("Startup") {
            Toggle("Open Gauge at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let message = loginItemError.value {
                Text(message).settingsFootnote().foregroundStyle(.orange)
            } else {
                Text("Uses the system login item service, so it appears in System Settings › General › Login Items.")
                    .settingsFootnote()
            }
        }
    }

    /// Registration only works for a real app bundle; a bare binary run from
    /// the build directory will fail here, which is worth saying out loud.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            loginItemError.value = nil
        } catch {
            loginItemError.value = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}

// MARK: - Per module

struct ModuleSettingsView: View {
    let module: ModuleID
    @EnvironmentObject private var settings: GaugeSettings
    @EnvironmentObject private var hub: MonitorHub

    var body: some View {
        SettingsGroup(module.title) {
            Toggle("Show \(module.title) in the menu bar", isOn: Binding(
                get: { settings.module(module).enabled },
                set: { value in settings.setModule(module) { $0.enabled = value } }
            ))

            Picker("Display as", selection: Binding(
                get: { settings.module(module).style },
                set: { value in settings.setModule(module) { $0.style = value } }
            )) {
                ForEach(MenubarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 260)
            .disabled(!settings.module(module).enabled)
        }

        SettingsGroup("Colours") {
            GraphAppearanceEditor(module: module)
        }

        switch module {
        case .network: NetworkSettings()
        case .weather: WeatherSettings()
        case .time:    TimeSettings()
        case .sensors: SensorSettings()
        default:       EmptyView()
        }
    }
}

struct NetworkSettings: View {
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        SettingsGroup("Public address") {
            Toggle("Look up this Mac's public IP address", isOn: $settings.publicIPEnabled)
            Text("""
                 Off by default. When on, Gauge asks the service below for your address \
                 at most every 15 minutes; that service necessarily sees the request.
                 """)
                .settingsFootnote()

            LabeledContent("IPv4 endpoint") {
                TextField("", text: $settings.publicIPEndpointV4)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .disabled(!settings.publicIPEnabled)

            LabeledContent("IPv6 endpoint") {
                TextField("", text: $settings.publicIPEndpointV6)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .disabled(!settings.publicIPEnabled)
        }
    }
}

struct SensorSettings: View {
    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        SettingsGroup("Menu bar readings") {
            SensorMenubarPicker(style: .full)
        }

        SettingsGroup("Which sensors are the CPU?") {
            Text("Apple does not document what a sensor named \"PMU tdie7\" measures. "
               + "Gauge can find out by loading one core cluster at a time and watching "
               + "where the heat appears: a sensor over the fast cluster warms further "
               + "when that cluster is busy.")
                .settingsFootnote()

            if let progress = hub.calibrationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 320)
                    HStack {
                        Text(progress.stage).font(.system(size: 11))
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Cancel") { hub.cancelCalibration() }
                            .controlSize(.small)
                    }
                    .frame(width: 320)
                    Text("The machine is deliberately busy while this runs.")
                        .settingsFootnote()
                }
            } else if let calibration = settings.sensorCalibration {
                HStack {
                    Label("Calibrated \(calibration.measuredAt.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "checkmark.seal")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Run again") { hub.calibrateSensors() }
                        .controlSize(.small)
                    Button("Clear") { hub.clearCalibration() }
                        .controlSize(.small)
                }

                CalibrationResults(calibration: calibration)
            } else {
                HStack {
                    Button("Calibrate sensors…") { hub.calibrateSensors() }
                    Text("About two minutes, under full load.")
                        .settingsFootnote()
                }
            }
        }

        SettingsGroup("Available sensors") {
            Text("\(hub.snapshot.sensors.readings.count) readings on this Mac, grouped by where they sit.")
                .settingsFootnote()
            ForEach(hub.snapshot.sensors.grouped, id: \.group) { entry in
                DisclosureGroup("\(entry.group.rawValue) (\(entry.readings.count))") {
                    ForEach(entry.readings) { reading in
                        HStack {
                            Text(reading.name).font(.system(size: 11))
                            Spacer()
                            Text(reading.formatted(temperatureUnit: hub.settings.temperatureUnit))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}

struct TimeSettings: View {
    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var newZone = UIState("")

    private let commonFormats = ["HH:mm", "HH:mm:ss", "h:mm a", "EEE HH:mm", "d MMM HH:mm"]

    var body: some View {
        SettingsGroup("Clock") {
            Picker("Menu bar format", selection: $settings.timeFormat) {
                ForEach(commonFormats, id: \.self) { format in
                    Text(preview(format)).tag(format)
                }
            }
            .frame(width: 300)
        }

        SettingsGroup("World clocks") {
            ForEach(settings.timeZones, id: \.self) { identifier in
                HStack {
                    Text(identifier).font(.system(size: 11))
                    Spacer()
                    if identifier != TimeZone.current.identifier {
                        Button("Remove") {
                            settings.timeZones.removeAll { $0 == identifier }
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Picker("Add", selection: $newZone.value) {
                    Text("Choose…").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter { !settings.timeZones.contains($0) }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .frame(width: 300)
                Button("Add") {
                    guard !newZone.value.isEmpty else { return }
                    settings.timeZones.append(newZone.value)
                    newZone.value = ""
                }
                .disabled(newZone.value.isEmpty)
            }
        }
    }

    private func preview(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return "\(formatter.string(from: Date()))   (\(format))"
    }
}

// MARK: - Weather

/// The weather form carries enough local state to be worth its own model.
final class WeatherFormModel: ObservableObject {
    @Published var apiKey: String
    @Published var query = ""
    @Published var results: [GeocodeResult] = []
    @Published var isSearching = false

    init() {
        apiKey = Keychain.get(Keychain.accuWeatherKey) ?? ""
    }
}

struct WeatherSettings: View {
    @EnvironmentObject private var settings: GaugeSettings
    @EnvironmentObject private var hub: MonitorHub
    @StateObject private var form = WeatherFormModel()

    var body: some View {
        SettingsGroup("Weather service") {
            Toggle("Enable weather", isOn: $settings.weatherEnabled)
            Text("""
                 This is the only feature that contacts a server. Everything else in \
                 Gauge is read from this Mac and never leaves it.
                 """)
                .settingsFootnote()

            Picker("Provider", selection: $settings.weatherProvider) {
                ForEach(WeatherProviderID.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 340)
            .disabled(!settings.weatherEnabled)

            if settings.weatherProvider == .accuWeather {
                LabeledContent("API key") {
                    SecureField("AccuWeather API key", text: $form.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { Keychain.set(form.apiKey, for: Keychain.accuWeatherKey) }
                }
                HStack {
                    Button("Save key") {
                        Keychain.set(form.apiKey, for: Keychain.accuWeatherKey)
                        hub.refreshWeather(force: true)
                    }
                    .controlSize(.small)
                    Text("Stored in the login keychain, not in preferences.").settingsFootnote()
                }
            }

            LabeledContent("Refresh every") {
                Picker("", selection: $settings.weatherRefreshMinutes) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .disabled(!settings.weatherEnabled)
        }

        SettingsGroup("Location") {
            if let location = settings.weatherLocation {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.name).font(.system(size: 12, weight: .medium))
                        Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") { settings.weatherLocation = nil }
                        .controlSize(.small)
                }
            } else {
                Text("No location set.").settingsFootnote()
            }

            HStack {
                TextField("Search for a city", text: $form.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(form.query.trimmingCharacters(in: .whitespaces).isEmpty || form.isSearching)
                if form.isSearching { ProgressView().controlSize(.small) }
            }

            ForEach(form.results) { result in
                HStack {
                    Text(result.displayName).font(.system(size: 11))
                    Spacer()
                    Button("Use") {
                        settings.weatherLocation = WeatherLocation(
                            name: result.name,
                            latitude: result.latitude,
                            longitude: result.longitude,
                            country: result.country,
                            timezone: result.timezone,
                            providerKey: result.providerKey
                        )
                        form.results = []
                        form.query = ""
                    }
                    .controlSize(.small)
                }
            }

            Text("Coordinates are the only thing sent to the provider. Gauge does not ask for your device location.")
                .settingsFootnote()
        }
    }

    private func search() {
        let trimmed = form.query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        form.isSearching = true
        Task {
            let found = await hub.searchLocations(trimmed)
            await MainActor.run {
                form.results = found
                form.isSearching = false
            }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject private var hub: MonitorHub

    var body: some View {
        SettingsGroup("Gauge \(GaugeVersion.string)") {
            HStack(alignment: .top, spacing: 12) {
                if let icon = Self.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gauge \(GaugeVersion.string)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(GaugeVersion.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(GaugeVersion.author)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 3)
                    Link(GaugeVersion.authorEmail,
                         destination: URL(string: "mailto:\(GaugeVersion.authorEmail)")!)
                        .font(.system(size: 11))
                    Text(GaugeVersion.builtWith)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("Quit Gauge") { NSApp.terminate(nil) }
                    .controlSize(.small)
                Spacer()
            }
            .padding(.top, 2)
        }

        SettingsGroup("This Mac") {
            LabeledContent("Model", value: hub.hardware.modelIdentifier)
            LabeledContent("Chip", value: hub.hardware.chip)
            LabeledContent("Cores",
                           value: "\(hub.hardware.coreCount) "
                                + "(\(hub.hardware.performanceCores) \(hub.performanceClusterName)"
                                + " + \(hub.hardware.efficiencyCores) \(hub.efficiencyClusterName))")
            LabeledContent("Memory", value: Format.bytes(hub.hardware.memoryBytes))
            LabeledContent("macOS", value: hub.hardware.osVersion)
        }

        SettingsGroup("Where the numbers come from") {
            sourceRow("CPU, memory, processes", "Mach host statistics and libproc")
            sourceRow("GPU", "IOAccelerator performance statistics")
            sourceRow("Disks", "IOBlockStorageDriver counters and volume capacities")
            sourceRow("Network", "Kernel routing-socket interface counters")
            sourceRow("Temperatures", "IOHID sensor services (Apple Silicon) or SMC keys (Intel)")
            sourceRow("Fans and power", "SMC keys read through a local IOKit connection")
            sourceRow("Battery", "IOPowerSources, AppleSmartBattery and the SMC gas gauge")
            sourceRow("Weather", "Open-Meteo or AccuWeather, only when enabled")
        }
    }

    /// The bundle's own icon. `NSApp.applicationIconImage` returns a generic
    /// placeholder when the process is not running from a bundle, which is how
    /// the preview renderer runs.
    private static var appIcon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    private func sourceRow(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 180, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared chrome

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
        }
    }
}

/// The measured response of every sensor, strongest first.
struct CalibrationResults: View {
    let calibration: SensorCalibration

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("SENSOR").frame(width: 112, alignment: .leading)
                Text("IDLE").frame(width: 42, alignment: .trailing)
                Text("D-" + calibration.efficiencyClusterName.prefix(3).uppercased())
                    .frame(width: 50, alignment: .trailing)
                Text("D-" + calibration.performanceClusterName.prefix(3).uppercased())
                    .frame(width: 50, alignment: .trailing)
                Text("VERDICT").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)

            ForEach(calibration.responses.sorted { $0.response > $1.response }) { response in
                HStack(spacing: 8) {
                    Text(SensorMonitor.displayName(forSensorNamed: response.sensor))
                        .frame(width: 112, alignment: .leading)
                        .lineLimit(1)
                    Text(String(format: "%.0f°", response.idle))
                        .frame(width: 42, alignment: .trailing)
                    Text(String(format: "%+.1f", response.deltaEfficiency))
                        .frame(width: 50, alignment: .trailing)
                    Text(String(format: "%+.1f", response.deltaPerformance))
                        .frame(width: 50, alignment: .trailing)
                    Text(verdict(response))
                        .foregroundStyle(color(response.affinity))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 10, design: .monospaced))
            }

            Text("Heat spreads across a die, so every sensor on it responds to both "
               + "clusters. The split above is by which one moves it more — it is an "
               + "affinity, not a per-core mapping.")
                .settingsFootnote()
                .padding(.top, 4)
        }
    }

    private func verdict(_ response: SensorResponse) -> String {
        switch response.affinity {
        case .performance: calibration.performanceClusterName + " area"
        case .efficiency: calibration.efficiencyClusterName + " area"
        case .shared: "shared die"
        case .unrelated: "not CPU"
        }
    }

    private func color(_ affinity: SensorAffinity) -> Color {
        switch affinity {
        case .performance: .blue
        case .efficiency: .teal
        case .shared: .secondary
        case .unrelated: Color.secondary.opacity(0.6)
        }
    }
}

extension View {
    func settingsFootnote() -> some View {
        font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
