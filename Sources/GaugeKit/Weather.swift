// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Unified model

public struct WeatherCondition: Sendable, Hashable {
    public var code: Int
    public var text: String
    public var symbolName: String
    public var isDay: Bool

    public init(code: Int, text: String, symbolName: String, isDay: Bool) {
        self.code = code
        self.text = text
        self.symbolName = symbolName
        self.isDay = isDay
    }
}

public struct WeatherNow: Sendable, Hashable {
    public var temperature: Double          // °C
    public var feelsLike: Double?
    public var humidity: Double?            // 0…1
    public var windSpeed: Double?           // km/h
    public var windDirection: Double?       // degrees
    public var pressure: Double?            // hPa
    public var precipitation: Double?       // mm
    public var uvIndex: Double?
    public var condition: WeatherCondition
}

public struct WeatherHour: Identifiable, Sendable, Hashable {
    public var id: Date { date }
    public var date: Date
    public var temperature: Double
    public var precipitationProbability: Double?
    public var condition: WeatherCondition
}

public struct WeatherDay: Identifiable, Sendable, Hashable {
    public var id: Date { date }
    public var date: Date
    public var high: Double
    public var low: Double
    public var precipitationProbability: Double?
    public var sunrise: Date?
    public var sunset: Date?
    public var condition: WeatherCondition
}

public struct WeatherReport: Sendable {
    public var location: WeatherLocation
    public var now: WeatherNow
    public var hourly: [WeatherHour]
    public var daily: [WeatherDay]
    public var provider: WeatherProviderID
    public var attribution: String
    public var fetchedAt: Date
}

public struct GeocodeResult: Identifiable, Sendable, Hashable {
    public var id: String { "\(name)-\(latitude)-\(longitude)" }
    public var name: String
    public var region: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double
    public var timezone: String?
    public var providerKey: String?

    public var displayName: String {
        [name, region, country].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum WeatherError: LocalizedError {
    case missingAPIKey
    case noLocation
    case badResponse(Int)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "This provider needs an API key. Add one in Settings → Weather."
        case .noLocation: "Choose a location in Settings → Weather."
        case .badResponse(let code): "The weather service returned HTTP \(code)."
        case .decoding(let detail): "Could not read the weather response (\(detail))."
        case .transport(let detail): "Could not reach the weather service (\(detail))."
        }
    }
}

public protocol WeatherProvider: Sendable {
    var id: WeatherProviderID { get }
    var attribution: String { get }
    func fetch(location: WeatherLocation, apiKey: String?) async throws -> WeatherReport
    func search(query: String, apiKey: String?) async throws -> [GeocodeResult]
}

// MARK: - Shared HTTP

enum HTTP {
    static func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Gauge/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WeatherError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeatherError.badResponse(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WeatherError.decoding("\(error)")
        }
    }
}

// MARK: - WMO code mapping

public enum WMOCode {
    /// Open-Meteo reports WMO 4677 codes; this collapses them into the handful
    /// of states worth distinguishing in a menu bar.
    public static func condition(for code: Int, isDay: Bool) -> WeatherCondition {
        let (text, day, night): (String, String, String) = switch code {
        case 0:        ("Clear", "sun.max", "moon.stars")
        case 1:        ("Mainly clear", "sun.min", "moon")
        case 2:        ("Partly cloudy", "cloud.sun", "cloud.moon")
        case 3:        ("Overcast", "cloud", "cloud")
        case 45, 48:   ("Fog", "cloud.fog", "cloud.fog")
        case 51, 53, 55: ("Drizzle", "cloud.drizzle", "cloud.drizzle")
        case 56, 57:   ("Freezing drizzle", "cloud.sleet", "cloud.sleet")
        case 61, 63:   ("Rain", "cloud.rain", "cloud.rain")
        case 65:       ("Heavy rain", "cloud.heavyrain", "cloud.heavyrain")
        case 66, 67:   ("Freezing rain", "cloud.sleet", "cloud.sleet")
        case 71, 73, 75, 77: ("Snow", "cloud.snow", "cloud.snow")
        case 80, 81:   ("Rain showers", "cloud.sun.rain", "cloud.moon.rain")
        case 82:       ("Heavy showers", "cloud.heavyrain", "cloud.heavyrain")
        case 85, 86:   ("Snow showers", "cloud.snow", "cloud.snow")
        case 95:       ("Thunderstorm", "cloud.bolt", "cloud.bolt")
        case 96, 99:   ("Thunderstorm with hail", "cloud.bolt.rain", "cloud.bolt.rain")
        default:       ("Unknown", "questionmark.circle", "questionmark.circle")
        }
        return WeatherCondition(code: code, text: text, symbolName: isDay ? day : night, isDay: isDay)
    }
}

