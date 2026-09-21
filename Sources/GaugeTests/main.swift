import Foundation
import GaugeKit

let t = Harness()

/// The calibration is machine-specific, so the round-trip test needs the same
/// model string the settings loader checks against.
func sysctlStringForTests(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "Mac" }
    return String(cString: buffer)
}

// MARK: - Ring buffer

t.suite("RingBuffer") {
    t.test("keeps oldest-first order while filling") {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...3 { buffer.append(value) }
        t.equal(buffer.values, [1, 2, 3])
        t.equal(buffer.count, 3)
    }

    t.test("drops the oldest sample once full") {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...6 { buffer.append(value) }
        t.equal(buffer.values, [4, 5, 6])
        t.equal(buffer.last, 6)
    }

    t.test("is empty before the first sample") {
        let buffer = RingBuffer<Double>(capacity: 8)
        t.expect(buffer.values.isEmpty, "expected no values")
        t.isNil(buffer.last)
    }

    t.test("never has zero capacity") {
        var buffer = RingBuffer<Int>(capacity: 0)
        buffer.append(1)
        t.equal(buffer.values, [1])
    }

    t.test("survives more writes than capacity many times over") {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 1...1000 { buffer.append(value) }
        t.equal(buffer.values, [996, 997, 998, 999, 1000])
    }
}

// MARK: - Formatting

t.suite("Format") {
    t.test("byte sizes use binary units") {
        t.equal(Format.bytes(0), "0 B")
        t.equal(Format.bytes(1024), "1.00 KB")
        t.equal(Format.bytes(16 * 1024 * 1024 * 1024), "16.0 GB")
    }

    t.test("rates shorten as they grow") {
        t.equal(Format.rate(0), "0 B/s")
        t.equal(Format.rate(2048), "2.0 K/s")
        t.equal(Format.rate(5 * 1024 * 1024), "5.0 M/s")
    }

    t.test("negative rates clamp to zero") {
        t.equal(Format.rate(-500), "0 B/s")
    }

    t.test("percentages clamp to 0–100") {
        t.equal(Format.percent(0.5), "50%")
        t.equal(Format.percent(1.7), "100%")
        t.equal(Format.percent(-0.2), "0%")
    }

    t.test("temperatures convert") {
        t.equal(Format.temperature(100, unit: .celsius), "100°C")
        t.equal(Format.temperature(100, unit: .fahrenheit), "212°F")
    }

    t.test("durations pick the largest useful unit") {
        t.equal(Format.duration(90 * 60), "1h 30m")
        t.equal(Format.duration(26 * 3600), "1d 2h")
        t.equal(Format.duration(0), "—")
    }

    t.test("division by an empty interval yields zero, not infinity") {
        t.close(10.0.safeDivided(by: 0), 0)
        t.close(10.0.safeDivided(by: 2), 5)
    }
}

// MARK: - SMC decoding

// Getting these wrong is silent: the value still looks plausible. The cases
// below use bytes read from a real Mac17,2.
t.suite("SMC decoding") {
    func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        SMC.decode(SMC.Value(type: type, bytes: bytes))
    }

    t.test("float keys are little-endian IEEE 754") {
        t.close(decode("flt", [0x00, 0xb0, 0xcc, 0x45]) ?? 0, 6550, accuracy: 0.01)   // F0Mx
        t.close(decode("flt", [0x00, 0xd0, 0x10, 0x45]) ?? 0, 2317, accuracy: 0.01)   // F0Mn
    }

    t.test("single-byte keys respect their sign") {
        t.equal(decode("ui8", [99]), 99)
        t.equal(decode("si8", [0xff]), -1)
        t.equal(decode("flag", [1]), 1)
    }

    t.test("word keys follow the architecture's byte order") {
        let value = decode("ui16", [0x7d, 0x18])     // B0FC = 6269 mAh
        #if arch(arm64)
        t.equal(value, 6269)
        #else
        t.equal(value, 32024)
        #endif
    }

    t.test("legacy fixed-point keys stay big-endian") {
        t.close(decode("sp78", [0x2d, 0x80]) ?? 0, 45.5)
        t.close(decode("fpe2", [0x0b, 0xb8]) ?? 0, 750)
    }

    t.test("unknown or truncated values return nil instead of a guess") {
        t.isNil(decode("hex_", [1, 2, 3, 4, 5]))
        t.isNil(decode("flt", [0x01]))
        t.isNil(decode("ui16", []))
    }

    t.test("four-character codes round-trip") {
        t.equal(SMC.fourCharString(0x666c7420), "flt")
        t.equal(SMC.fourCharString(0x75693136), "ui16")
    }
}

