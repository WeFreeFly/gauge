import Foundation
import Combine

public enum ModuleID: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disks, network, sensors, battery, time, weather, combined

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disks: "Disks"
        case .network: "Network"
        case .sensors: "Sensors"
        case .battery: "Battery"
        case .time: "Time"
        case .weather: "Weather"
        case .combined: "Combined"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .disks: "internaldrive"
        case .network: "network"
        case .sensors: "thermometer.medium"
        case .battery: "battery.75percent"
        case .time: "clock"
        case .weather: "cloud.sun"
        case .combined: "square.grid.2x2"
        }
    }
}

/// How a module draws itself in the menu bar.
public enum MenubarStyle: String, Codable, CaseIterable, Sendable {
    case text, graph, textAndGraph, gauge, icon

    public var title: String {
        switch self {
        case .text: "Text"
        case .graph: "Graph"
        case .textAndGraph: "Text + Graph"
        case .gauge: "Gauge"
        case .icon: "Icon only"
        }
    }
}

public enum WeatherProviderID: String, Codable, CaseIterable, Sendable {
    case openMeteo, accuWeather

    public var title: String {
        switch self {
        case .openMeteo: "Open-Meteo (no account)"
        case .accuWeather: "AccuWeather (API key)"
        }
    }

    public var requiresKey: Bool { self == .accuWeather }
}

public struct WeatherLocation: Codable, Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var country: String?
    public var timezone: String?
    /// AccuWeather addresses places by its own key rather than coordinates.
    public var providerKey: String?

    public init(name: String, latitude: Double, longitude: Double,
                country: String? = nil, timezone: String? = nil, providerKey: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
        self.timezone = timezone
        self.providerKey = providerKey
    }
}

public struct ModuleSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var style: MenubarStyle
    public var order: Int

    public init(enabled: Bool, style: MenubarStyle = .text, order: Int = 0) {
        self.enabled = enabled
        self.style = style
        self.order = order
    }
}

/// Everything the user can change. Persisted as one JSON blob so adding a field
/// never needs a migration step.
public final class GaugeSettings: ObservableObject, @unchecked Sendable {
    public static let shared = GaugeSettings()

    private static let defaultsKey = "settings.v1"
    private let defaults: UserDefaults
    private var saveTask: AnyCancellable?

    // MARK: Stored state

    @Published public var modules: [ModuleID: ModuleSettings] {
        didSet { scheduleSave() }
    }
    @Published public var updateInterval: TimeInterval { didSet { scheduleSave() } }
    @Published public var temperatureUnit: TemperatureUnit { didSet { scheduleSave() } }
    @Published public var historyMinutes: Int { didSet { scheduleSave() } }
    /// Range each chart is showing, keyed by chart id. Charts fall back to
    /// `defaultChartRange` until they are changed.
    @Published public var chartRanges: [String: HistoryRange] { didSet { scheduleSave() } }
    @Published public var defaultChartRange: HistoryRange { didSet { scheduleSave() } }
    @Published public var showPerCoreGraph: Bool { didSet { scheduleSave() } }
    @Published public var networkUnitBits: Bool { didSet { scheduleSave() } }

    /// Off by default: it is the only setting that makes the app talk to a server.
    @Published public var publicIPEnabled: Bool { didSet { scheduleSave() } }
    @Published public var publicIPEndpointV4: String { didSet { scheduleSave() } }
    @Published public var publicIPEndpointV6: String { didSet { scheduleSave() } }

    // Weather is opt-in for the same reason, and carries its own provider choice.
    @Published public var weatherEnabled: Bool { didSet { scheduleSave() } }
    @Published public var weatherProvider: WeatherProviderID { didSet { scheduleSave() } }
    @Published public var weatherLocation: WeatherLocation? { didSet { scheduleSave() } }
    @Published public var weatherRefreshMinutes: Int { didSet { scheduleSave() } }
    @Published public var weatherUsesDeviceLocation: Bool { didSet { scheduleSave() } }

    // Appearance
    @Published public var graphs: [ModuleID: GraphAppearance] { didSet { scheduleSave() } }
    @Published public var panel: PanelAppearance { didSet { scheduleSave() } }
    @Published public var menubarGraphWidth: Double { didSet { scheduleSave() } }
    @Published public var highlightRowsOnHover: Bool { didSet { scheduleSave() } }

