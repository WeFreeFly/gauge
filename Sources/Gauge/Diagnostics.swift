import Foundation
import GaugeKit

enum GaugeVersion {
    static let string = "1.0"
}

/// Prints one full sampling pass. Two passes by default because every rate in
/// the app is a delta and the first pass has nothing to subtract from.
/// Fetches one forecast and prints it, so the provider plumbing can be checked
/// without turning the feature on in the UI. This is the one diagnostic that
/// makes a network request.
enum WeatherProbe {
    static func run(query: String) async {
        let provider = OpenMeteoProvider()
        print("Searching for \"\(query)\"…")
        do {
            let matches = try await provider.search(query: query, apiKey: nil)
            guard let match = matches.first else {
                print("No match.")
                return
            }
            print("  → \(match.displayName)  (\(match.latitude), \(match.longitude))")

            let location = WeatherLocation(name: match.name, latitude: match.latitude,
                                           longitude: match.longitude, country: match.country,
                                           timezone: match.timezone)
            let report = try await provider.fetch(location: location, apiKey: nil)
            print("\nNow: \(Format.temperature(report.now.temperature, unit: .celsius, decimals: 1))" +
                  "  \(report.now.condition.text)  [\(report.now.condition.symbolName)]")
            if let feels = report.now.feelsLike {
                print("  feels like \(Format.temperature(feels, unit: .celsius, decimals: 1))")
            }
            if let humidity = report.now.humidity { print("  humidity   \(Format.percent(humidity))") }
            if let wind = report.now.windSpeed { print(String(format: "  wind       %.0f km/h", wind)) }

            print("\nNext hours:")
            for hour in report.hourly.prefix(6) {
                print("  \(hour.date.formatted(date: .omitted, time: .shortened))  " +
                      "\(Format.temperature(hour.temperature, unit: .celsius))  \(hour.condition.text)")
            }
            print("\nForecast:")
            for day in report.daily.prefix(5) {
                print("  \(day.date.formatted(date: .abbreviated, time: .omitted))  " +
                      "\(Format.temperature(day.low, unit: .celsius))–\(Format.temperature(day.high, unit: .celsius))" +
                      "  \(day.condition.text)")
            }
            print("\n\(report.attribution)")
        } catch {
            print("Failed: \((error as? WeatherError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}

/// Times each collector. A system monitor that costs more than the things it
/// watches is not worth running, so this is the number that decides how often
/// each source may be sampled.
enum Benchmark {
    static func run(iterations: Int) {
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        let gpu = GPUMonitor()
        let disk = DiskMonitor()
        let network = NetworkMonitor()
        let sensors = SensorMonitor()
        let battery = BatteryMonitor()
        let processes = ProcessMonitor()

        var cases: [(String, () -> Void)] = [
            ("CPU", { _ = cpu.sample() }),
            ("Memory", { _ = memory.sample() }),
            ("GPU", { _ = gpu.sample() }),
            ("Disk", { _ = disk.sample() }),
            ("Network", { _ = network.sample() }),
            ("Sensors", { _ = sensors.sample() }),
            ("Battery", { _ = battery.sample() }),
            ("Processes", { _ = processes.sample() }),
        ]
        cases.append(("  ├ net counters", { _ = NetworkMonitor.interfaceCounters() }))
        cases.append(("  └ net addresses", { _ = NetworkMonitor.interfaceDetails(primary: nil) }))

        // The idle path: no panel open, so the slow collectors use their own
        // cadence. This is what the app actually costs most of the time.
        let idleSensors = SensorMonitor()
        idleSensors.backgroundInterval = 0            // measure the work, not the cache
        let idleDisk = DiskMonitor()
        idleDisk.volumeRefreshInterval = .infinity
        let idleNetwork = NetworkMonitor()
        idleNetwork.interfaceRefreshInterval = .infinity
        _ = idleDisk.sample(live: true)
        _ = idleNetwork.sample(live: true)
        cases.append(("  ⤷ sensors idle", { _ = idleSensors.sample(live: false) }))
        cases.append(("  ⤷ disk idle", { _ = idleDisk.sample(live: false) }))
        cases.append(("  ⤷ network idle", { _ = idleNetwork.sample(live: false) }))

        // Warm up so first-call setup does not land in the measurement.
        for entry in cases { entry.1() }

        print(String(format: "%-18@ %10@ %10@", "collector" as NSString,
                     "median" as NSString, "worst" as NSString))
        print(String(repeating: "─", count: 40))

        var total = 0.0
        for (name, work) in cases {
            var samples: [Double] = []
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                work()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            if !name.hasPrefix(" ") { total += median }
            print(String(format: "%-18@ %8.2f ms %8.2f ms", name as NSString, median, samples.last ?? 0))
        }
        print(String(repeating: "─", count: 40))
        print(String(format: "%-18@ %8.2f ms per pass", "total" as NSString, total))
        print(String(format: "at a 2 s interval that is %.2f%% of one core", total / 2000 * 100))
    }
}

enum DiagnosticsDump {
    static func run(passes: Int) {
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        let gpu = GPUMonitor()
        let disk = DiskMonitor()
        let network = NetworkMonitor()
        let sensors = SensorMonitor()
        let battery = BatteryMonitor()
        let processes = ProcessMonitor()

        for pass in 1...max(1, passes) {
            let cpuSample = cpu.sample()
            let memorySample = memory.sample()
            let gpuSample = gpu.sample()
            let diskSample = disk.sample()
            let networkSample = network.sample()
            let sensorSample = sensors.sample()
            let batterySample = battery.sample()
            let processSample = processes.sample(limit: 5)

            guard pass == passes else {
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }

            let hardware = HardwareInfo()
            print("=== Hardware ===")
            print("  model        \(hardware.modelIdentifier)")
            print("  chip         \(hardware.chip)")
            print("  cores        \(hardware.coreCount) " +
                  "(\(hardware.performanceCores) \(cpu.performanceClusterName) / " +
                  "\(hardware.efficiencyCores) \(cpu.efficiencyClusterName))")
            print("  memory       \(Format.bytes(hardware.memoryBytes))")
            print("  macOS        \(hardware.osVersion)")

            print("\n=== CPU ===")
            print("  total        \(Format.percent(cpuSample.total, decimals: 1))  " +
                  "(user \(Format.percent(cpuSample.user, decimals: 1)), sys \(Format.percent(cpuSample.system, decimals: 1)))")
            print("  \(cpu.performanceClusterName.padding(toLength: 12, withPad: " ", startingAt: 0)) " +
                  "\(Format.percent(cpuSample.performanceLoad, decimals: 1))  (\(cpu.performanceCoreCount) cores)")
            print("  \(cpu.efficiencyClusterName.padding(toLength: 12, withPad: " ", startingAt: 0)) " +
                  "\(Format.percent(cpuSample.efficiencyLoad, decimals: 1))  (\(cpu.efficiencyCoreCount) cores)")
            print("  load avg     " + String(format: "%.2f %.2f %.2f", cpuSample.loadAverage.one,
                                             cpuSample.loadAverage.five, cpuSample.loadAverage.fifteen))
            print("  uptime       \(Format.duration(cpuSample.uptime))")
            print("  processes    \(cpuSample.processCount) / threads \(processSample.threadCount)")
            print("  per-core     " + cpuSample.cores.map {
                "\($0.clusterName.prefix(1))\($0.id):\(Int($0.total * 100))%"
            }.joined(separator: " "))

            print("\n=== Memory ===")
            print("  used         \(Format.bytes(memorySample.used)) of \(Format.bytes(memorySample.total))" +
                  "  (\(Format.percent(memorySample.usedFraction, decimals: 1)))")
            print("  app          \(Format.bytes(memorySample.appMemory))")
            print("  wired        \(Format.bytes(memorySample.wired))")
            print("  compressed   \(Format.bytes(memorySample.compressed))")
            print("  cached       \(Format.bytes(memorySample.cachedFiles))")
            print("  swap         \(Format.bytes(memorySample.swapUsed)) of \(Format.bytes(memorySample.swapTotal))")
            print("  pressure     \(memorySample.pressure.label) (\(Format.percent(memorySample.pressureFraction, decimals: 1)))")

            print("\n=== GPU ===")
            if gpuSample.isAvailable {
                print("  \(gpuSample.name)")
                print("  device       \(Format.percent(gpuSample.utilization, decimals: 1))")
                print("  renderer     \(Format.percent(gpuSample.rendererUtilization, decimals: 1))")
                print("  tiler        \(Format.percent(gpuSample.tilerUtilization, decimals: 1))")
                print("  in use       \(Format.bytes(gpuSample.inUseMemory))")
            } else {
                print("  unavailable")
            }

            print("\n=== Disks ===")
            for volume in diskSample.volumes {
                print("  \(volume.name.padding(toLength: 18, withPad: " ", startingAt: 0)) " +
                      "\(Format.bytes(volume.used)) / \(Format.bytes(volume.total))  " +
                      "(\(Format.percent(volume.usedFraction))) at \(volume.path)")
            }
            print("  read         \(Format.rate(diskSample.activity.readRate))  total \(Format.bytes(diskSample.activity.readTotal))")
            print("  write        \(Format.rate(diskSample.activity.writeRate))  total \(Format.bytes(diskSample.activity.writeTotal))")

            print("\n=== Network ===")
            print("  down         \(Format.rate(networkSample.downloadRate))   up \(Format.rate(networkSample.uploadRate))")
            print("  since boot   in \(Format.bytes(networkSample.totalIn))  out \(Format.bytes(networkSample.totalOut))")
            print("  primary      \(networkSample.primaryInterface ?? "—")")
            for interface in networkSample.interfaces.prefix(6) {
                let addresses = (interface.ipv4 + interface.ipv6).joined(separator: ", ")
                print("  \(interface.name.padding(toLength: 8, withPad: " ", startingAt: 0)) " +
                      "\(interface.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(addresses)")
            }

            print("\n=== Sensors ===")
            if let soc = sensorSample.socTemperature {
                print("  CPU die avg  \(Format.temperature(soc, unit: .celsius, decimals: 1))")
            }
            if let peak = sensorSample.peakDieTemperature {
                print("  CPU die peak \(Format.temperature(peak, unit: .celsius, decimals: 1))")
            }
            if let storage = sensorSample.storageTemperature {
                print("  SSD          \(Format.temperature(storage, unit: .celsius, decimals: 1))")
            }
            if let batteryTemperature = sensorSample.batteryTemperature {
                print("  Battery      \(Format.temperature(batteryTemperature, unit: .celsius, decimals: 1))")
            }
            if let power = sensorSample.systemPower { print("  System power \(Format.power(power))") }
            if let adapter = sensorSample.adapterPower { print("  Adapter      \(Format.power(adapter))") }
            for fan in sensorSample.fans {
                print("  \(fan.name)          \(Int(fan.rpm)) rpm  (range \(Int(fan.minRPM))–\(Int(fan.maxRPM)))")
            }
            print("  sensors read \(sensorSample.readings.count)")

            print("\n=== Battery ===")
            if batterySample.isPresent {
                print("  charge       \(batterySample.chargePercent)%  \(batterySample.isCharging ? "charging" : (batterySample.isPluggedIn ? "plugged in" : "on battery"))")
                if let health = batterySample.health { print("  health       \(Format.percent(health, decimals: 1))") }
                if let cycles = batterySample.cycleCount { print("  cycles       \(cycles)") }
                if let capacity = batterySample.currentCapacity, let maximum = batterySample.maxCapacity {
                    print("  capacity     \(Int(capacity)) / \(Int(maximum)) mAh")
                }
                if let voltage = batterySample.voltage { print("  voltage      " + String(format: "%.2f V", voltage)) }
                if let amperage = batterySample.amperage { print("  current      " + String(format: "%.2f A", amperage)) }
                if let temperature = batterySample.temperature { print("  temperature  \(Format.temperature(temperature, unit: .celsius, decimals: 1))") }
                if let time = batterySample.timeToEmpty { print("  time to empty \(Format.duration(time))") }
                if let time = batterySample.timeToFull { print("  time to full  \(Format.duration(time))") }
            } else {
                print("  no battery")
            }

            print("\n=== Top processes (CPU) ===")
            for process in processSample.byCPU {
                print("  \(String(format: "%6.2f%%", process.cpu * 100))  " +
                      "\(Format.bytes(process.memory).padding(toLength: 10, withPad: " ", startingAt: 0)) " +
                      "\(process.name) (pid \(process.id))")
            }
            print("\n=== Top processes (memory) ===")
            for process in processSample.byMemory {
                print("  \(Format.bytes(process.memory).padding(toLength: 10, withPad: " ", startingAt: 0)) " +
                      "\(String(format: "%6.2f%%", process.cpu * 100))  \(process.name) (pid \(process.id))")
            }
        }
    }
}
