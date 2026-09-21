import Foundation
import Combine

/// One timer, one sampling pass, one published snapshot.
///
/// Every module reads from the same tick so the menu bar items never disagree
/// with each other, and the sampling itself stays off the main thread.
@MainActor
public final class MonitorHub: ObservableObject {
    public struct Snapshot: Sendable {
        public var cpu = CPUSnapshot()
        public var memory = MemorySnapshot()
        public var gpu = GPUSnapshot()
        public var disk = DiskSnapshot()
        public var network = NetworkSnapshot()
        public var sensors = SensorSnapshot()
        public var battery = BatterySnapshot()
        public var topByCPU: [ProcessUsage] = []
        public var topByMemory: [ProcessUsage] = []
        public var timestamp = Date()
    }

    public struct Series: Sendable {
        public var cpu: [Double] = []
        public var cpuPerformance: [Double] = []
        public var cpuEfficiency: [Double] = []
        public var memory: [Double] = []
        public var gpu: [Double] = []
        public var networkDown: [Double] = []
        public var networkUp: [Double] = []
        public var diskRead: [Double] = []
        public var diskWrite: [Double] = []
        public var socTemperature: [Double] = []
        public var fanRPM: [Double] = []
        public var power: [Double] = []
    }

    // MARK: Published state

    @Published public private(set) var snapshot = Snapshot()
    @Published public private(set) var series = Series()
    @Published public private(set) var weather: WeatherReport?
    @Published public private(set) var weatherError: String?
    @Published public private(set) var isRefreshingWeather = false

    public let settings: GaugeSettings
    public let hardware = HardwareInfo()
    /// "Super" / "Efficiency" on an M5, "Performance" / "Efficiency" before it.
    public var performanceClusterName: String { cpuMonitor.performanceClusterName }
    public var efficiencyClusterName: String { cpuMonitor.efficiencyClusterName }

    // MARK: Collectors

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let gpuMonitor = GPUMonitor()
    private let diskMonitor = DiskMonitor()
    private let networkMonitor = NetworkMonitor()
    private let sensorMonitor = SensorMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let processMonitor = ProcessMonitor()
    private let publicIP = PublicIPResolver()

    private let queue = DispatchQueue(label: "com.gauge.sampling", qos: .utility)
    /// Set while a dropdown is open. Walking every process is by far the most
    /// expensive part of a pass, and only the panels display the result, so it
    /// runs every tick while one is visible and rarely otherwise.
    public var isShowingDetail = false {
        didSet { if isShowingDetail { sampleNow() } }
    }
    private var lastProcessSample: Date?
    private let backgroundProcessInterval: TimeInterval = 15

    private var timer: Timer?
    private var weatherTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isSampling = false

    // MARK: History

    private var history: History

    private struct History {
        var cpu: RingBuffer<Double>
        var cpuPerformance: RingBuffer<Double>
        var cpuEfficiency: RingBuffer<Double>
        var memory: RingBuffer<Double>
        var gpu: RingBuffer<Double>
        var networkDown: RingBuffer<Double>
        var networkUp: RingBuffer<Double>
        var diskRead: RingBuffer<Double>
        var diskWrite: RingBuffer<Double>
        var socTemperature: RingBuffer<Double>
        var fanRPM: RingBuffer<Double>
        var power: RingBuffer<Double>

        init(capacity: Int) {
            cpu = .init(capacity: capacity)
            cpuPerformance = .init(capacity: capacity)
            cpuEfficiency = .init(capacity: capacity)
            memory = .init(capacity: capacity)
            gpu = .init(capacity: capacity)
            networkDown = .init(capacity: capacity)
            networkUp = .init(capacity: capacity)
            diskRead = .init(capacity: capacity)
            diskWrite = .init(capacity: capacity)
            socTemperature = .init(capacity: capacity)
            fanRPM = .init(capacity: capacity)
            power = .init(capacity: capacity)
        }
    }

    // MARK: Lifecycle

    public init(settings: GaugeSettings = .shared) {
        self.settings = settings
        self.history = History(capacity: settings.historyCapacity)

        // Re-arm the timers whenever the cadence or retention window changes.
        settings.$updateInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &cancellables)