// MARK: - Sensor naming

t.suite("Sensor naming") {
    // The split below is what the --map-sensors measurement showed: the
    // PMU die sensors follow CPU load, the PMU2 ones do not, so only the
    // first set may be called a CPU temperature.
    t.test("only the compute die counts as CPU") {
        t.equal(SensorMonitor.group(forSensorNamed: "PMU tdie5"), .cpu)
        t.equal(SensorMonitor.group(forSensorNamed: "PMU2 tdie3"), .package)
        t.equal(SensorMonitor.group(forSensorNamed: "PMU tdev1"), .board)
        t.equal(SensorMonitor.group(forSensorNamed: "NAND CH0 temp"), .storage)
        t.equal(SensorMonitor.group(forSensorNamed: "gas gauge battery"), .battery)
    }

    t.test("names become readable") {
        t.equal(SensorMonitor.displayName(forSensorNamed: "PMU tdie5"), "CPU Die 5")
        t.equal(SensorMonitor.displayName(forSensorNamed: "PMU2 tdie3"), "Package Die 3")
        t.equal(SensorMonitor.displayName(forSensorNamed: "PMU tdev1"), "Board Sensor 1")
        t.equal(SensorMonitor.displayName(forSensorNamed: "PMU2 tdev2"), "Board 2 Sensor 2")
        t.equal(SensorMonitor.displayName(forSensorNamed: "gas gauge battery"), "Battery Cell")
        t.equal(SensorMonitor.displayName(forSensorNamed: "NAND CH0 temp"), "SSD CH0 temp")
    }

    t.test("the CPU average excludes sensors that ignore CPU load") {
        let sample = SensorMonitor().sample()
        let cpuDie = sample.readings.filter { $0.group == .cpu }.map(\.value)
        guard !cpuDie.isEmpty else { return }
        let expected = cpuDie.reduce(0, +) / Double(cpuDie.count)
        t.close(sample.socTemperature ?? 0, expected, accuracy: 0.01)
        t.close(sample.peakDieTemperature ?? 0, cpuDie.max() ?? 0, accuracy: 0.01)
        // Package sensors sit a few degrees cooler and would drag the mean down.
        t.expect(!sample.readings.contains { $0.group == .cpu && $0.name.hasPrefix("Package") },
                 "package sensors must not be counted as CPU")
    }

    t.test("the primary die sorts above the board and the second die") {
        let primary = SensorMonitor.order(forSensorNamed: "PMU tdie1")
        let board = SensorMonitor.order(forSensorNamed: "PMU tdev1")
        let secondary = SensorMonitor.order(forSensorNamed: "PMU2 tdie1")
        t.expect(primary < board, "primary die should precede board sensors")
        t.expect(board < secondary, "board sensors should precede the second die")
    }

    t.test("numbered sensors sort naturally, not lexically") {
        var snapshot = SensorSnapshot()
        for name in ["PMU tdie10", "PMU tdie2", "PMU tdie1"] {
            snapshot.readings.append(SensorReading(
                id: name,
                name: SensorMonitor.displayName(forSensorNamed: name),
                group: .cpu, kind: .temperature, value: 40,
                order: SensorMonitor.order(forSensorNamed: name)))
        }
        t.equal(snapshot.grouped.first?.readings.map(\.name) ?? [],
                ["CPU Die 1", "CPU Die 2", "CPU Die 10"])
    }

    t.test("sensors sharing a name are numbered apart") {
        // Six of this Mac's sensors all report "gas gauge battery".
        var readings = (0..<3).map {
            SensorReading(id: "b\($0)", name: "Battery Cell", group: .battery,
                          kind: .temperature, value: 30)
        }
        readings.append(SensorReading(id: "s", name: "SSD CH0 temp", group: .storage,
                                      kind: .temperature, value: 40))
        SensorMonitor.numberDuplicateNames(in: &readings)

        t.equal(readings.prefix(3).map(\.name), ["Battery Cell 1", "Battery Cell 2", "Battery Cell 3"])
        t.equal(readings.last?.name, "SSD CH0 temp", "a unique name is left alone")
    }

    t.test("the same name in different groups is not merged") {
        var readings = [
            SensorReading(id: "a", name: "Die 1", group: .cpu, kind: .temperature, value: 50),
            SensorReading(id: "b", name: "Die 1", group: .package, kind: .temperature, value: 40),
        ]
        SensorMonitor.numberDuplicateNames(in: &readings)
        t.equal(readings.map(\.name), ["Die 1", "Die 1"], "different groups, no clash")
    }

    t.test("live readings carry no duplicate names within a group") {
        let sample = SensorMonitor().sample()
        var seen = Set<String>()
        for reading in sample.readings {
            let key = "\(reading.group.rawValue)|\(reading.name)"
            t.expect(!seen.contains(key), "duplicate row: \(key)")
            seen.insert(key)
        }
    }

    t.test("fan load is measured against the fan's own envelope") {
        let fan = FanReading(id: 0, name: "Fan", rpm: 4433, minRPM: 2317, maxRPM: 6550, targetRPM: nil)
        t.close(fan.loadFraction, 0.5, accuracy: 0.01)

        let stopped = FanReading(id: 0, name: "Fan", rpm: 0, minRPM: 2317, maxRPM: 6550, targetRPM: nil)
        t.close(stopped.loadFraction, 0)
    }

    t.test("readings format according to their kind") {
        let temperature = SensorReading(id: "a", name: "Die", group: .cpu, kind: .temperature, value: 51)
        t.equal(temperature.formatted(temperatureUnit: .celsius), "51°C")
        t.equal(temperature.formatted(temperatureUnit: .fahrenheit), "124°F")

        let fan = SensorReading(id: "b", name: "Fan", group: .fans, kind: .fan, value: 2499)
        t.equal(fan.formatted(temperatureUnit: .celsius), "2499 rpm")
    }
}