// MARK: - Open-Meteo

/// Default provider: no account, no API key, no per-user identifier in the
/// request. The only thing it learns is the coordinate being asked about.
public struct OpenMeteoProvider: WeatherProvider {
    public let id: WeatherProviderID = .openMeteo
    public let attribution = "Weather data by Open-Meteo.com (CC BY 4.0)"

    public init() {}

    private struct Response: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double?
            let relative_humidity_2m: Double?
            let apparent_temperature: Double?
            let is_day: Int?
            let precipitation: Double?
            let weather_code: Int?
            let pressure_msl: Double?
            let wind_speed_10m: Double?
            let wind_direction_10m: Double?
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]?
            let weather_code: [Int?]?
            let precipitation_probability: [Double?]?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]?
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
            let precipitation_probability_max: [Double?]?
            let sunrise: [String?]?
            let sunset: [String?]?
            let uv_index_max: [Double?]?
        }
        let timezone: String?
        let current: Current?
        let hourly: Hourly?
        let daily: Daily?
    }

    public func fetch(location: WeatherLocation, apiKey: String?) async throws -> WeatherReport {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(location.latitude)),
            .init(name: "longitude", value: String(location.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,pressure_msl,wind_speed_10m,wind_direction_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
        ]
        guard let url = components.url else { throw WeatherError.noLocation }
        let response = try await HTTP.getJSON(url, as: Response.self)

        let zone = response.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let parser = Self.dateParser(zone: zone)
        let dayParser = Self.dayParser(zone: zone)

        guard let current = response.current, let temperature = current.temperature_2m else {
            throw WeatherError.decoding("missing current conditions")
        }
        let isDay = (current.is_day ?? 1) == 1
        let now = WeatherNow(
            temperature: temperature,
            feelsLike: current.apparent_temperature,
            humidity: current.relative_humidity_2m.map { $0 / 100 },
            windSpeed: current.wind_speed_10m,
            windDirection: current.wind_direction_10m,
            pressure: current.pressure_msl,
            precipitation: current.precipitation,
            uvIndex: response.daily?.uv_index_max?.first ?? nil,
            condition: WMOCode.condition(for: current.weather_code ?? 0, isDay: isDay)
        )

        var hourly: [WeatherHour] = []
        if let block = response.hourly {
            let cutoff = Date().addingTimeInterval(-3600)
            for (index, stamp) in block.time.enumerated() {
                guard let date = parser.date(from: stamp), date > cutoff,
                      let temperature = block.temperature_2m?[safe: index] ?? nil else { continue }
                let code = block.weather_code?[safe: index] ?? nil
                hourly.append(WeatherHour(
                    date: date,
                    temperature: temperature,
                    precipitationProbability: (block.precipitation_probability?[safe: index] ?? nil).map { $0 / 100 },
                    condition: WMOCode.condition(for: code ?? 0, isDay: Self.isDaylight(date, zone: zone))
                ))
                if hourly.count >= 24 { break }
            }
        }

        var daily: [WeatherDay] = []
        if let block = response.daily {
            for (index, stamp) in block.time.enumerated() {
                guard let date = dayParser.date(from: stamp),
                      let high = block.temperature_2m_max?[safe: index] ?? nil,
                      let low = block.temperature_2m_min?[safe: index] ?? nil else { continue }
                daily.append(WeatherDay(
                    date: date,
                    high: high,
                    low: low,
                    precipitationProbability: (block.precipitation_probability_max?[safe: index] ?? nil).map { $0 / 100 },
                    sunrise: (block.sunrise?[safe: index] ?? nil).flatMap { parser.date(from: $0) },
                    sunset: (block.sunset?[safe: index] ?? nil).flatMap { parser.date(from: $0) },
                    condition: WMOCode.condition(for: (block.weather_code?[safe: index] ?? nil) ?? 0, isDay: true)
                ))
            }
        }

        var resolved = location
        resolved.timezone = response.timezone
        return WeatherReport(location: resolved, now: now, hourly: hourly, daily: daily,
                             provider: id, attribution: attribution, fetchedAt: Date())
    }

    private struct GeocodeResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
            let timezone: String?
        }
        let results: [Entry]?
    }

    public func search(query: String, apiKey: String?) async throws -> [GeocodeResult] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "10"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        let response = try await HTTP.getJSON(url, as: GeocodeResponse.self)
        return (response.results ?? []).map {
            GeocodeResult(name: $0.name, region: $0.admin1, country: $0.country,
                          latitude: $0.latitude, longitude: $0.longitude,
                          timezone: $0.timezone, providerKey: nil)
        }
    }

    // MARK: Date parsing

    static func dateParser(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }

    static func dayParser(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Rough day/night split for picking an icon; the exact sunrise is used
    /// where the API supplies it.
    static func isDaylight(_ date: Date, zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return (6..<19).contains(hour)
    }
}

