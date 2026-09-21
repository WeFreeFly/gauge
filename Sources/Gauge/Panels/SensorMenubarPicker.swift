import SwiftUI
import GaugeKit

/// The Sensors menu bar choice, as rows for the shared picker.
struct SensorMenubarPicker: View {
    var style: MenubarReadingPicker.Style = .compact

    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let sensors = hub.snapshot.sensors
        MenubarReadingPicker(
            style: style,
            rows: SensorMenubarItem.allCases.map { item in
                let needsCalibration = item.requiresCalibration && settings.sensorCalibration == nil
                return MenubarReadingPicker.Row(
                    id: item.rawValue,
                    title: item.title(performanceCluster: hub.performanceClusterName,
                                      efficiencyCluster: hub.efficiencyClusterName),
                    shortTitle: item.shortTitle(performanceCluster: hub.performanceClusterName,
                                                efficiencyCluster: hub.efficiencyClusterName),
                    value: needsCalibration
                        ? nil
                        : item.formatted(from: sensors, unit: settings.temperatureUnit)
                            .map { item.shortPrefix + $0 },
                    unavailableReason: needsCalibration ? "needs calibration" : nil,
                    isSelected: settings.sensorMenubarItems.contains(item),
                    toggle: { settings.toggleSensorMenubarItem(item) })
            },
            maximum: SensorMenubarItem.maximumSelected,
            reset: { settings.sensorMenubarItems = SensorMenubarItem.standard }
        )
    }
}

/// The Combined menu bar choice, which draws on every module.
struct CombinedMenubarPicker: View {
    var style: MenubarReadingPicker.Style = .compact

    @EnvironmentObject private var hub: MonitorHub
    @EnvironmentObject private var settings: GaugeSettings

    var body: some View {
        let snapshot = hub.snapshot
        MenubarReadingPicker(
            style: style,
            rows: CombinedMenubarItem.allCases.map { item in
                MenubarReadingPicker.Row(
                    id: item.rawValue,
                    title: item.title(performanceCluster: hub.performanceClusterName,
                                      efficiencyCluster: hub.efficiencyClusterName),
                    shortTitle: item.shortTitle(performanceCluster: hub.performanceClusterName,
                                                efficiencyCluster: hub.efficiencyClusterName),
                    value: item.formatted(from: snapshot,
                                          temperatureUnit: settings.temperatureUnit,
                                          networkInBits: settings.networkUnitBits),
                    unavailableReason: nil,
                    isSelected: settings.combinedMenubarItems.contains(item),
                    toggle: { settings.toggleCombinedMenubarItem(item) })
            },
            maximum: CombinedMenubarItem.maximumSelected,
            reset: { settings.combinedMenubarItems = CombinedMenubarItem.standard }
        )
    }
}