// MARK: - Weather mapping

t.suite("Weather mapping") {
    t.test("WMO codes become distinct conditions") {
        t.equal(WMOCode.condition(for: 0, isDay: true).text, "Clear")
        t.equal(WMOCode.condition(for: 3, isDay: true).text, "Overcast")
        t.equal(WMOCode.condition(for: 61, isDay: true).text, "Rain")
        t.equal(WMOCode.condition(for: 95, isDay: true).text, "Thunderstorm")
    }

    t.test("night uses night symbols") {
        t.equal(WMOCode.condition(for: 0, isDay: false).symbolName, "moon.stars")
        t.equal(WMOCode.condition(for: 2, isDay: false).symbolName, "cloud.moon")
    }

    t.test("an unrecognised code does not pretend to know") {
        let condition = WMOCode.condition(for: 4242, isDay: true)
        t.equal(condition.text, "Unknown")
        t.equal(condition.symbolName, "questionmark.circle")
    }

    t.test("both providers speak the same symbol vocabulary") {
        t.equal(AccuWeatherProvider.condition(icon: 1, text: "Sunny", isDay: true).symbolName, "sun.max")
        t.equal(AccuWeatherProvider.condition(icon: 1, text: "Clear", isDay: false).symbolName, "moon.stars")
        t.equal(AccuWeatherProvider.condition(icon: 18, text: "Rain", isDay: true).symbolName, "cloud.rain")
    }

    t.test("only AccuWeather needs a key") {
        t.expect(!WeatherProviderID.openMeteo.requiresKey, "Open-Meteo should need no key")
        t.expect(WeatherProviderID.accuWeather.requiresKey, "AccuWeather should need a key")
    }
}

// MARK: - Settings

