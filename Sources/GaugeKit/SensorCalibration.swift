import Foundation

/// Which part of the chip a thermal sensor actually responds to.
///
/// Apple publishes nothing about the `PMU tdie*` names, so this is measured:
/// load one core cluster at a time and see where the heat turns up. A sensor
/// sitting over the fast cluster warms further when that cluster is busy.
public enum SensorAffinity: String, Codable, Sendable, CaseIterable {
    /// Rises noticeably more under the fast cluster's load.
    case performance
    /// Rises noticeably more under the efficient cluster's load.
    case efficiency
    /// On the compute die, but responds to both about equally.
    case shared
    /// Barely moves under CPU load at all.
    case unrelated
}

/// One sensor's measured response, in degrees above its idle reading.
public struct SensorResponse: Codable, Sendable, Identifiable {
    public var id: String { sensor }
    public var sensor: String
    public var idle: Double
    public var deltaEfficiency: Double
    public var deltaPerformance: Double

    public init(sensor: String, idle: Double, deltaEfficiency: Double, deltaPerformance: Double) {
        self.sensor = sensor
        self.idle = idle
        self.deltaEfficiency = deltaEfficiency
        self.deltaPerformance = deltaPerformance
    }

    /// The larger of the two responses: how much this sensor cares about the
    /// CPU at all.
    public var response: Double { max(deltaEfficiency, deltaPerformance) }

    /// Above 1 means the fast cluster moves it more.
    public var ratio: Double { deltaPerformance / max(0.2, deltaEfficiency) }

    public var affinity: SensorAffinity {
        // Below two degrees the sensor is measuring something else, and the
        // ratio of two small numbers is noise.
        guard response >= 2 else { return .unrelated }
        if ratio >= 1.35 { return .performance }
        if ratio <= 0.95 { return .efficiency }
        return .shared
    }
}

/// The result of a calibration run, kept so the labels survive a restart.
public struct SensorCalibration: Codable, Sendable {
    public var responses: [SensorResponse]
    public var performanceClusterName: String
    public var efficiencyClusterName: String
    public var machineModel: String
    public var measuredAt: Date

    public init(responses: [SensorResponse], performanceClusterName: String,
                efficiencyClusterName: String, machineModel: String, measuredAt: Date = Date()) {
        self.responses = responses
        self.performanceClusterName = performanceClusterName
        self.efficiencyClusterName = efficiencyClusterName
        self.machineModel = machineModel
        self.measuredAt = measuredAt
    }

