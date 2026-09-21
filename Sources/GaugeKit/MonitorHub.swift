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
        public var cpuUser: [Double] = []
        public var cpuSystem: [Double] = []
        /// One history per logical core, for the per-core graph grid.
        public var perCore: [[Double]] = []
        public var loadAverage: [Double] = []
        public var memory: [Double] = []
        public var memoryApp: [Double] = []
        public var memoryWired: [Double] = []
        public var memoryCompressed: [Double] = []
        public var swap: [Double] = []
        public var gpu: [Double] = []
        public var networkDown: [Double] = []
        public var networkUp: [Double] = []
        public var diskRead: [Double] = []
        public var diskWrite: [Double] = []
        public var socTemperature: [Double] = []
        public var fanRPM: [Double] = []
        public var power: [Double] = []
        public var batteryCharge: [Double] = []
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
        var cpuUser: RingBuffer<Double>
        var cpuSystem: RingBuffer<Double>
        var perCore: [RingBuffer<Double>]
        var loadAverage: RingBuffer<Double>
        var memory: RingBuffer<Double>
        var memoryApp: RingBuffer<Double>
        var memoryWired: RingBuffer<Double>
        var memoryCompressed: RingBuffer<Double>
        var swap: RingBuffer<Double>
        var gpu: RingBuffer<Double>
        var networkDown: RingBuffer<Double>
        var networkUp: RingBuffer<Double>
        var diskRead: RingBuffer<Double>
        var diskWrite: RingBuffer<Double>
        var socTemperature: RingBuffer<Double>
        var fanRPM: RingBuffer<Double>
        var power: RingBuffer<Double>
        var batteryCharge: RingBuffer<Double>

        init(capacity: Int, cores: Int) {
            cpu = .init(capacity: capacity)
            cpuPerformance = .init(capacity: capacity)
            cpuEfficiency = .init(capacity: capacity)
            cpuUser = .init(capacity: capacity)
            cpuSystem = .init(capacity: capacity)
            // Per-core history is the same window, just narrower graphs.
            perCore = (0..<max(1, cores)).map { _ in RingBuffer<Double>(capacity: capacity) }
            loadAverage = .init(capacity: capacity)
            memory = .init(capacity: capacity)
            memoryApp = .init(capacity: capacity)
            memoryWired = .init(capacity: capacity)
            memoryCompressed = .init(capacity: capacity)
            swap = .init(capacity: capacity)
            gpu = .init(capacity: capacity)
            networkDown = .init(capacity: capacity)
            networkUp = .init(capacity: capacity)
            diskRead = .init(capacity: capacity)
            diskWrite = .init(capacity: capacity)
            socTemperature = .init(capacity: capacity)
            fanRPM = .init(capacity: capacity)
            power = .init(capacity: capacity)
            batteryCharge = .init(capacity: capacity)
        }
    }

    // MARK: Lifecycle

    public init(settings: GaugeSettings = .shared) {
        self.settings = settings
        self.history = History(capacity: settings.historyCapacity, cores: cpuMonitor.coreCount)

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
        history = History(capacity: capacity, cores: cpuMonitor.coreCount)
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
        history.cpuUser.append(snapshot.cpu.user)
        history.cpuSystem.append(snapshot.cpu.system)
        for core in snapshot.cpu.cores where core.id < history.perCore.count {
            history.perCore[core.id].append(core.total)
        }
        // Normalised against the core count so the graph has a sensible ceiling.
        history.loadAverage.append(snapshot.cpu.loadAverage.one)
        history.memory.append(snapshot.memory.usedFraction)
        history.memoryApp.append(snapshot.memory.appMemory)
        history.memoryWired.append(snapshot.memory.wired)
        history.memoryCompressed.append(snapshot.memory.compressed)
        history.swap.append(snapshot.memory.swapUsed)
        history.gpu.append(snapshot.gpu.utilization)
        history.networkDown.append(snapshot.network.downloadRate)
        history.networkUp.append(snapshot.network.uploadRate)
        history.diskRead.append(snapshot.disk.activity.readRate)
        history.diskWrite.append(snapshot.disk.activity.writeRate)
        if let temperature = snapshot.sensors.socTemperature { history.socTemperature.append(temperature) }
        if let fan = snapshot.sensors.fans.first { history.fanRPM.append(fan.rpm) }
        if let power = snapshot.sensors.systemPower { history.power.append(power) }
        if snapshot.battery.isPresent { history.batteryCharge.append(snapshot.battery.charge) }

        var series = Series()
        series.cpu = history.cpu.values
        series.cpuPerformance = history.cpuPerformance.values
        series.cpuEfficiency = history.cpuEfficiency.values
        series.cpuUser = history.cpuUser.values
        series.cpuSystem = history.cpuSystem.values
        series.perCore = history.perCore.map(\.values)
        series.loadAverage = history.loadAverage.values
        series.memory = history.memory.values
        series.memoryApp = history.memoryApp.values
        series.memoryWired = history.memoryWired.values
        series.memoryCompressed = history.memoryCompressed.values
        series.swap = history.swap.values
        series.gpu = history.gpu.values
        series.networkDown = history.networkDown.values
        series.networkUp = history.networkUp.values
        series.diskRead = history.diskRead.values
        series.diskWrite = history.diskWrite.values
        series.socTemperature = history.socTemperature.values
        series.fanRPM = history.fanRPM.values
        series.power = history.power.values
        series.batteryCharge = history.batteryCharge.values

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

    /// Fills the history with a plausible shape so the rendered previews show
    /// what the graphs look like under load. Only `--preview --demo` calls it;
    /// a real run always plots measured values.
    public func injectDemoHistory(samples: Int = 180) {
        func wave(_ base: Double, _ amplitude: Double, _ periods: Double,
                  _ noise: Double, _ index: Int) -> Double {
            let x = Double(index) / Double(max(1, samples - 1))
            let value = base
                + amplitude * sin(x * .pi * periods)
                + amplitude * 0.35 * sin(x * .pi * periods * 3.7)
                + Double.random(in: -noise...noise)
            return max(0, value)
        }

        var history = History(capacity: max(samples, settings.historyCapacity),
                              cores: cpuMonitor.coreCount)
        for index in 0..<samples {
            let user = wave(0.22, 0.16, 2.2, 0.03, index)
            let system = wave(0.08, 0.05, 3.1, 0.015, index)
            history.cpuUser.append(user)
            history.cpuSystem.append(system)
            history.cpu.append(min(1, user + system))
            history.cpuPerformance.append(wave(0.2, 0.18, 1.7, 0.04, index))
            history.cpuEfficiency.append(wave(0.45, 0.25, 2.6, 0.05, index))
            for core in history.perCore.indices {
                history.perCore[core].append(
                    wave(core < 6 ? 0.45 : 0.2, 0.3, 2.0 + Double(core) * 0.4, 0.08, index))
            }
            history.loadAverage.append(wave(4, 3, 1.4, 0.4, index))

            let total = memoryMonitor.physicalMemory
            history.memoryApp.append(wave(total * 0.28, total * 0.06, 1.3, total * 0.01, index))
            history.memoryWired.append(wave(total * 0.14, total * 0.02, 0.8, total * 0.004, index))
            history.memoryCompressed.append(wave(total * 0.2, total * 0.08, 1.9, total * 0.01, index))
            history.memory.append(wave(0.62, 0.12, 1.3, 0.02, index))
            history.swap.append(wave(4e8, 3e8, 0.9, 2e7, index))

            history.gpu.append(wave(0.18, 0.17, 3.3, 0.05, index))
            history.networkDown.append(wave(2.2e6, 2.0e6, 2.4, 3e5, index))
            history.networkUp.append(wave(4e5, 3.5e5, 3.0, 8e4, index))
            history.diskRead.append(wave(1.4e7, 1.3e7, 1.8, 2e6, index))
            history.diskWrite.append(wave(6e6, 5e6, 2.9, 1e6, index))
            history.socTemperature.append(wave(56, 9, 1.6, 1.2, index))
            history.fanRPM.append(wave(2600, 700, 1.2, 60, index))
            history.power.append(wave(18, 9, 2.1, 1.5, index))
            history.batteryCharge.append(min(1, 0.55 + 0.4 * Double(index) / Double(samples)))
        }
        self.history = history

        var series = Series()
        series.cpu = history.cpu.values
        series.cpuPerformance = history.cpuPerformance.values
        series.cpuEfficiency = history.cpuEfficiency.values
        series.cpuUser = history.cpuUser.values
        series.cpuSystem = history.cpuSystem.values
        series.perCore = history.perCore.map(\.values)
        series.loadAverage = history.loadAverage.values
        series.memory = history.memory.values
        series.memoryApp = history.memoryApp.values
        series.memoryWired = history.memoryWired.values
        series.memoryCompressed = history.memoryCompressed.values
        series.swap = history.swap.values
        series.gpu = history.gpu.values
        series.networkDown = history.networkDown.values
        series.networkUp = history.networkUp.values
        series.diskRead = history.diskRead.values
        series.diskWrite = history.diskWrite.values
        series.socTemperature = history.socTemperature.values
        series.fanRPM = history.fanRPM.values
        series.power = history.power.values
        series.batteryCharge = history.batteryCharge.values
        self.series = series
    }

    /// A stand-in forecast for `--preview --demo`, so the weather charts can
    /// be reviewed without a network call or a configured location.
    public func injectDemoWeather() {
        let now = Date()
        let calendar = Calendar.current
        let condition = { (code: Int, day: Bool) in WMOCode.condition(for: code, isDay: day) }

        let hourly = (0..<14).map { offset -> WeatherHour in
            let date = now.addingTimeInterval(TimeInterval(offset) * 3600)
            let hour = calendar.component(.hour, from: date)
            return WeatherHour(
                date: date,
                temperature: 27 + 3 * sin(Double(offset) / 5) + Double(offset % 3) * 0.4,
                precipitationProbability: min(0.95, 0.15 + 0.7 * abs(sin(Double(offset) / 3.2))),
                condition: condition([0, 2, 3, 61, 80, 95][offset % 6], (7...18).contains(hour)))
        }

        let daily = (0..<7).map { offset -> WeatherDay in
            let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            return WeatherDay(
                date: date,
                high: 30 + 2 * sin(Double(offset) / 1.7),
                low: 24 + 1.5 * cos(Double(offset) / 2.1),
                precipitationProbability: 0.2 + 0.6 * abs(sin(Double(offset) / 2)),
                sunrise: calendar.date(bySettingHour: 6, minute: 12, second: 0, of: date),
                sunset: calendar.date(bySettingHour: 18, minute: 30, second: 0, of: date),
                condition: condition([0, 3, 61, 95, 80, 2, 3][offset], true))
        }

        weather = WeatherReport(
            location: WeatherLocation(name: "Samut Prakan", latitude: 13.5976, longitude: 100.5972,
                                      country: "Thailand", timezone: "Asia/Bangkok"),
            now: WeatherNow(temperature: 27.4, feelsLike: 32.1, humidity: 0.86,
                            windSpeed: 9, windDirection: 210, pressure: 1008,
                            precipitation: 0.4, uvIndex: 7,
                            condition: condition(80, true)),
            hourly: hourly,
            daily: daily,
            provider: .openMeteo,
            attribution: "Demo data",
            fetchedAt: now)
        weatherError = nil
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