        settings.$historyMinutes
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resizeHistory() }
            .store(in: &cancellables)

        settings.$weatherEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.refreshWeather(force: true) } else { self.weather = nil }
                self.restartWeatherTimer()
            }
            .store(in: &cancellables)

        settings.$weatherLocation
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshWeather(force: true) }
            .store(in: &cancellables)
    }

    public func start() {
        restartTimer()
        restartWeatherTimer()
        sampleNow()
        if settings.weatherEnabled { refreshWeather(force: true) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = max(0.5, settings.updateInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        // .common keeps sampling alive while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        resizeHistory()
    }

    private func restartWeatherTimer() {
        weatherTimer?.invalidate()
        guard settings.weatherEnabled else { return }
        let interval = TimeInterval(max(10, settings.weatherRefreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWeather(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        weatherTimer = timer
    }

    private func resizeHistory() {
        let capacity = settings.historyCapacity
        guard capacity != history.cpu.capacity else { return }
        // Retention changed; start the new window rather than resampling the past.
        history = History(capacity: capacity)
    }

    // MARK: Sampling

    public func sampleNow() {
        guard !isSampling else { return }   // a slow pass must not queue up more work
        isSampling = true

        let stale = lastProcessSample.map { Date().timeIntervalSince($0) >= backgroundProcessInterval } ?? true
        let wantsProcesses = isShowingDetail || stale
        if wantsProcesses { lastProcessSample = Date() }
        // With no panel open, the slow collectors fall back to their own
        // background cadence instead of running every tick.
        let live = isShowingDetail

        queue.async { [weak self] in
            guard let self else { return }

            var snapshot = Snapshot()
            snapshot.cpu = self.cpuMonitor.sample()
            snapshot.memory = self.memoryMonitor.sample()
            snapshot.gpu = self.gpuMonitor.sample()
            snapshot.disk = self.diskMonitor.sample(live: live)
            snapshot.network = self.networkMonitor.sample(live: live)
            snapshot.sensors = self.sensorMonitor.sample(live: live)
            snapshot.battery = self.batteryMonitor.sample(live: live)
            if wantsProcesses {
                let processes = self.processMonitor.sample()
                snapshot.topByCPU = processes.byCPU
                snapshot.topByMemory = processes.byMemory
                snapshot.cpu.threadCount = processes.threadCount
            }
            snapshot.timestamp = Date()

            Task { @MainActor in
                self.apply(snapshot)
                self.isSampling = false
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        var snapshot = snapshot
        // Carry the last known process list and thread count across the ticks
        // that skipped the walk, so panels never blank out.
        if snapshot.topByCPU.isEmpty, !self.snapshot.topByCPU.isEmpty {
            snapshot.topByCPU = self.snapshot.topByCPU
            snapshot.topByMemory = self.snapshot.topByMemory
            snapshot.cpu.threadCount = self.snapshot.cpu.threadCount
        }

        history.cpu.append(snapshot.cpu.total)
        history.cpuPerformance.append(snapshot.cpu.performanceLoad)
        history.cpuEfficiency.append(snapshot.cpu.efficiencyLoad)
        history.memory.append(snapshot.memory.usedFraction)
        history.gpu.append(snapshot.gpu.utilization)
        history.networkDown.append(snapshot.network.downloadRate)
        history.networkUp.append(snapshot.network.uploadRate)
        history.diskRead.append(snapshot.disk.activity.readRate)
        history.diskWrite.append(snapshot.disk.activity.writeRate)
        if let temperature = snapshot.sensors.socTemperature { history.socTemperature.append(temperature) }
        if let fan = snapshot.sensors.fans.first { history.fanRPM.append(fan.rpm) }
        if let power = snapshot.sensors.systemPower { history.power.append(power) }

        var series = Series()
        series.cpu = history.cpu.values
        series.cpuPerformance = history.cpuPerformance.values
        series.cpuEfficiency = history.cpuEfficiency.values
        series.memory = history.memory.values
        series.gpu = history.gpu.values
        series.networkDown = history.networkDown.values
        series.networkUp = history.networkUp.values
        series.diskRead = history.diskRead.values
        series.diskWrite = history.diskWrite.values
        series.socTemperature = history.socTemperature.values
        series.fanRPM = history.fanRPM.values
        series.power = history.power.values

        self.snapshot = snapshot
        self.series = series

        if settings.publicIPEnabled { refreshPublicIPIfNeeded() }
    }

    // MARK: Public IP

    private var publicIPTask: Task<Void, Never>?

    private func refreshPublicIPIfNeeded() {
        guard publicIPTask == nil else { return }
        publicIPTask = Task { [weak self] in
            guard let self else { return }
            let v4 = settings.publicIPEndpointV4
            let v6 = settings.publicIPEndpointV6.isEmpty ? nil : settings.publicIPEndpointV6
            let result = await publicIP.lookup(endpointV4: v4, endpointV6: v6)
            await MainActor.run {
                if let result {
                    self.snapshot.network.publicIPv4 = result.ipv4
                    self.snapshot.network.publicIPv6 = result.ipv6
                }
                self.publicIPTask = nil
            }
        }
    }

    public func resetNetworkTotals() {
        networkMonitor.resetSessionTotals()
    }

    // MARK: Weather

    private var weatherTask: Task<Void, Never>?

    public func refreshWeather(force: Bool) {
        guard settings.weatherEnabled else { return }
        guard let location = settings.weatherLocation else {
            weatherError = WeatherError.noLocation.errorDescription
            return
        }
        if !force, let weather, Date().timeIntervalSince(weather.fetchedAt) < 300 { return }

        weatherTask?.cancel()
        isRefreshingWeather = true
        let provider: WeatherProvider = settings.weatherProvider == .accuWeather
            ? AccuWeatherProvider() : OpenMeteoProvider()
        let apiKey = settings.weatherProvider.requiresKey ? Keychain.get(Keychain.accuWeatherKey) : nil

        weatherTask = Task { [weak self] in
            do {
                let report = try await provider.fetch(location: location, apiKey: apiKey)
                await MainActor.run {
                    guard let self else { return }
                    self.weather = report
                    self.weatherError = nil
                    self.isRefreshingWeather = false
                    // AccuWeather hands back a location key worth keeping.
                    if report.location.providerKey != self.settings.weatherLocation?.providerKey {
                        self.settings.weatherLocation = report.location
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.weatherError = (error as? WeatherError)?.errorDescription ?? error.localizedDescription
                    self.isRefreshingWeather = false
                }
            }
        }
    }

    public func searchLocations(_ query: String) async -> [GeocodeResult] {
        let provider: WeatherProvider = settings.weatherProvider == .accuWeather
            ? AccuWeatherProvider() : OpenMeteoProvider()
        let apiKey = settings.weatherProvider.requiresKey ? Keychain.get(Keychain.accuWeatherKey) : nil
        return (try? await provider.search(query: query, apiKey: apiKey)) ?? []
    }
}

// MARK: - Static hardware facts

public struct HardwareInfo: Sendable {
    public let modelIdentifier: String
    public let modelName: String
    public let chip: String
    public let coreCount: Int
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let memoryBytes: Double
    public let osVersion: String
    public let serialNumberAvailable: Bool

    public init() {
        modelIdentifier = sysctlString("hw.model") ?? "Mac"
        chip = sysctlString("machdep.cpu.brand_string") ?? modelIdentifier
        coreCount = Int(sysctlValue("hw.logicalcpu") ?? 0)
        performanceCores = Int(sysctlValue("hw.perflevel0.logicalcpu") ?? 0)
        efficiencyCores = Int(sysctlValue("hw.perflevel1.logicalcpu") ?? 0)
        memoryBytes = Double(sysctlValue("hw.memsize") ?? 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        modelName = HardwareInfo.marketingName() ?? modelIdentifier
        serialNumberAvailable = false
    }

    /// The human-readable model lives in the IORegistry on Apple Silicon.
    private static func marketingName() -> String? {
        guard let data = sysctlString("hw.product") else { return nil }
        return data.isEmpty ? nil : data
    }
}