    private var index: [String: SensorResponse] {
        Dictionary(responses.map { ($0.sensor, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func affinity(for sensor: String) -> SensorAffinity? {
        index[sensor]?.affinity
    }

    public func response(for sensor: String) -> SensorResponse? {
        index[sensor]
    }

    /// A calibration from another Mac says nothing about this one.
    public func applies(to model: String) -> Bool {
        machineModel == model
    }

    public func clusterName(for affinity: SensorAffinity) -> String {
        switch affinity {
        case .performance: performanceClusterName
        case .efficiency: efficiencyClusterName
        case .shared: "Shared"
        case .unrelated: ""
        }
    }
}

// MARK: - Running a calibration

/// Loads one cluster at a time and records how each sensor responds.
///
/// This costs about two minutes of full CPU load, so it is only ever run when
/// asked for. Progress is reported so the caller can show where it is up to.
public final class SensorCalibrator: @unchecked Sendable {
    public struct Progress: Sendable {
        public var stage: String
        public var fraction: Double
    }

    public enum Stage: CaseIterable {
        case settling, loadingEfficiency, cooling, loadingPerformance, done
    }

    private let sensors = SensorMonitor()
    private let cpu = CPUMonitor()
    private var cancelled = false
    private let lock = NSLock()

    /// Seconds spent in each phase. Shorter runs are noisier; these are the
    /// shortest values that gave a stable split on a Mac17,2.
    public var settleSeconds: TimeInterval = 12
    public var loadSeconds: TimeInterval = 30
    public var coolSeconds: TimeInterval = 30

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var totalSeconds: TimeInterval {
        settleSeconds + loadSeconds * 2 + coolSeconds + 6
    }

    /// Runs the whole measurement. Blocking; call it off the main thread.
    public func run(progress: @escaping @Sendable (Progress) -> Void) -> SensorCalibration? {
        let performanceName = cpu.performanceClusterName
        let efficiencyName = cpu.efficiencyClusterName
        var elapsed: TimeInterval = 0
        let total = totalSeconds

        func report(_ stage: String) {
            progress(Progress(stage: stage, fraction: (elapsed / total).clamped(to: 0...1)))
        }

        report("Settling")
        guard wait(settleSeconds, &elapsed, total, "Settling", progress) else { return nil }
        let baseline = average(samples: 6, elapsed: &elapsed, total: total,
                               stage: "Reading idle temperatures", progress: progress)

        report("Loading \(efficiencyName) cores")
        load(threads: max(2, cpu.efficiencyCoreCount), qos: .background, seconds: loadSeconds)
        guard wait(loadSeconds - 6, &elapsed, total, "Loading \(efficiencyName) cores", progress) else { return nil }
        let efficiency = average(samples: 6, elapsed: &elapsed, total: total,
                                 stage: "Measuring \(efficiencyName)", progress: progress)

        guard wait(coolSeconds, &elapsed, total, "Cooling down", progress) else { return nil }
        let cooled = average(samples: 6, elapsed: &elapsed, total: total,
                             stage: "Reading idle temperatures", progress: progress)

        report("Loading \(performanceName) cores")
        load(threads: max(2, cpu.performanceCoreCount), qos: .userInteractive, seconds: loadSeconds)
        guard wait(loadSeconds - 6, &elapsed, total, "Loading \(performanceName) cores", progress) else { return nil }
        let performance = average(samples: 6, elapsed: &elapsed, total: total,
                                  stage: "Measuring \(performanceName)", progress: progress)

        let responses = baseline.keys.sorted().map { sensor in
            SensorResponse(
                sensor: sensor,
                idle: baseline[sensor] ?? 0,
                deltaEfficiency: (efficiency[sensor] ?? 0) - (baseline[sensor] ?? 0),
                // Compare against the cooled reading, not the original idle:
                // the machine does not return to exactly where it started.
                deltaPerformance: (performance[sensor] ?? 0) - (cooled[sensor] ?? 0))
        }

        progress(Progress(stage: "Done", fraction: 1))
        return SensorCalibration(responses: responses,
                                 performanceClusterName: performanceName,
                                 efficiencyClusterName: efficiencyName,
                                 machineModel: sysctlString("hw.model") ?? "Mac")
    }

    // MARK: Phases

    private func wait(_ seconds: TimeInterval, _ elapsed: inout TimeInterval,
                      _ total: TimeInterval, _ stage: String,
                      _ progress: @escaping @Sendable (Progress) -> Void) -> Bool {
        let step = 0.5
        var remaining = seconds
        while remaining > 0 {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: min(step, remaining))
            remaining -= step
            elapsed += step
            progress(Progress(stage: stage, fraction: (elapsed / total).clamped(to: 0...1)))
        }
        return true
    }

    private func average(samples: Int, elapsed: inout TimeInterval, total: TimeInterval,
                         stage: String, progress: @escaping @Sendable (Progress) -> Void) -> [String: Double] {
        var totals: [String: [Double]] = [:]
        for _ in 0..<samples {
            for reading in sensors.sample().readings where reading.kind == .temperature {
                // Several sensors share a name; the hottest is the meaningful one.
                totals[reading.rawName, default: []].append(reading.value)
            }
            Thread.sleep(forTimeInterval: 0.4)
            elapsed += 0.4
            progress(Progress(stage: stage, fraction: (elapsed / total).clamped(to: 0...1)))
        }
        return totals.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    /// Thread QoS is the only public lever for choosing a cluster: background
    /// work is confined to the efficiency cores, user-interactive work prefers
    /// the fast ones.
    private func load(threads: Int, qos: DispatchQoS.QoSClass, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        for _ in 0..<threads {
            DispatchQueue(label: "gauge.calibration", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
                .async { [weak self] in
                    var accumulator = 0.0
                    while Date() < deadline, self?.isCancelled == false {
                        for i in 0..<200_000 { accumulator += Double(i).squareRoot() }
                    }
                    if accumulator == .infinity { print("") }   // keep the loop
                }
        }
    }
}