    /// What the Sensors menu bar item shows, in order.
    @Published public var sensorMenubarItems: [SensorMenubarItem] { didSet { scheduleSave() } }

    /// Result of the last sensor calibration, if one has been run on this Mac.
    @Published public var sensorCalibration: SensorCalibration? { didSet { scheduleSave() } }

    @Published public var timeZones: [String] { didSet { scheduleSave() } }
    @Published public var timeFormat: String { didSet { scheduleSave() } }
    @Published public var launchAtLogin: Bool { didSet { scheduleSave() } }

    // MARK: Init

    private struct Stored: Codable {
        var modules: [String: ModuleSettings]?
        var updateInterval: TimeInterval?
        var temperatureUnit: TemperatureUnit?
        var historyMinutes: Int?
        var chartRanges: [String: HistoryRange]?
        var defaultChartRange: HistoryRange?
        var showPerCoreGraph: Bool?
        var networkUnitBits: Bool?
        var publicIPEnabled: Bool?
        var publicIPEndpointV4: String?
        var publicIPEndpointV6: String?
        var weatherEnabled: Bool?
        var weatherProvider: WeatherProviderID?
        var weatherLocation: WeatherLocation?
        var weatherRefreshMinutes: Int?
        var weatherUsesDeviceLocation: Bool?
        var graphs: [String: GraphAppearance]?
        var panel: PanelAppearance?
        var panelMaterial: PanelMaterial?      // pre-glass setting, migrated below
        var menubarGraphWidth: Double?
        var highlightRowsOnHover: Bool?
        var sensorMenubarItems: [SensorMenubarItem]?
        var sensorCalibration: SensorCalibration?
        var timeZones: [String]?
        var timeFormat: String?
        var launchAtLogin: Bool?
    }

    public init(defaults: UserDefaults = .standard) {
        // The bundle identifier changed, which moved the preferences domain;
        // this brings the old settings across before they are read.
        Migration.runIfNeeded(defaults: defaults)
        self.defaults = defaults
        let stored: Stored? = {
            guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }()

        var modules: [ModuleID: ModuleSettings] = [:]
        for (index, module) in ModuleID.allCases.enumerated() {
            let fallback = ModuleSettings(
                enabled: Self.defaultEnabled.contains(module),
                style: Self.defaultStyle[module] ?? .text,
                order: index
            )
            modules[module] = stored?.modules?[module.rawValue] ?? fallback
        }
        self.modules = modules

        updateInterval = stored?.updateInterval ?? 2
        temperatureUnit = stored?.temperatureUnit ?? .celsius
        historyMinutes = stored?.historyMinutes ?? 10
        chartRanges = stored?.chartRanges ?? [:]
        defaultChartRange = stored?.defaultChartRange ?? .h1
        showPerCoreGraph = stored?.showPerCoreGraph ?? true
        networkUnitBits = stored?.networkUnitBits ?? false
        publicIPEnabled = stored?.publicIPEnabled ?? false
        publicIPEndpointV4 = stored?.publicIPEndpointV4 ?? "https://api.ipify.org"
        publicIPEndpointV6 = stored?.publicIPEndpointV6 ?? "https://api64.ipify.org"
        weatherEnabled = stored?.weatherEnabled ?? false
        weatherProvider = stored?.weatherProvider ?? .openMeteo
        weatherLocation = stored?.weatherLocation
        weatherRefreshMinutes = stored?.weatherRefreshMinutes ?? 30
        weatherUsesDeviceLocation = stored?.weatherUsesDeviceLocation ?? false
        var graphs: [ModuleID: GraphAppearance] = [:]
        for module in ModuleID.allCases {
            graphs[module] = stored?.graphs?[module.rawValue] ?? .standard(for: module)
        }
        self.graphs = graphs
        // Earlier builds stored only a material; carry it forward.
        if let saved = stored?.panel {
            panel = saved
        } else if let legacy = stored?.panelMaterial {
            panel = PanelAppearance(material: legacy)
        } else {
            panel = .standard
        }
        menubarGraphWidth = stored?.menubarGraphWidth ?? 32
        highlightRowsOnHover = stored?.highlightRowsOnHover ?? true

        sensorMenubarItems = stored?.sensorMenubarItems ?? SensorMenubarItem.standard

        // A calibration measured on a different machine means nothing here.
        let model = sysctlString("hw.model") ?? "Mac"
        sensorCalibration = stored?.sensorCalibration.flatMap { $0.applies(to: model) ? $0 : nil }

        timeZones = stored?.timeZones ?? [TimeZone.current.identifier]
        timeFormat = stored?.timeFormat ?? "HH:mm"
        launchAtLogin = stored?.launchAtLogin ?? false
    }

