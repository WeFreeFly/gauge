import Foundation
import GaugeKit

/// Works out which thermal sensors actually respond to CPU work.
///
/// Apple ships no documentation for the `PMU tdie*` names, so the honest way
/// to decide which ones deserve to be called a CPU temperature is to measure
/// it: load one core cluster at a time and see where the heat appears. On a
/// Mac17,2 the PMU die sensors rise 7–19 °C while the PMU2 ones move under
/// 1.5 °C, which is why only the first set feeds the CPU reading.
///
/// Thread QoS is the lever: background work is confined to the efficiency
/// cores, user-interactive work prefers the fast ones.
enum SensorMapping {
    static func run() {
        let monitor = SensorMonitor()
        let cpu = CPUMonitor()

        print("""
              Mapping thermal sensors to core clusters
              \(cpu.brand) — \(cpu.performanceCoreCount) \(cpu.performanceClusterName) \
              + \(cpu.efficiencyCoreCount) \(cpu.efficiencyClusterName)

              This loads the machine for about two minutes.
              """)

        print("\nSettling…")
        Thread.sleep(forTimeInterval: 12)
        let baseline = average(monitor, samples: 6)

        print("Loading \(cpu.efficiencyClusterName) cores…")
        load(threads: max(2, cpu.efficiencyCoreCount), qos: .background, seconds: 30) {
            Thread.sleep(forTimeInterval: 24)
        }
        let efficiency = average(monitor, samples: 6)

        print("Cooling…")
        Thread.sleep(forTimeInterval: 30)
        let cooled = average(monitor, samples: 6)

        print("Loading \(cpu.performanceClusterName) cores…")
        load(threads: max(2, cpu.performanceCoreCount), qos: .userInteractive, seconds: 30) {
            Thread.sleep(forTimeInterval: 24)
        }
        let performance = average(monitor, samples: 6)

        report(baseline: baseline, efficiency: efficiency, cooled: cooled, performance: performance,
               efficiencyName: cpu.efficiencyClusterName, performanceName: cpu.performanceClusterName)
    }

    // MARK: Measurement

    private static func average(_ monitor: SensorMonitor, samples: Int) -> [String: Double] {
        var totals: [String: [Double]] = [:]
        for _ in 0..<samples {
            for reading in monitor.sample().readings where reading.kind == .temperature {
                totals[reading.name, default: []].append(reading.value)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return totals.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    private static func load(threads: Int, qos: DispatchQoS.QoSClass,
                             seconds: Double, whileRunning: () -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        for _ in 0..<threads {
            DispatchQueue(label: "gauge.load", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
                .async {
                    var accumulator = 0.0
                    while Date() < deadline {
                        for i in 0..<200_000 { accumulator += Double(i).squareRoot() }
                    }
                    // Keep the optimiser from deleting the loop.
                    if accumulator == .infinity { print("") }
                }
        }
        whileRunning()
    }

    // MARK: Output

    private static func report(baseline: [String: Double], efficiency: [String: Double],
                               cooled: [String: Double], performance: [String: Double],
                               efficiencyName: String, performanceName: String) {
        let header = String(format: "%-20@ %7@ %8@ %8@  %@",
                            "sensor" as NSString, "idle" as NSString,
                            "Δ\(efficiencyName.prefix(4))" as NSString,
                            "Δ\(performanceName.prefix(4))" as NSString,
                            "verdict" as NSString)
        print("\n" + header)
        print(String(repeating: "─", count: 68))

        struct Row {
            let name: String
            let base: Double
            let deltaEfficiency: Double
            let deltaPerformance: Double
            var response: Double { max(deltaEfficiency, deltaPerformance) }
        }

        let rows = baseline.keys.map { name in
            Row(name: name,
                base: baseline[name] ?? 0,
                deltaEfficiency: (efficiency[name] ?? 0) - (baseline[name] ?? 0),
                deltaPerformance: (performance[name] ?? 0) - (cooled[name] ?? 0))
        }
        .sorted { $0.response > $1.response }

        for row in rows {
            // A sensor that moves several degrees under load is on the compute
            // die; one that barely moves is measuring something else.
            let verdict: String
            switch row.response {
            case 5...:   verdict = "tracks CPU load"
            case 2..<5:  verdict = "partly affected"
            default:     verdict = "unrelated to CPU"
            }
            let bias: String
            if row.response >= 5, row.deltaEfficiency > 0 {
                let ratio = row.deltaPerformance / max(0.1, row.deltaEfficiency)
                if ratio > 1.4 { bias = "  (leans \(performanceName))" }
                else if ratio < 0.85 { bias = "  (leans \(efficiencyName))" }
                else { bias = "" }
            } else {
                bias = ""
            }
            print(String(format: "%-20@ %6.1f° %+7.1f° %+7.1f°  %@%@",
                         row.name as NSString, row.base,
                         row.deltaEfficiency, row.deltaPerformance,
                         verdict as NSString, bias as NSString))
        }

        print("""

              A sensor rising several degrees when a cluster is loaded sits on \
              the compute die. Heat spreads across that die, so every sensor on \
              it responds to both clusters — which is why Gauge reports a die \
              average and a peak rather than pretending to name a temperature \
              per core.
              """)
    }
}
