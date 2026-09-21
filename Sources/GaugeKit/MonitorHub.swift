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
        public var frequency = FrequencySnapshot()
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

    /// Progress of a running sensor calibration, nil when none is running.
    @Published public private(set) var calibrationProgress: SensorCalibrator.Progress?

    public let settings: GaugeSettings
    public let hardware = HardwareInfo()
    /// Long-term history, kept at three resolutions and written to disk so a
    /// chart set to days or weeks has something to show after a restart.
    public let history = HistoryStore()
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
    /// Nil on hardware that does not publish DVFS residency.
    private let frequencyMonitor = FrequencyMonitor()
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
    private var saveTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isSampling = false

    // MARK: History

    private var liveHistory: History

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
        self.liveHistory = History(capacity: settings.historyCapacity, cores: cpuMonitor.coreCount)

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

        sensorMonitor.calibration = settings.sensorCalibration
    }

    public func start() {
        restartTimer()
        restartWeatherTimer()
        sampleNow()
        if settings.weatherEnabled { refreshWeather(force: true) }

        // Losing more than a minute of long-range history to a crash would be
        // annoying; saving more often than that is pointless.
        let saveTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.history.saveIfNeeded()
        }
        RunLoop.main.add(saveTimer, forMode: .common)
        self.saveTimer = saveTimer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        history.save()
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
        guard capacity != liveHistory.cpu.capacity else { return }
        // Retention changed; start the new window rather than resampling the past.
        liveHistory = History(capacity: capacity, cores: cpuMonitor.coreCount)
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
            if let frequency = self.frequencyMonitor?.sample() { snapshot.frequency = frequency }
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

    /// Names used by the long-term store. Kept as constants so a chart and
    /// the recorder cannot disagree about a spelling.
    public enum Metric {
        public static let cpu = "cpu"
        public static let cpuUser = "cpu.user"
        public static let cpuSystem = "cpu.system"
        public static let cpuPerformance = "cpu.performance"
        public static let cpuEfficiency = "cpu.efficiency"
        public static let load = "cpu.load"
        public static let memory = "memory.used"
        public static let memoryApp = "memory.app"
        public static let memoryWired = "memory.wired"
        public static let memoryCompressed = "memory.compressed"
        public static let swap = "memory.swap"
        public static let gpu = "gpu"
        public static let networkDown = "network.down"
        public static let networkUp = "network.up"
        public static let diskRead = "disk.read"
        public static let diskWrite = "disk.write"
        public static let temperature = "sensors.cpuDie"
        public static let fan = "sensors.fan"
        public static let power = "sensors.power"
        public static let battery = "battery.charge"
        public static let efficiencyClock = "cpu.clock.efficiency"
        public static let performanceClock = "cpu.clock.performance"
        public static let gpuClock = "gpu.clock"
        public static let ssdTemperature = "sensors.ssd"
        public static let batteryTemperature = "sensors.battery"
        public static func core(_ index: Int) -> String { "cpu.core.\(index)" }
    }

    private func recordHistory(_ snapshot: Snapshot, at date: Date) {
        history.record(Metric.cpu, snapshot.cpu.total, at: date)
        history.record(Metric.cpuUser, snapshot.cpu.user, at: date)
        history.record(Metric.cpuSystem, snapshot.cpu.system, at: date)
        history.record(Metric.cpuPerformance, snapshot.cpu.performanceLoad, at: date)
        history.record(Metric.cpuEfficiency, snapshot.cpu.efficiencyLoad, at: date)
        history.record(Metric.load, snapshot.cpu.loadAverage.one, at: date)
        for core in snapshot.cpu.cores { history.record(Metric.core(core.id), core.total, at: date) }

        history.record(Metric.memory, snapshot.memory.usedFraction, at: date)
        history.record(Metric.memoryApp, snapshot.memory.appMemory, at: date)
        history.record(Metric.memoryWired, snapshot.memory.wired, at: date)
        history.record(Metric.memoryCompressed, snapshot.memory.compressed, at: date)
        history.record(Metric.swap, snapshot.memory.swapUsed, at: date)
        history.record(Metric.gpu, snapshot.gpu.utilization, at: date)
        history.record(Metric.networkDown, snapshot.network.downloadRate, at: date)
        history.record(Metric.networkUp, snapshot.network.uploadRate, at: date)
        history.record(Metric.diskRead, snapshot.disk.activity.readRate, at: date)
        history.record(Metric.diskWrite, snapshot.disk.activity.writeRate, at: date)

        if let temperature = snapshot.sensors.socTemperature {
            history.record(Metric.temperature, temperature, at: date)
        }
        if let fan = snapshot.sensors.fans.first { history.record(Metric.fan, fan.rpm, at: date) }
        if let power = snapshot.sensors.systemPower { history.record(Metric.power, power, at: date) }
        if let storage = snapshot.sensors.storageTemperature {
            history.record(Metric.ssdTemperature, storage, at: date)
        }
        if let batteryTemperature = snapshot.sensors.batteryTemperature {
            history.record(Metric.batteryTemperature, batteryTemperature, at: date)
        }
        if let clock = snapshot.frequency.efficiencyMHz {
            history.record(Metric.efficiencyClock, clock, at: date)
        }
        if let clock = snapshot.frequency.performanceMHz {
            history.record(Metric.performanceClock, clock, at: date)
        }
        if let clock = snapshot.frequency.gpuMHz { history.record(Metric.gpuClock, clock, at: date) }
        if snapshot.battery.isPresent { history.record(Metric.battery, snapshot.battery.charge, at: date) }
    }

    /// History for a chart, at whatever range it is set to.
    public func series(_ metric: String, range: HistoryRange, points: Int = 320) -> HistorySeries {
        history.series(metric, range: range, maximumPoints: points)
    }

    private func apply(_ snapshot: Snapshot) {
        var snapshot = snapshot
        recordHistory(snapshot, at: snapshot.timestamp)
        // Carry the last known process list and thread count across the ticks
        // that skipped the walk, so panels never blank out.
        if snapshot.topByCPU.isEmpty, !self.snapshot.topByCPU.isEmpty {
            snapshot.topByCPU = self.snapshot.topByCPU
            snapshot.topByMemory = self.snapshot.topByMemory
            snapshot.cpu.threadCount = self.snapshot.cpu.threadCount
        }

        liveHistory.cpu.append(snapshot.cpu.total)
        liveHistory.cpuPerformance.append(snapshot.cpu.performanceLoad)
        liveHistory.cpuEfficiency.append(snapshot.cpu.efficiencyLoad)
        liveHistory.cpuUser.append(snapshot.cpu.user)
        liveHistory.cpuSystem.append(snapshot.cpu.system)
        for core in snapshot.cpu.cores where core.id < liveHistory.perCore.count {
            liveHistory.perCore[core.id].append(core.total)
        }
        // Normalised against the core count so the graph has a sensible ceiling.
        liveHistory.loadAverage.append(snapshot.cpu.loadAverage.one)
        liveHistory.memory.append(snapshot.memory.usedFraction)
        liveHistory.memoryApp.append(snapshot.memory.appMemory)
        liveHistory.memoryWired.append(snapshot.memory.wired)
        liveHistory.memoryCompressed.append(snapshot.memory.compressed)
        liveHistory.swap.append(snapshot.memory.swapUsed)
        liveHistory.gpu.append(snapshot.gpu.utilization)
        liveHistory.networkDown.append(snapshot.network.downloadRate)
        liveHistory.networkUp.append(snapshot.network.uploadRate)
        liveHistory.diskRead.append(snapshot.disk.activity.readRate)
        liveHistory.diskWrite.append(snapshot.disk.activity.writeRate)
        if let temperature = snapshot.sensors.socTemperature { liveHistory.socTemperature.append(temperature) }
        if let fan = snapshot.sensors.fans.first { liveHistory.fanRPM.append(fan.rpm) }
        if let power = snapshot.sensors.systemPower { liveHistory.power.append(power) }
        if snapshot.battery.isPresent { liveHistory.batteryCharge.append(snapshot.battery.charge) }

        var series = Series()
        series.cpu = liveHistory.cpu.values
        series.cpuPerformance = liveHistory.cpuPerformance.values
        series.cpuEfficiency = liveHistory.cpuEfficiency.values
        series.cpuUser = liveHistory.cpuUser.values
        series.cpuSystem = liveHistory.cpuSystem.values
        series.perCore = liveHistory.perCore.map(\.values)
        series.loadAverage = liveHistory.loadAverage.values
        series.memory = liveHistory.memory.values
        series.memoryApp = liveHistory.memoryApp.values
        series.memoryWired = liveHistory.memoryWired.values
        series.memoryCompressed = liveHistory.memoryCompressed.values
        series.swap = liveHistory.swap.values
        series.gpu = liveHistory.gpu.values
        series.networkDown = liveHistory.networkDown.values
        series.networkUp = liveHistory.networkUp.values
        series.diskRead = liveHistory.diskRead.values
        series.diskWrite = liveHistory.diskWrite.values
        series.socTemperature = liveHistory.socTemperature.values
        series.fanRPM = liveHistory.fanRPM.values
        series.power = liveHistory.power.values
        series.batteryCharge = liveHistory.batteryCharge.values

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
            liveHistory.cpuUser.append(user)
            liveHistory.cpuSystem.append(system)
            liveHistory.cpu.append(min(1, user + system))
            liveHistory.cpuPerformance.append(wave(0.2, 0.18, 1.7, 0.04, index))
            liveHistory.cpuEfficiency.append(wave(0.45, 0.25, 2.6, 0.05, index))
            for core in liveHistory.perCore.indices {
                liveHistory.perCore[core].append(
                    wave(core < 6 ? 0.45 : 0.2, 0.3, 2.0 + Double(core) * 0.4, 0.08, index))
            }
            liveHistory.loadAverage.append(wave(4, 3, 1.4, 0.4, index))

            let total = memoryMonitor.physicalMemory
            liveHistory.memoryApp.append(wave(total * 0.28, total * 0.06, 1.3, total * 0.01, index))
            liveHistory.memoryWired.append(wave(total * 0.14, total * 0.02, 0.8, total * 0.004, index))
            liveHistory.memoryCompressed.append(wave(total * 0.2, total * 0.08, 1.9, total * 0.01, index))
            liveHistory.memory.append(wave(0.62, 0.12, 1.3, 0.02, index))
            liveHistory.swap.append(wave(4e8, 3e8, 0.9, 2e7, index))

            liveHistory.gpu.append(wave(0.18, 0.17, 3.3, 0.05, index))
            liveHistory.networkDown.append(wave(2.2e6, 2.0e6, 2.4, 3e5, index))
            liveHistory.networkUp.append(wave(4e5, 3.5e5, 3.0, 8e4, index))
            liveHistory.diskRead.append(wave(1.4e7, 1.3e7, 1.8, 2e6, index))
            liveHistory.diskWrite.append(wave(6e6, 5e6, 2.9, 1e6, index))
            liveHistory.socTemperature.append(wave(56, 9, 1.6, 1.2, index))
            liveHistory.fanRPM.append(wave(2600, 700, 1.2, 60, index))
            liveHistory.power.append(wave(18, 9, 2.1, 1.5, index))
            liveHistory.batteryCharge.append(min(1, 0.55 + 0.4 * Double(index) / Double(samples)))
        }
        self.liveHistory = history

        // Panels read the long-term store, so the demo data has to land there
        // too — sparsely over four weeks, then densely over the last hour, so
        // every range in the menu has something to draw.
        injectDemoStore(samples: samples)

        var series = Series()
        series.cpu = liveHistory.cpu.values
        series.cpuPerformance = liveHistory.cpuPerformance.values
        series.cpuEfficiency = liveHistory.cpuEfficiency.values
        series.cpuUser = liveHistory.cpuUser.values
        series.cpuSystem = liveHistory.cpuSystem.values
        series.perCore = liveHistory.perCore.map(\.values)
        series.loadAverage = liveHistory.loadAverage.values
        series.memory = liveHistory.memory.values
        series.memoryApp = liveHistory.memoryApp.values
        series.memoryWired = liveHistory.memoryWired.values
        series.memoryCompressed = liveHistory.memoryCompressed.values
        series.swap = liveHistory.swap.values
        series.gpu = liveHistory.gpu.values
        series.networkDown = liveHistory.networkDown.values
        series.networkUp = liveHistory.networkUp.values
        series.diskRead = liveHistory.diskRead.values
        series.diskWrite = liveHistory.diskWrite.values
        series.socTemperature = liveHistory.socTemperature.values
        series.fanRPM = liveHistory.fanRPM.values
        series.power = liveHistory.power.values
        series.batteryCharge = liveHistory.batteryCharge.values
        self.series = series
    }

    private func injectDemoStore(samples: Int) {
        // Samples already recorded sit at "now", and the store rejects anything
        // older than the bucket it is filling, so start from nothing.
        history.reset()
        let now = Date()
        let total = liveHistory.cpu.capacity

        // Structure at every zoom level: a daily rhythm, an hourly one, and
        // movement over minutes and seconds. A single frequency looks flat
        // as soon as the chart is zoomed past it.
        func wave(_ base: Double, _ amplitude: Double, _ phase: Double, _ x: Double) -> Double {
            let secondsAgo = 28 * 86_400.0 * (1 - x)
            let tau = 2 * Double.pi
            return max(0, base
                + amplitude * 0.45 * sin(secondsAgo / 86_400 * tau + phase)
                + amplitude * 0.28 * sin(secondsAgo / 12_000 * tau + phase * 1.7)
                + amplitude * 0.18 * sin(secondsAgo / 900 * tau + phase * 2.3)
                + amplitude * 0.12 * sin(secondsAgo / 90 * tau + phase * 3.1)
                + amplitude * 0.08 * sin(secondsAgo / 14 * tau + phase * 5.9))
        }

        // One chronological pass: the store rejects samples older than the
        // bucket it is filling, so the timestamps have to only move forward.
        // Coarse out to four weeks, then two-second detail for the last hour.
        // One sample per bucket of whichever tier that stretch belongs to, so
        // every range comes out as full as it would after a month of running.
        var schedule: [(date: Date, x: Double)] = []
        let span = 28 * 86_400.0
        func add(from: TimeInterval, to: TimeInterval, step: TimeInterval) {
            var seconds = from
            while seconds > to {
                schedule.append((now.addingTimeInterval(-seconds), 1 - seconds / span))
                seconds -= step
            }
        }
        add(from: span, to: 86_400, step: 900)     // quarter-hour tier
        add(from: 86_400, to: 3_600, step: 60)     // minute tier
        add(from: 3_600, to: 0, step: 2)           // live tier
        _ = total

        func fill() {
            for entry in schedule {
                let x = entry.x
                let date = entry.date
                history.record(Metric.cpu, wave(0.3, 0.2, 3, x), at: date)
                history.record(Metric.cpuUser, wave(0.22, 0.16, 2.2, x), at: date)
                history.record(Metric.cpuSystem, wave(0.08, 0.05, 3.1, x), at: date)
                history.record(Metric.load, wave(4, 3, 1.4, x), at: date)
                for core in 0..<liveHistory.perCore.count {
                    history.record(Metric.core(core),
                                   wave(core < 6 ? 0.45 : 0.2, 0.3, 2 + Double(core) * 0.4, x), at: date)
                }
                let memoryTotal = memoryMonitor.physicalMemory
                history.record(Metric.memory, wave(0.62, 0.12, 1.3, x), at: date)
                history.record(Metric.memoryApp, wave(memoryTotal * 0.28, memoryTotal * 0.06, 1.3, x), at: date)
                history.record(Metric.memoryWired, wave(memoryTotal * 0.14, memoryTotal * 0.02, 0.8, x), at: date)
                history.record(Metric.memoryCompressed, wave(memoryTotal * 0.2, memoryTotal * 0.08, 1.9, x), at: date)
                history.record(Metric.swap, wave(4e8, 3e8, 0.9, x), at: date)
                history.record(Metric.gpu, wave(0.18, 0.17, 3.3, x), at: date)
                history.record(Metric.networkDown, wave(2.2e6, 2.0e6, 2.4, x), at: date)
                history.record(Metric.networkUp, wave(4e5, 3.5e5, 3.0, x), at: date)
                history.record(Metric.diskRead, wave(1.4e7, 1.3e7, 1.8, x), at: date)
                history.record(Metric.diskWrite, wave(6e6, 5e6, 2.9, x), at: date)
                history.record(Metric.temperature, wave(56, 9, 1.6, x), at: date)
                history.record(Metric.ssdTemperature, wave(41, 6, 0.9, x), at: date)
                history.record(Metric.batteryTemperature, wave(28, 4, 0.6, x), at: date)
                history.record(Metric.power, wave(18, 9, 2.1, x), at: date)
                history.record(Metric.fan, wave(2600, 700, 1.2, x), at: date)
                history.record(Metric.efficiencyClock, wave(2200, 700, 2.4, x), at: date)
                history.record(Metric.performanceClock, wave(3200, 1200, 1.9, x), at: date)
                history.record(Metric.gpuClock, wave(700, 500, 2.8, x), at: date)
                history.record(Metric.battery, min(1, 0.55 + 0.4 * x), at: date)
            }
        }

        fill()
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

    // MARK: Sensor calibration

    private var calibrator: SensorCalibrator?

    public var isCalibrating: Bool { calibrationProgress != nil }

    /// Measures which thermal sensors follow which core cluster. Takes about
    /// two minutes of deliberate load, so it only runs when asked.
    public func calibrateSensors() {
        guard calibrator == nil else { return }
        let calibrator = SensorCalibrator()
        self.calibrator = calibrator
        calibrationProgress = SensorCalibrator.Progress(stage: "Starting", fraction: 0)

        queue.async { [weak self] in
            let result = calibrator.run { progress in
                Task { @MainActor in self?.calibrationProgress = progress }
            }
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.settings.sensorCalibration = result
                    self.sensorMonitor.calibration = result
                    self.sampleNow()
                }
                self.calibrationProgress = nil
                self.calibrator = nil
            }
        }
    }

    public func cancelCalibration() {
        calibrator?.cancel()
    }

    public func clearCalibration() {
        settings.sensorCalibration = nil
        sensorMonitor.calibration = nil
        sampleNow()
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
