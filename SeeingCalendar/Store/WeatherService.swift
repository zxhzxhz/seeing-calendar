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

    /// 匹配 Apple HIG 的 SF Symbol 天气图标
    var systemSymbol: String {
        WeatherService.wmoSymbol(for: weatherCode)
    }

    /// 按照需求格式化：天气{晴/多云/暴雨等} 气温{min}~{max}摄氏度
    var formattedWeatherSegment: String {
        let minRounded = Int(tempMin.rounded())
        let maxRounded = Int(tempMax.rounded())
        return "天气\(conditionDescription) 气温\(minRounded)~\(maxRounded)摄氏度"
    }

    /// 优雅的 HIG 紧凑摘要：晴 · 18°~30°C
    var compactSummary: String {
        let minRounded = Int(tempMin.rounded())
        let maxRounded = Int(tempMax.rounded())
        return "\(conditionDescription) · \(minRounded)°~\(maxRounded)℃"
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

    // MARK: - 相位（单一真值）

    /// 天气请求相位。**单一真值**：`isFetching` / `lastError` 都是它的只读投影。
    ///
    /// 旧实现用 `isFetching = true` + `defer { isFetching = false }` 包住 `await`，
    /// 两次请求重叠时先返回的那次会把标志提前熄火；改成相位 + 代次后，
    /// 「迟到响应」在类型层面就没有改变相位的能力（见 `WeatherStatePolicy.reduce`）。
    private(set) var weatherPhase: WeatherPhase = .idle

    /// 城市搜索相位（带代次，乱序响应据此丢弃）。
    private(set) var searchPhase: CitySearchPhase = .idle

    /// 当前活跃拉取代次。响应携带的代次早于它即被丢弃。
    private var weatherGeneration = 0
    private var searchGeneration = 0

    /// 兼容只读入口：界面用它显示「正在拉取最新天气…」与禁用刷新按钮。
    /// 语义严格等于旧实现的 `isFetching`（只由 `fetchWeather` 置位）—— 不含定位态。
    var isFetching: Bool { weatherPhase.isFetching }

    /// 兼容只读入口：是否正在搜索。
    ///
    /// ★ 这一条是**真实编译**抓出来的：M4 首次落地时漏了它，swift-frontend -parse 只看语法所以放行，
    /// 直到 macOS 客机 xcodebuild 才报 value of type 'WeatherService' has no dynamic member 'isSearching'。
    /// 门禁已同步补上正向断言（见 verify_weather_state 的断言 0）。
    var isSearching: Bool { searchPhase.isSearching }

    /// 兼容只读入口：搜索建议列表。
    var searchResults: [WeatherLocation] { searchPhase.items }

    /// 兼容只读入口：最近一次**被采纳**的失败信息。
    var lastError: String? { weatherPhase.failureMessage ?? searchPhase.failureMessage }

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

    /// **纯查询**：读取指定日期的缓存天气，绝不产生任何副作用。
    ///
    /// 渲染路径（`body` / 计算属性）只允许走这一个入口。
    ///
    /// 旧实现会在这里 `Task { await fetchWeather(for: date) }` —— 于是一次 SwiftUI
    /// 求值就触发一次网络请求，**状态机的时钟变成了渲染回合**：读操作会写，
    /// 而「读不产生副作用」正是本项目对 `@Observable` 分层的基本约定。
    /// 两处调用点（`DayEditorView` 的 `.task` 与 `WeatherLocationSheet` 的 `.task`）
    /// 本来就各自显式调了 `fetchWeather`，所以去掉这里的副作用不改变任何可见行为。
    ///
    /// 需要发起请求请显式调用 `requestWeather(for:)`。
    func weather(for date: Date) -> WeatherInfo? {
        cachedWeather(for: date)
    }

    /// 缓存读取（无副作用，纯字典查找）。
    func cachedWeather(for date: Date) -> WeatherInfo? {
        weatherCache[cacheKey(for: date, location: currentLocation)]
    }

    /// 显式请求指定日期的天气（缓存新鲜则内部直接返回）。
    @discardableResult
    func requestWeather(for date: Date) -> Task<Void, Never> {
        Task { await fetchWeather(for: date) }
    }

    /// 格式化包含天气的页面标题：`{日期} 天气{描述} 气温{min}~{max}摄氏度`
    func fullTitle(for date: Date) -> String {
        let baseDateTitle = CalendarUtils.dayTitle(date)
        if let weather = weather(for: date) {
            return "\(baseDateTitle) \(weather.formattedWeatherSegment)"
        }
        return baseDateTitle
    }

    /// 拉取指定日期的天气。
    ///
    /// 所有相位写入都经 `WeatherStatePolicy.reduce`，且携带本次请求的代次：
    /// **只有代次不早于当前活跃代次的响应才能改变相位**。
    func fetchWeather(for date: Date) async {
        let dateKey = CalendarUtils.key(for: date)
        let key = cacheKey(for: date, location: currentLocation)

        // 缓存仍然新鲜：不重复请求，也完全不动相位。
        if let existing = weatherCache[key],
           WeatherStatePolicy.isCacheFresh(updatedAt: existing.updatedAt, now: Date()) {
            return
        }

        weatherGeneration &+= 1
        let generation = weatherGeneration
        emit(.fetchBegan(generation: generation))

        let lat = currentLocation.latitude
        let lon = currentLocation.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&start_date=\(dateKey)&end_date=\(dateKey)"
        
        guard let url = URL(string: urlString) else {
            // 必须收尾：否则相位永久停在 .fetching，isFetching 再也回不到 false。
            emit(.failed(message: "天气请求地址无效", generation: generation))
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                emit(.failed(message: "天气接口响应异常 (\(http.statusCode))", generation: generation))
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
                emit(.failed(message: "天气数据格式无法识别", generation: generation))
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
            emit(.succeeded(updatedAt: info.updatedAt, generation: generation))
        } catch {
            emit(.failed(message: error.localizedDescription, generation: generation))
        }
    }

    /// 唯一的天气相位写入点。
    ///
    /// 事件自带的代次早于 `weatherGeneration` 时，`reduce` 会原样返回旧相位 ——
    /// 不写、不清、不改 `isFetching`。这就是「先返回者提前熄火」的修法。
    private func emit(_ event: WeatherEvent) {
        weatherPhase = WeatherStatePolicy.reduce(weatherPhase,
                                                 event: event,
                                                 latestGeneration: weatherGeneration)
    }

    // MARK: - 搜索城市

    func searchCities(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 清空输入 = 作废在途搜索：代次先推进，迟到响应就再也无法把建议列表写回来。
            searchGeneration &+= 1
            emitSearch(.cleared)
            return
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=8&language=zh&format=json") else {
            return
        }

        searchGeneration &+= 1
        let generation = searchGeneration
        emitSearch(.began(query: trimmed, generation: generation))

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
            let mapped = items.map {
                WeatherLocation(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, admin1: $0.admin1, country: $0.country)
            }
            emitSearch(.succeeded(query: trimmed, generation: generation, items: mapped))
        } catch {
            emitSearch(.failed(query: trimmed, generation: generation, message: error.localizedDescription))
        }
    }

    /// 唯一的搜索相位写入点（与 `emit` 共用同一条代次采纳规则）。
    ///
    /// 快速连续输入会并发发出多次搜索：旧实现里任何一次返回都会覆盖
    /// `searchResults`，于是结果与输入框内容对不上。带代次后，只有最后一次
    /// `.began` 之后发出的那次响应能落地。
    private func emitSearch(_ event: CitySearchEvent) {
        searchPhase = CitySearchPolicy.reduce(searchPhase,
                                              event: event,
                                              latestGeneration: searchGeneration)
    }

    func selectLocation(_ location: WeatherLocation) {
        useAutoLocation = false
        currentLocation = location
        searchGeneration &+= 1
        emitSearch(.cleared)
    }

    // MARK: - CoreLocation 自动定位

    func requestLocation() {
        let status = locationManager.authorizationStatus
        // 只在**确实会发起定位**时才进入定位相位：
        // `.denied` / `.restricted` 不会再有任何回调，进去就永久粘住。
        if status == .notDetermined {
            emit(.locateBegan)
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            emit(.locateBegan)
            locationManager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if (status == .authorizedWhenInUse || status == .authorizedAlways) && self.useAutoLocation {
                self.locationManager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        Task { @MainActor in
            await self.resolveLocationName(latitude: lat, longitude: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.emit(.locateEnded)
            self.emit(.failed(message: "定位失败：\(msg)", generation: self.weatherGeneration))
        }
    }

    private func resolveLocationName(latitude lat: Double, longitude lon: Double) async {
        let loc = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()
        defer { emit(.locateEnded) }   // 无论成败都收尾定位相位，绝不粘住 isBusy
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(loc),
              let mark = placemarks.first else {
            currentLocation = WeatherLocation(name: "当前位置", latitude: lat, longitude: lon, admin1: nil, country: nil)
            return
        }
        let name = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea ?? "当前位置"
        currentLocation = WeatherLocation(
            name: name,
            latitude: lat,
            longitude: lon,
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

    nonisolated static func wmoSymbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1: return "sun.min.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "sun.max.fill"
        }
    }
}