t.suite("Settings") {
    func freshDefaults() -> UserDefaults {
        let suite = "gauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    t.test("ships with a usable default layout") {
        let settings = GaugeSettings(defaults: freshDefaults())
        t.expect(!settings.enabledModules.isEmpty, "at least one module should be on")
        t.expect(settings.enabledModules.contains(.cpu), "CPU should be on by default")
    }

    t.test("nothing that talks to a server is on by default") {
        let settings = GaugeSettings(defaults: freshDefaults())
        t.expect(!settings.weatherEnabled, "weather should be opt-in")
        t.expect(!settings.publicIPEnabled, "public IP lookup should be opt-in")
    }

    t.test("round-trips through UserDefaults") {
        let defaults = freshDefaults()
        let settings = GaugeSettings(defaults: defaults)
        settings.temperatureUnit = .fahrenheit
        settings.updateInterval = 5
        settings.setModule(.gpu) { $0.enabled = true; $0.style = .graph }
        settings.weatherLocation = WeatherLocation(name: "Bangkok", latitude: 13.75, longitude: 100.5)
        settings.save()

        let reloaded = GaugeSettings(defaults: defaults)
        t.equal(reloaded.temperatureUnit, .fahrenheit)
        t.close(reloaded.updateInterval, 5)
        t.expect(reloaded.module(.gpu).enabled, "GPU should still be enabled")
        t.equal(reloaded.module(.gpu).style, .graph)
        t.equal(reloaded.weatherLocation?.name, "Bangkok")
    }

    t.test("graph colours round-trip and can be reset") {
        let defaults = freshDefaults()
        let settings = GaugeSettings(defaults: defaults)
        let original = settings.graph(.cpu)

        settings.setGraph(.cpu) {
            $0.primaryHex = "#FF2D55"
            $0.fade = .duotone
            $0.fadeOpacity = 0.8
            $0.showsLine = false
            $0.usesLoadColor = false
        }
        settings.panel = PanelAppearance(material: .clearGlass, tintHex: "#0A84FF",
                                         tintStrength: 0.3, cornerRadius: 18)
        settings.menubarGraphWidth = 48
        settings.save()

        let reloaded = GaugeSettings(defaults: defaults)
        t.equal(reloaded.graph(.cpu).primaryHex, "#FF2D55")
        t.equal(reloaded.graph(.cpu).fade, .duotone)
        t.close(reloaded.graph(.cpu).fadeOpacity, 0.8)
        t.expect(!reloaded.graph(.cpu).showsLine, "line toggle should persist")
        t.equal(reloaded.panel.material, .clearGlass)
        t.equal(reloaded.panel.tintHex, "#0A84FF")
        t.close(reloaded.panel.tintStrength, 0.3)
        t.close(reloaded.panel.cornerRadius, 18)
        t.close(reloaded.menubarGraphWidth, 48)

        reloaded.resetGraph(.cpu)
        t.equal(reloaded.graph(.cpu), original, "reset should restore the shipped default")
    }

    t.test("panel tint is ignored until it has both a colour and strength") {
        var panel = PanelAppearance(tintHex: "", tintStrength: 0.5)
        t.isNil(panel.tint, "no colour means no tint")

        panel = PanelAppearance(tintHex: "#FF2D55", tintStrength: 0)
        t.isNil(panel.tint, "zero strength means no tint")

        panel = PanelAppearance(tintHex: "#FF2D55", tintStrength: 0.4)
        t.notNil(panel.tint, "a colour with strength should tint")
    }

    t.test("glass materials are recognised as glass") {
        t.expect(PanelMaterial.liquidGlass.usesGlass, "liquid glass")
        t.expect(PanelMaterial.clearGlass.usesGlass, "clear glass")
        t.expect(!PanelMaterial.vibrant.usesGlass, "vibrancy is not glass")
        t.expect(!PanelMaterial.opaque.usesGlass, "solid is not glass")
    }

    t.test("every module ships with a colour of its own") {
        let settings = GaugeSettings(defaults: freshDefaults())
        for module in ModuleID.allCases {
            let look = settings.graph(module)
            t.notNil(RGBAColor(hex: look.primaryHex), "\(module.title) primary")
            t.notNil(RGBAColor(hex: look.secondaryHex), "\(module.title) secondary")
        }
    }

    t.test("history capacity tracks the retention window") {
        let settings = GaugeSettings(defaults: freshDefaults())
        settings.updateInterval = 2
        settings.historyMinutes = 10
        t.equal(settings.historyCapacity, 300)

        settings.updateInterval = 1
        t.equal(settings.historyCapacity, 600)
    }

    t.test("history never collapses to an unusable window") {
        let settings = GaugeSettings(defaults: freshDefaults())
        settings.updateInterval = 10
        settings.historyMinutes = 5
        t.expect(settings.historyCapacity >= 60, "expected a floor on history length")
    }
}

// MARK: - Colour handling

t.suite("Colours") {
    t.test("hex parses with and without the hash, in both lengths") {
        t.close(RGBAColor(hex: "#FF0000")?.red ?? 0, 1)
        t.close(RGBAColor(hex: "00FF00")?.green ?? 0, 1)
        t.close(RGBAColor(hex: "#0000FF80")?.alpha ?? 0, 128.0 / 255, accuracy: 0.01)
    }

    t.test("malformed hex returns nil instead of black") {
        t.isNil(RGBAColor(hex: ""))
        t.isNil(RGBAColor(hex: "#12345"))
        t.isNil(RGBAColor(hex: "#GGGGGG"))
    }

    t.test("hex survives a round trip") {
        for hex in ["#0A84FF", "#30D158", "#FF453A", "#BF5AF2"] {
            t.equal(RGBAColor(hex: hex)?.hex, hex)
        }
    }

    t.test("blending moves towards the other colour") {
        let red = RGBAColor(hex: "#FF0000")!
        let blue = RGBAColor(hex: "#0000FF")!
        t.equal(red.blended(with: blue, amount: 0).hex, "#FF0000")
        t.equal(red.blended(with: blue, amount: 1).hex, "#0000FF")
        let middle = red.blended(with: blue, amount: 0.5)
        t.close(middle.red, 0.5, accuracy: 0.01)
        t.close(middle.blue, 0.5, accuracy: 0.01)
    }

    t.test("blend amount is clamped") {
        let red = RGBAColor(hex: "#FF0000")!
        let blue = RGBAColor(hex: "#0000FF")!
        t.equal(red.blended(with: blue, amount: 5).hex, "#0000FF")
        t.equal(red.blended(with: blue, amount: -2).hex, "#FF0000")
    }
}