    private static let defaultEnabled: Set<ModuleID> = [.cpu, .memory, .network, .sensors]
    private static let defaultStyle: [ModuleID: MenubarStyle] = [
        .cpu: .textAndGraph,
        .gpu: .text,
        .memory: .textAndGraph,
        .disks: .text,
        .network: .text,
        .sensors: .text,
        .battery: .text,
        .time: .text,
        .weather: .text,
        .combined: .icon,
    ]

    // MARK: Access

    public func module(_ id: ModuleID) -> ModuleSettings {
        modules[id] ?? ModuleSettings(enabled: false)
    }

    public func setModule(_ id: ModuleID, _ transform: (inout ModuleSettings) -> Void) {
        var value = module(id)
        transform(&value)
        modules[id] = value
    }

    /// Toggles a reading in the menu bar, keeping the list within what fits.
    public func toggleSensorMenubarItem(_ item: SensorMenubarItem) {
        if let index = sensorMenubarItems.firstIndex(of: item) {
            // Never leave the item with nothing to draw.
            guard sensorMenubarItems.count > 1 else { return }
            sensorMenubarItems.remove(at: index)
        } else {
            sensorMenubarItems.append(item)
            if sensorMenubarItems.count > SensorMenubarItem.maximumSelected {
                sensorMenubarItems.removeFirst()
            }
        }
    }

    public func chartRange(_ chart: String) -> HistoryRange {
        chartRanges[chart] ?? defaultChartRange
    }

    public func setChartRange(_ chart: String, _ range: HistoryRange) {
        chartRanges[chart] = range
    }

    /// Puts every chart back on the default range.
    public func resetChartRanges() {
        chartRanges = [:]
    }

    public func graph(_ id: ModuleID) -> GraphAppearance {
        graphs[id] ?? .standard(for: id)
    }

    public func setGraph(_ id: ModuleID, _ transform: (inout GraphAppearance) -> Void) {
        var value = graph(id)
        transform(&value)
        graphs[id] = value
    }

    /// Puts one module's colours back to the shipped defaults.
    public func resetGraph(_ id: ModuleID) {
        graphs[id] = .standard(for: id)
    }

    public var enabledModules: [ModuleID] {
        modules.filter { $0.value.enabled }
            .sorted { $0.value.order < $1.value.order }
            .map(\.key)
    }

    /// Number of samples to keep so history covers `historyMinutes`.
    public var historyCapacity: Int {
        max(60, Int(Double(historyMinutes) * 60 / max(0.5, updateInterval)))
    }

    // MARK: Persistence

    private func scheduleSave() {
        // Sliders and steppers fire continuously; collapse the writes.
        saveTask?.cancel()
        saveTask = Just(())
            .delay(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
    }

    public func save() {
        let stored = Stored(
            modules: Dictionary(uniqueKeysWithValues: modules.map { ($0.key.rawValue, $0.value) }),
            updateInterval: updateInterval,
            temperatureUnit: temperatureUnit,
            historyMinutes: historyMinutes,
            chartRanges: chartRanges,
            defaultChartRange: defaultChartRange,
            showPerCoreGraph: showPerCoreGraph,
            networkUnitBits: networkUnitBits,
            publicIPEnabled: publicIPEnabled,
            publicIPEndpointV4: publicIPEndpointV4,
            publicIPEndpointV6: publicIPEndpointV6,
            weatherEnabled: weatherEnabled,
            weatherProvider: weatherProvider,
            weatherLocation: weatherLocation,
            weatherRefreshMinutes: weatherRefreshMinutes,
            weatherUsesDeviceLocation: weatherUsesDeviceLocation,
            graphs: Dictionary(uniqueKeysWithValues: graphs.map { ($0.key.rawValue, $0.value) }),
            panel: panel,
            panelMaterial: nil,
            menubarGraphWidth: menubarGraphWidth,
            highlightRowsOnHover: highlightRowsOnHover,
            sensorMenubarItems: sensorMenubarItems,
            sensorCalibration: sensorCalibration,
            timeZones: timeZones,
            timeFormat: timeFormat,
            launchAtLogin: launchAtLogin
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
