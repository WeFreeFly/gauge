// SPDX-License-Identifier: Apache-2.0
import Foundation
import GaugeKit

/// Command-line front end for `SensorCalibrator`.
///
/// The measurement itself lives in GaugeKit so the settings window and this
/// command cannot drift apart; this only prints the result and saves it, so a
/// calibration run from the terminal also relabels the sensors in the app.
enum SensorMapping {
    static func run(save: Bool) {
        let cpu = CPUMonitor()
        let calibrator = SensorCalibrator()

        print("""
              Mapping thermal sensors to core clusters
              \(cpu.brand) — \(cpu.performanceCoreCount) \(cpu.performanceClusterName) \
              + \(cpu.efficiencyCoreCount) \(cpu.efficiencyClusterName)

              This loads the machine for about \(Int(calibrator.totalSeconds)) seconds.
              """)

        var lastStage = ""
        guard let calibration = calibrator.run(progress: { progress in
            guard progress.stage != lastStage else { return }
            lastStage = progress.stage
            print(String(format: "  [%3.0f%%] %@", progress.fraction * 100, progress.stage as NSString))
        }) else {
            print("Cancelled.")
            return
        }

        report(calibration)

        if save {
            let settings = GaugeSettings()
            settings.sensorCalibration = calibration
            settings.save()
            print("\nSaved. Gauge will label these sensors by cluster.")
        } else {
            print("\nNot saved. Pass --save to keep the result.")
        }
    }

    private static func report(_ calibration: SensorCalibration) {
        let efficiency = calibration.efficiencyClusterName
        let performance = calibration.performanceClusterName

        print("\n" + String(format: "%-20@ %7@ %9@ %9@  %@",
                            "sensor" as NSString, "idle" as NSString,
                            "Δ\(efficiency.prefix(5))" as NSString,
                            "Δ\(performance.prefix(5))" as NSString,
                            "verdict" as NSString))
        print(String(repeating: "─", count: 74))

        for response in calibration.responses.sorted(by: { $0.response > $1.response }) {
            let verdict: String = switch response.affinity {
            case .performance: "\(performance) area"
            case .efficiency: "\(efficiency) area"
            case .shared: "shared die"
            case .unrelated: "unrelated to CPU"
            }
            let ratio = response.affinity == .unrelated ? "" : String(format: "   ratio %.2f", response.ratio)
            print(String(format: "%-20@ %6.1f° %+8.1f° %+8.1f°  %@%@",
                         SensorMonitor.displayName(forSensorNamed: response.sensor) as NSString,
                         response.idle, response.deltaEfficiency, response.deltaPerformance,
                         verdict as NSString, ratio as NSString))
        }

        print("""

              Heat spreads across a die, so every sensor on it responds to both \
              clusters. The split above is by which one moves it more — an affinity, \
              not a per-core mapping.
              """)
    }
}