// MARK: - User-visible text

t.suite("Wording") {
    // Renaming the Settings type once rewrote the word inside string literals
    // too, and "Gauge GaugeSettings" shipped as a tooltip. This reads the
    // sources back so a blanket rename cannot do it again unnoticed.
    let sources: [String] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GaugeTests
            .deletingLastPathComponent()   // Sources
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // This file spells out the strings it is looking for.
            guard url.path != #filePath else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) { files.append(text) }
        }
        return files
    }()

    t.test("the sources are readable from the test") {
        t.expect(sources.count > 10, "found only \(sources.count) source files")
    }

    t.test("no type name leaked into a string or a sentence") {
        for text in sources {
            for line in text.split(separator: "\n") {
                let isComment = line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                let quoted = line.contains("\"") && line.contains("GaugeSettings")
                guard isComment || quoted else { continue }
                // A type name is fine in code; it is not a word for a person.
                let offends = line.contains("Gauge GaugeSettings")
                    || line.contains("System GaugeSettings")
                    || line.contains("in GaugeSettings →")
                t.expect(!offends, "leaked type name: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    t.test("the author credit is filled in") {
        t.expect(!GaugeVersion.author.isEmpty, "no author")
        t.expect(GaugeVersion.authorEmail.contains("@"), "author email looks wrong")
        t.expect(GaugeVersion.credit.contains(GaugeVersion.author), "credit omits the author")
        t.expect(GaugeVersion.credit.contains(GaugeVersion.authorEmail), "credit omits the email")
    }
}

// MARK: - History store

t.suite("History store") {
    func tempStore() -> (HistoryStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gauge-history-\(UUID().uuidString)")
        return (HistoryStore(directory: directory), directory)
    }

    t.test("ranges are ordered and cover four weeks") {
        let seconds = HistoryRange.allCases.map(\.seconds)
        t.equal(seconds, seconds.sorted(), "ranges should increase")
        t.close(HistoryRange.m10.seconds, 600)
        t.close(HistoryRange.d28.seconds, 28 * 86_400)
        t.equal(HistoryRange.allCases.count, 10)
    }

    t.test("a bucket keeps the extremes, not just the mean") {
        var bucket = HistoryBucket()
        for value in [10.0, 90.0, 50.0] { bucket.add(value) }
        t.close(bucket.minimum, 10)
        t.close(bucket.maximum, 90)
        t.close(bucket.average, 50)
        t.equal(bucket.count, 3)
    }

    t.test("recording then reading returns the values") {
        let (store, _) = tempStore()
        let now = Date()
        for index in 0..<60 {
            store.record("test", Double(index), at: now.addingTimeInterval(-Double(60 - index) * 2))
        }
        let series = store.series("test", range: .m10)
        t.expect(!series.isEmpty, "expected buckets")
        t.expect(series.peak >= 58, "peak should reach the highest sample, got \(series.peak)")
    }

    t.test("a long range still returns data recorded seconds ago") {
        let (store, _) = tempStore()
        store.record("test", 42, at: Date())
        let series = store.series("test", range: .d28)
        t.expect(!series.isEmpty, "the coarse tier should have the sample too")
        t.close(series.latest, 42, accuracy: 0.001)
    }

    t.test("downsampling keeps the peak instead of averaging it away") {
        var buckets = (0..<1000).map { _ in HistoryBucket(minimum: 1, average: 1, maximum: 1, count: 1) }
        buckets[500] = HistoryBucket(minimum: 1, average: 99, maximum: 99, count: 1)
        let series = HistorySeries(buckets: buckets, start: Date(), interval: 2)

        let reduced = HistoryStore.downsample(series, to: 50)
        t.expect(reduced.buckets.count <= 51, "expected about 50 points, got \(reduced.buckets.count)")
        t.close(reduced.peak, 99, accuracy: 0.001)
    }

    t.test("downsampling leaves a short series alone") {
        let buckets = (0..<10).map { HistoryBucket(minimum: 0, average: Double($0), maximum: Double($0), count: 1) }
        let series = HistorySeries(buckets: buckets, start: Date(), interval: 2)
        t.equal(HistoryStore.downsample(series, to: 400).buckets.count, 10)
    }

    t.test("a gap stays a gap") {
        let (store, _) = tempStore()
        let now = Date()
        store.record("test", 5, at: now.addingTimeInterval(-3_600))
        store.record("test", 5, at: now)
        let series = store.series("test", range: .h1, maximumPoints: 10_000)
        let empty = series.buckets.filter(\.isEmpty).count
        t.expect(empty > 0, "the silent hour should read as empty buckets, not a straight line")
    }

    t.test("history survives a restart") {
        let (store, directory) = tempStore()
        let now = Date()
        for index in 0..<40 {
            store.record("test", Double(index),
                         at: now.addingTimeInterval(-Double(40 - index) * 900))
        }
        store.save()

        let reopened = HistoryStore(directory: directory)
        let series = reopened.series("test", range: .d28)
        t.expect(!series.isEmpty, "expected the saved history back")
        t.expect(series.peak >= 38, "peak should survive the round trip, got \(series.peak)")
        try? FileManager.default.removeItem(at: directory)
    }

    t.test("the live tier is not written to disk") {
        // An hour of two-second detail is stale by the time the app returns,
        // and it is the bulk of the data.
        let (store, directory) = tempStore()
        let now = Date()
        for index in 0..<200 { store.record("test", 1, at: now.addingTimeInterval(-Double(index) * 2)) }
        store.save()
        let size = (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("history.gauge").path)[.size] as? Int) ?? 0
        t.expect(size > 0, "something should be written")
        t.expect(size < 60_000, "one metric should not need \(size) bytes")
        try? FileManager.default.removeItem(at: directory)
    }

    t.test("a bucket run is split at the gaps") {
        // Plot lives in the app target, so the behaviour is checked through
        // the series it is built from.
        let present = HistoryBucket(minimum: 1, average: 1, maximum: 1, count: 1)
        let missing = HistoryBucket()
        let buckets = [present, present, missing, missing, present, present, present]
        let defined = buckets.map { !$0.isEmpty }
        t.equal(defined, [true, true, false, false, true, true, true])
        t.equal(defined.filter { $0 }.count, 5, "five samples, two holes")
    }

    t.test("an unknown metric returns nothing rather than failing") {
        let (store, _) = tempStore()
        t.expect(store.series("nope", range: .h1).isEmpty, "expected an empty series")
    }

    t.test("chart ranges persist per chart and fall back to the default") {
        let suite = "gauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let settings = GaugeSettings(defaults: defaults)
        t.equal(settings.chartRange("cpu.usage"), settings.defaultChartRange)

        settings.setChartRange("cpu.usage", .d7)
        settings.defaultChartRange = .h6
        settings.save()

        let reloaded = GaugeSettings(defaults: defaults)
        t.equal(reloaded.chartRange("cpu.usage"), .d7, "explicit range")
        t.equal(reloaded.chartRange("memory.used"), .h6, "falls back to the default")

        reloaded.resetChartRanges()
        t.equal(reloaded.chartRange("cpu.usage"), .h6, "reset returns to the default")
    }
}

// MARK: - Sensor calibration

t.suite("Sensor calibration") {
    func response(_ name: String, idle: Double, e: Double, p: Double) -> SensorResponse {
        SensorResponse(sensor: name, idle: idle, deltaEfficiency: e, deltaPerformance: p)
    }

    // The numbers below are the ones measured on a Mac17,2.
    t.test("a sensor that barely moves is not a CPU sensor") {
        t.equal(response("PMU2 tdie1", idle: 42.8, e: 0.6, p: 0.9).affinity, .unrelated)
        t.equal(response("gas gauge battery", idle: 31.1, e: 0.1, p: 0.0).affinity, .unrelated)
    }

    t.test("a sensor the fast cluster moves further leans that way") {
        t.equal(response("PMU tdie1", idle: 46.7, e: 10.4, p: 19.5).affinity, .performance)
        t.equal(response("PMU tdie6", idle: 48.3, e: 9.7, p: 15.3).affinity, .performance)
    }

    t.test("a sensor the efficient cluster moves further leans that way") {
        t.equal(response("PMU tdie8", idle: 49.3, e: 13.3, p: 12.0).affinity, .efficiency)
    }

    t.test("a sensor both clusters move equally is shared") {
        t.equal(response("PMU tdie3", idle: 47.5, e: 9.4, p: 9.2).affinity, .shared)
        t.equal(response("PMU tdie13", idle: 47.4, e: 7.0, p: 8.7).affinity, .shared)
    }

    t.test("a tiny response never produces a confident verdict") {
        // 0.2 against 0.1 is a ratio of 2, but both are noise.
        t.equal(response("noise", idle: 40, e: 0.1, p: 0.2).affinity, .unrelated)
    }

    t.test("a calibration from another Mac is not applied here") {
        let calibration = SensorCalibration(responses: [], performanceClusterName: "Super",
                                            efficiencyClusterName: "Efficiency",
                                            machineModel: "Mac99,9")
        t.expect(!calibration.applies(to: "Mac17,2"), "should reject a foreign calibration")
        t.expect(calibration.applies(to: "Mac99,9"), "should accept its own machine")
    }

    t.test("calibration round-trips through settings") {
        let suite = "gauge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let model = sysctlStringForTests("hw.model")
        let settings = GaugeSettings(defaults: defaults)
        settings.sensorCalibration = SensorCalibration(
            responses: [response("PMU tdie1", idle: 46.7, e: 10.4, p: 19.5)],
            performanceClusterName: "Super", efficiencyClusterName: "Efficiency",
            machineModel: model)
        settings.save()

        let reloaded = GaugeSettings(defaults: defaults)
        t.notNil(reloaded.sensorCalibration, "calibration should survive a reload")
        t.equal(reloaded.sensorCalibration?.affinity(for: "PMU tdie1"), .performance)
        t.equal(reloaded.sensorCalibration?.clusterName(for: .performance), "Super")
    }

    t.test("sensor numbers survive relabelling") {
        t.equal(SensorMonitor.sensorNumber("PMU tdie14"), "14")
        t.equal(SensorMonitor.sensorNumber("PMU2 tdev3"), "3")
        t.equal(SensorMonitor.sensorNumber("NAND CH0 temp"), "")
    }
}

// MARK: - Live collectors
//
// These run against the machine doing the testing, so they assert on shape and
// plausibility rather than on exact values.

t.suite("Live collectors") {
    t.test("core clusters are named the way the system names them") {
        let monitor = CPUMonitor()
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let sample = monitor.sample()
        t.expect(!monitor.performanceClusterName.isEmpty, "no name for the fast cluster")
        t.expect(!monitor.efficiencyClusterName.isEmpty, "no name for the efficient cluster")
        if monitor.efficiencyCoreCount > 0 {
            let named = Set(sample.cores.map(\.clusterName))
            t.expect(named.contains(monitor.performanceClusterName),
                     "no core labelled \(monitor.performanceClusterName)")
            t.expect(named.contains(monitor.efficiencyClusterName),
                     "no core labelled \(monitor.efficiencyClusterName)")
            t.equal(sample.cores.filter { $0.kind == .performance }.count,
                    monitor.performanceCoreCount, "performance core count")
            t.equal(sample.cores.filter { $0.kind == .efficiency }.count,
                    monitor.efficiencyCoreCount, "efficiency core count")
        }
    }

    t.test("CPU reports one entry per logical core") {
        let monitor = CPUMonitor()
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let sample = monitor.sample()
        t.equal(sample.cores.count, monitor.coreCount)
        t.expect(sample.total >= 0 && sample.total <= 1, "total load out of range: \(sample.total)")
        t.expect(sample.uptime > 0, "uptime should be positive")
        t.expect(sample.processCount > 0, "expected some processes")
    }

    t.test("memory parts never exceed what is installed") {
        let sample = MemoryMonitor().sample()
        t.expect(sample.total > 0, "no physical memory reported")
        t.expect(sample.used <= sample.total, "used (\(sample.used)) exceeds total (\(sample.total))")
        t.expect(sample.usedFraction > 0 && sample.usedFraction <= 1, "fraction out of range")
    }

    t.test("the boot volume is present and self-consistent") {
        let sample = DiskMonitor().sample()
        t.notNil(sample.bootVolume, "boot volume")
        if let volume = sample.bootVolume {
            t.expect(volume.total > 0, "boot volume has no capacity")
            t.expect(volume.used <= volume.total, "used exceeds total")
            t.expect(volume.free <= volume.total, "free exceeds total")
        }
    }

    t.test("network counters only ever move forward") {
        let monitor = NetworkMonitor()
        let first = monitor.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let second = monitor.sample()
        t.expect(second.totalIn >= first.totalIn, "byte counter went backwards")
        t.expect(second.downloadRate >= 0, "negative download rate")
        t.expect(second.uploadRate >= 0, "negative upload rate")
    }

    t.test("sensor readings are physically plausible") {
        let sample = SensorMonitor().sample()
        for reading in sample.readings where reading.kind == .temperature {
            t.expect(reading.value > -40 && reading.value < 150,
                     "\(reading.name) reported \(reading.value)°C")
        }
        for fan in sample.fans {
            t.expect(fan.rpm >= 0 && fan.rpm < 20000, "\(fan.name) reported \(fan.rpm) rpm")
            t.expect(fan.maxRPM >= fan.minRPM, "\(fan.name) has an inverted range")
        }
    }

    t.test("battery figures agree with each other when a battery exists") {
        let sample = BatteryMonitor().sample()
        guard sample.isPresent else { return }
        t.expect(sample.charge >= 0 && sample.charge <= 1, "charge out of range")
        if let current = sample.currentCapacity, let maximum = sample.maxCapacity, maximum > 0 {
            // Both are milliamp-hours, so neither should look like a percentage.
            t.expect(maximum > 100, "max capacity \(maximum) looks like a percentage")
            t.expect(current <= maximum * 1.05, "current capacity exceeds the pack's maximum")
        }
        if let health = sample.health {
            t.expect(health > 0.2 && health <= 1.2, "implausible health \(health)")
        }
    }

    t.test("no process is named after a bare version number") {
        let monitor = ProcessMonitor()
        _ = monitor.sample(limit: 20)
        Thread.sleep(forTimeInterval: 0.3)
        let sample = monitor.sample(limit: 20)
        for process in sample.byCPU + sample.byMemory {
            let versionish = !process.name.isEmpty
                && process.name.allSatisfy { $0.isNumber || $0 == "." }
            t.expect(!versionish, "\(process.name) (pid \(process.id)) reads as a version, not a name")
        }
    }

    t.test("the power manager publishes usable frequency tables") {
        let tables = FrequencyMonitor.frequencyTables()
        #if arch(arm64)
        t.expect(!tables.efficiency.isEmpty, "no efficiency-cluster table")
        t.expect(!tables.performance.isEmpty, "no performance-cluster table")

        for (label, table) in [("efficiency", tables.efficiency),
                               ("performance", tables.performance),
                               ("gpu", tables.gpu)] where !table.isEmpty {
            t.expect(table == table.sorted(), "\(label) states should ascend")
            t.expect(table.first ?? 0 > 100, "\(label) starts at \(table.first ?? 0) MHz")
            t.expect(table.last ?? 0 < 10_000, "\(label) tops out at \(table.last ?? 0) MHz")
        }
        // The fast cluster clocks higher than the efficient one; that is what
        // makes it the fast one.
        if let slow = tables.efficiency.last, let fast = tables.performance.last {
            t.expect(fast > slow, "performance \(fast) should exceed efficiency \(slow) MHz")
        }
        #endif
    }

    t.test("clock readings stay inside the hardware's own range") {
        guard let monitor = FrequencyMonitor() else { return }
        _ = monitor.sample()                    // first pass has no baseline
        Thread.sleep(forTimeInterval: 0.4)
        let sample = monitor.sample()

        for (label, value, maximum) in [
            ("efficiency", sample.efficiencyMHz, sample.maximumEfficiencyMHz),
            ("performance", sample.performanceMHz, sample.maximumPerformanceMHz),
            ("gpu", sample.gpuMHz, sample.maximumGPUMHz),
        ] {
            guard let value else { continue }   // idle is a valid answer
            t.expect(value > 0, "\(label) reported \(value) MHz")
            t.expect(value <= maximum * 1.02,
                     "\(label) reported \(value) MHz above its \(maximum) MHz ceiling")
        }
        for (label, active) in [("efficiency", sample.efficiencyActive),
                                ("performance", sample.performanceActive),
                                ("gpu", sample.gpuActive)] {
            t.expect(active >= 0 && active <= 1, "\(label) active share is \(active)")
        }
    }

    t.test("an idle unit reports no clock rather than zero") {
        // A unit that never left idle has no speed to average, and reporting
        // 0 GHz would read as a stopped clock instead of an unused one.
        guard let monitor = FrequencyMonitor() else { return }
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let sample = monitor.sample()
        if sample.gpuActive == 0 { t.isNil(sample.gpuMHz, "idle GPU") }
    }

    t.test("process sampling produces named processes with sane usage") {
        let monitor = ProcessMonitor()
        _ = monitor.sample(limit: 5)
        Thread.sleep(forTimeInterval: 0.4)
        let sample = monitor.sample(limit: 5)
        t.expect(!sample.byCPU.isEmpty, "expected at least one process")
        t.expect(sample.processCount > 0, "expected a process count")
        t.expect(sample.threadCount >= sample.processCount,
                 "threads (\(sample.threadCount)) should not be fewer than processes (\(sample.processCount))")
        for process in sample.byCPU + sample.byMemory {
            t.expect(!process.name.isEmpty, "process \(process.id) has no name")
            t.expect(process.cpu >= 0, "negative CPU for \(process.name)")
            t.expect(process.memory >= 0, "negative memory for \(process.name)")
        }
    }
}

exit(t.finish())
