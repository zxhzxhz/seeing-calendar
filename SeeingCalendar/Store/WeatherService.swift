import CoreLocation
import Foundation
import Observation

/// 天气数据模型（来自 Open-Meteo）
struct WeatherInfo: Codable, Sendable {
    var dateKey: String
    var weatherCode: Int
    var tempMin: Double
    var tempMax: Double
    var cityName: String
    var updatedAt: Date

    /// 中文天气描述（根据 WMO 天气代码标准对照）
    var conditionDescription: String {
        WeatherService.wmoDescription(for: weatherCode)
    }

    /// 按照需求格式化：天气{晴/多云/暴雨等} 气温{min}~{max}摄氏度
    var formattedWeatherSegment: String {
        let minRounded = Int(tempMin.rounded())
        let maxRounded = Int(tempMax.rounded())
        return "天气\(conditionDescription) 气温\(minRounded)~\(maxRounded)摄氏度"
    }
}

/// 城市定位与搜索结果条目
struct WeatherLocation: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(latitude)_\(longitude)" }
    var name: String
    var latitude: Double
    var longitude: Double
    var admin1: String?
    var country: String?

    var displayName: String {
        if let admin = admin1, !admin.isEmpty, admin != name {
            return "\(name), \(admin)"
        }
        return name
    }
}

/// Open-Meteo 天气服务管理单例
@MainActor
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    /// 当前选定或定位到的城市
    private(set) var currentLocation: WeatherLocation {
        didSet {
            saveCurrentLocation()
        }
    }

    /// 是否开启系统自动定位
    var useAutoLocation: Bool {
        didSet {
            UserDefaults.standard.set(useAutoLocation, forKey: "weather_use_auto_location")
            if useAutoLocation {
                requestLocation()
            }
        }
    }

    /// 天气缓存字典：`[dateKey_locationKey: WeatherInfo]`
    private var weatherCache: [String: WeatherInfo] = [:]

    /// 搜索地点建议列表
    private(set) var searchResults: [WeatherLocation] = []
    private(set) var isSearching = false
    private(set) var isFetching = false
    private(set) var lastError: String?

    private let locationManager = CLLocationManager()
    private let cacheURL: URL

    private override init() {
        self.cacheURL = AppPaths.cacheRoot.appendingPathComponent("weather_cache.json")
        self.useAutoLocation = UserDefaults.standard.bool(forKey: "weather_use_auto_location")
        
        // 默认预设城市（北京），支持随后通过定位或搜索替换
        if let savedData = UserDefaults.standard.data(forKey: "weather_saved_location"),
           let saved = try? JSONDecoder().decode(WeatherLocation.self, from: savedData) {
            self.currentLocation = saved
        } else {
            self.currentLocation = WeatherLocation(name: "北京", latitude: 39.9042, longitude: 116.4074, admin1: "北京市", country: "中国")
        }

        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer

        loadCache()

        if useAutoLocation {
            requestLocation()
        }
    }

    // MARK: - 查询与装载

    /// 获取指定日期的天气数据（若缓存命中直接返回，否则后台异步拉取）
    func weather(for date: Date) -> WeatherInfo? {
        let key = cacheKey(for: date, location: currentLocation)
        if let cached = weatherCache[key] {
            return cached
        }
        Task {
            await fetchWeather(for: date)
        }
        return nil
    }

    /// 格式化包含天气的页面标题：`{日期} 天气{描述} 气温{min}~{max}摄氏度`
    func fullTitle(for date: Date) -> String {
        let baseDateTitle = CalendarUtils.dayTitle(date)
        if let weather = weather(for: date) {
            return "\(baseDateTitle) \(weather.formattedWeatherSegment)"
        }
        return baseDateTitle
    }

    /// 拉取指定日期的天气
    func fetchWeather(for date: Date) async {
        let dateKey = CalendarUtils.key(for: date)
        let key = cacheKey(for: date, location: currentLocation)
        
        // 如果 2 小时内已拉取过，不重复请求
        if let existing = weatherCache[key], Date().timeIntervalSince(existing.updatedAt) < 7200 {
            return
        }

        isFetching = true
        defer { isFetching = false }

        let lat = currentLocation.latitude
        let lon = currentLocation.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&start_date=\(dateKey)&end_date=\(dateKey)"
        
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "天气接口响应异常 (\(http.statusCode))"
                return
            }

            struct OpenMeteoResponse: Codable {
                struct Daily: Codable {
                    let time: [String]
                    let weather_code: [Int]?
                    let temperature_2m_max: [Double]?
                    let temperature_2m_min: [Double]?
                }
                let daily: Daily?
            }

            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            guard let daily = decoded.daily,
                  let code = daily.weather_code?.first,
                  let maxTemp = daily.temperature_2m_max?.first,
                  let minTemp = daily.temperature_2m_min?.first else {
                return
            }

            let info = WeatherInfo(
                dateKey: dateKey,
                weatherCode: code,
                tempMin: minTemp,
                tempMax: maxTemp,
                cityName: currentLocation.name,
                updatedAt: Date()
            )

            weatherCache[key] = info
            persistCache()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 搜索城市

    func searchCities(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=8&language=zh&format=json") else {
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct GeocodingResponse: Codable {
                struct Item: Codable {
                    let id: Int
                    let name: String
                    let latitude: Double
                    let longitude: Double
                    let admin1: String?
                    let country: String?
                }
                let results: [Item]?
            }
            let res = try JSONDecoder().decode(GeocodingResponse.self, from: data)
            let items = res.results ?? []
            self.searchResults = items.map {
                WeatherLocation(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, admin1: $0.admin1, country: $0.country)
            }
        } catch {
            searchResults = []
        }
    }

    func selectLocation(_ location: WeatherLocation) {
        useAutoLocation = false
        currentLocation = location
        searchResults = []
    }

    // MARK: - CoreLocation 自动定位

    func requestLocation() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if (status == .authorizedWhenInUse || status == .authorizedAlways) && self.useAutoLocation {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            await self.resolveLocationName(for: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = "定位失败：\(error.localizedDescription)"
        }
    }

    private func resolveLocationName(for loc: CLLocation) async {
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(loc),
              let mark = placemarks.first else {
            currentLocation = WeatherLocation(name: "当前位置", latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, admin1: nil, country: nil)
            return
        }
        let name = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea ?? "当前位置"
        currentLocation = WeatherLocation(
            name: name,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            admin1: mark.administrativeArea,
            country: mark.country
        )
    }

    // MARK: - 缓存存储

    private func cacheKey(for date: Date, location: WeatherLocation) -> String {
        let dateKey = CalendarUtils.key(for: date)
        let latStr = String(format: "%.2f", location.latitude)
        let lonStr = String(format: "%.2f", location.longitude)
        return "\(dateKey)_\(latStr)_\(lonStr)"
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: WeatherInfo].self, from: data) else { return }
        weatherCache = decoded
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(weatherCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func saveCurrentLocation() {
        if let data = try? JSONEncoder().encode(currentLocation) {
            UserDefaults.standard.set(data, forKey: "weather_saved_location")
        }
    }

    // MARK: - WMO 代码转换

    nonisolated static func wmoDescription(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "雪粒"
        case 80: return "小阵雨"
        case 81: return "阵雨"
        case 82: return "暴雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷雨伴冰雹"
        default: return "晴"
        }
    }
}