// MARK: - AccuWeather

/// Optional provider. It needs a free developer key, and every request carries
/// that key plus the location key, so it is a more identifying choice than the
/// default; offered because it was asked for.
public struct AccuWeatherProvider: WeatherProvider {
    public let id: WeatherProviderID = .accuWeather
    public let attribution = "Weather data by AccuWeather"

    private let base = "https://dataservice.accuweather.com"

    public init() {}

    private struct Current: Decodable {
        struct Metric: Decodable { let Value: Double? }
        struct Unit: Decodable { let Metric: Metric? }
        struct Wind: Decodable {
            struct Speed: Decodable { let Metric: Metric? }
            struct Direction: Decodable { let Degrees: Double? }
            let Speed: Speed?
            let Direction: Direction?
        }
        struct Pressure: Decodable { let Metric: Metric? }
        let WeatherIcon: Int?
        let WeatherText: String?
        let IsDayTime: Bool?
        let Temperature: Unit?
        let RealFeelTemperature: Unit?
        let RelativeHumidity: Double?
        let UVIndex: Double?
        let Wind: Wind?
        let Pressure: Pressure?
    }

    private struct DailyForecast: Decodable {
        struct DailyForecasts: Decodable {
            struct Temp: Decodable {
                struct Value: Decodable { let Value: Double? }
                let Minimum: Value?
                let Maximum: Value?
            }
            struct Sun: Decodable { let Rise: String?; let Set: String? }
            struct Half: Decodable { let Icon: Int?; let IconPhrase: String?; let PrecipitationProbability: Double? }
            let Date: String?
            let Temperature: Temp?
            let Sun: Sun?
            let Day: Half?
        }
        let DailyForecasts: [DailyForecasts]?
    }

    private struct HourlyForecast: Decodable {
        struct Temp: Decodable { let Value: Double? }
        let DateTime: String?
        let WeatherIcon: Int?
        let IconPhrase: String?
        let Temperature: Temp?
        let PrecipitationProbability: Double?
        let IsDaylight: Bool?
    }

    private struct LocationEntry: Decodable {
        struct Area: Decodable { let LocalizedName: String? }
        struct Geo: Decodable { let Latitude: Double?; let Longitude: Double? }
        struct GeoPosition: Decodable { let Latitude: Double?; let Longitude: Double? }
        struct TimeZoneInfo: Decodable { let Name: String? }
        let Key: String?
        let LocalizedName: String?
        let AdministrativeArea: Area?
        let Country: Area?
        let GeoPosition: GeoPosition?
        let TimeZone: TimeZoneInfo?
    }

    public func fetch(location: WeatherLocation, apiKey: String?) async throws -> WeatherReport {
        guard let apiKey, !apiKey.isEmpty else { throw WeatherError.missingAPIKey }

        // AccuWeather works off its own location key; resolve it from the
        // coordinates the first time and cache it on the stored location.
        let locationKey: String
        if let key = location.providerKey, !key.isEmpty {
            locationKey = key
        } else {
            locationKey = try await resolveLocationKey(location: location, apiKey: apiKey)
        }

        async let currentTask: [Current] = HTTP.getJSON(
            url("\(base)/currentconditions/v1/\(locationKey)", [("apikey", apiKey), ("details", "true")]),
            as: [Current].self)
        async let dailyTask: DailyForecast = HTTP.getJSON(
            url("\(base)/forecasts/v1/daily/5day/\(locationKey)", [("apikey", apiKey), ("metric", "true"), ("details", "true")]),
            as: DailyForecast.self)
        async let hourlyTask: [HourlyForecast] = HTTP.getJSON(
            url("\(base)/forecasts/v1/hourly/12hour/\(locationKey)", [("apikey", apiKey), ("metric", "true")]),
            as: [HourlyForecast].self)

        guard let current = try await currentTask.first, let temperature = current.Temperature?.Metric?.Value else {
            throw WeatherError.decoding("missing current conditions")
        }
        let isDay = current.IsDayTime ?? true
        let now = WeatherNow(
            temperature: temperature,
            feelsLike: current.RealFeelTemperature?.Metric?.Value,
            humidity: current.RelativeHumidity.map { $0 / 100 },
            windSpeed: current.Wind?.Speed?.Metric?.Value,
            windDirection: current.Wind?.Direction?.Degrees,
            pressure: current.Pressure?.Metric?.Value,
            precipitation: nil,
            uvIndex: current.UVIndex,
            condition: Self.condition(icon: current.WeatherIcon, text: current.WeatherText, isDay: isDay)
        )

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let hourly = (try await hourlyTask).compactMap { entry -> WeatherHour? in
            guard let stamp = entry.DateTime, let date = iso.date(from: stamp),
                  let temperature = entry.Temperature?.Value else { return nil }
            return WeatherHour(
                date: date,
                temperature: temperature,
                precipitationProbability: entry.PrecipitationProbability.map { $0 / 100 },
                condition: Self.condition(icon: entry.WeatherIcon, text: entry.IconPhrase,
                                          isDay: entry.IsDaylight ?? true))
        }

        let daily = (try await dailyTask.DailyForecasts ?? []).compactMap { entry -> WeatherDay? in
            guard let stamp = entry.Date, let date = iso.date(from: stamp),
                  let high = entry.Temperature?.Maximum?.Value,
                  let low = entry.Temperature?.Minimum?.Value else { return nil }
            return WeatherDay(
                date: date,
                high: high,
                low: low,
                precipitationProbability: entry.Day?.PrecipitationProbability.map { $0 / 100 },
                sunrise: entry.Sun?.Rise.flatMap { iso.date(from: $0) },
                sunset: entry.Sun?.Set.flatMap { iso.date(from: $0) },
                condition: Self.condition(icon: entry.Day?.Icon, text: entry.Day?.IconPhrase, isDay: true))
        }

        var resolved = location
        resolved.providerKey = locationKey
        return WeatherReport(location: resolved, now: now, hourly: hourly, daily: daily,
                             provider: id, attribution: attribution, fetchedAt: Date())
    }

    public func search(query: String, apiKey: String?) async throws -> [GeocodeResult] {
        guard let apiKey, !apiKey.isEmpty else { throw WeatherError.missingAPIKey }
        let entries = try await HTTP.getJSON(
            url("\(base)/locations/v1/cities/search", [("apikey", apiKey), ("q", query)]),
            as: [LocationEntry].self)
        return entries.compactMap { entry in
            guard let name = entry.LocalizedName,
                  let latitude = entry.GeoPosition?.Latitude,
                  let longitude = entry.GeoPosition?.Longitude else { return nil }
            return GeocodeResult(name: name,
                                 region: entry.AdministrativeArea?.LocalizedName,
                                 country: entry.Country?.LocalizedName,
                                 latitude: latitude, longitude: longitude,
                                 timezone: entry.TimeZone?.Name,
                                 providerKey: entry.Key)
        }
    }

    private func resolveLocationKey(location: WeatherLocation, apiKey: String) async throws -> String {
        let entry = try await HTTP.getJSON(
            url("\(base)/locations/v1/cities/geoposition/search",
                [("apikey", apiKey), ("q", "\(location.latitude),\(location.longitude)")]),
            as: LocationEntry.self)
        guard let key = entry.Key else { throw WeatherError.decoding("no location key") }
        return key
    }

    private func url(_ string: String, _ items: [(String, String)]) -> URL {
        var components = URLComponents(string: string)!
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// Maps AccuWeather's icon numbers onto the same symbol vocabulary the
    /// Open-Meteo path uses, so the UI does not care which provider is active.
    public static func condition(icon: Int?, text: String?, isDay: Bool) -> WeatherCondition {
        let symbol: String = switch icon ?? 0 {
        case 1, 2, 30:        isDay ? "sun.max" : "moon.stars"
        case 3, 4, 5:         isDay ? "cloud.sun" : "cloud.moon"
        case 6, 7, 8:         "cloud"
        case 11:              "cloud.fog"
        case 12, 13, 14:      isDay ? "cloud.sun.rain" : "cloud.moon.rain"
        case 15, 16, 17:      "cloud.bolt.rain"
        case 18:              "cloud.rain"
        case 19, 20, 21, 22, 23, 24, 25, 26: "cloud.snow"
        case 29:              "cloud.sleet"
        case 31:              "thermometer.snowflake"
        case 32:              "wind"
        case 33, 34, 35, 36, 37, 38: "cloud.moon"
        case 39, 40:          "cloud.moon.rain"
        case 41, 42:          "cloud.bolt.rain"
        case 43, 44:          "cloud.snow"
        default:              "questionmark.circle"
        }
        return WeatherCondition(code: icon ?? 0, text: text ?? "Unknown", symbolName: symbol, isDay: isDay)
    }
}

// MARK: - Helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
