import Foundation

/// 天气请求相位。
///
/// 为什么需要它：旧实现用 `isFetching: Bool` + `defer { isFetching = false }` 包住
/// `await`。两次请求重叠时，**先返回的那次会把标志提前熄火**，UI 于是在另一次
/// 请求仍在飞行时显示“暂无缓存天气”。相位 + 代次把这件事变成不可表达的非法态：
/// 只有代次不早于当前代次的响应才允许改变相位（见 `WeatherStatePolicy.reduce`）。
enum WeatherPhase: Equatable, Sendable {
    case idle
    /// 正在向系统请求定位权限 / 定位结果。
    case locating
    /// 正在拉取指定代次的天气。
    case fetching(generation: Int)
    /// 已拿到有效数据。
    case ready(updatedAt: Date)
    /// 最近一次**被采纳**的请求失败。
    case failed(message: String, generation: Int)

    /// 界面上的「加载中」：定位与拉取都算忙碌。
    var isBusy: Bool { WeatherStatePolicy.isBusy(self) }

    /// 是否正在拉取天气。
    ///
    /// 与 `isBusy` **刻意不同**：`isBusy` 把 `.locating` 也算进去，
    /// 而本投影严格等价于旧实现的 `isFetching`（只由 `fetchWeather` 置位）——
    /// 界面上的刷新按钮用它做 `disabled`，语义必须是「拉取天气」而不是「在做任何事」。
    var isFetching: Bool { WeatherStatePolicy.isFetching(self) }

    /// 是否正在定位。
    var isLocating: Bool { if case .locating = self { return true }; return false }

    /// 失败信息（供兼容只读入口使用）。
    var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

/// 城市搜索相位。
///
/// `generation` 是**乱序响应**的丢弃依据：快速连续输入会并发发出多次搜索，
/// 旧实现里任何一次返回都会覆盖 `searchResults`，于是结果与输入框内容对不上。
enum CitySearchPhase: Equatable, Sendable {
    case idle
    case searching(query: String, generation: Int)
    case results(query: String, generation: Int, items: [WeatherLocation])
    case failed(query: String, generation: Int, message: String)

    var query: String {
        switch self {
        case .idle: return ""
        case .searching(let query, _), .results(let query, _, _), .failed(let query, _, _):
            return query
        }
    }

    var isSearching: Bool { CitySearchPolicy.isSearching(self) }

    var items: [WeatherLocation] { CitySearchPolicy.results(self) }

    /// 失败信息（供兼容只读入口使用）。
    var failureMessage: String? {
        if case .failed(_, _, let message) = self { return message }
        return nil
    }
}

/// 天气相位机的驱动事件。
enum WeatherEvent: Equatable, Sendable {
    case reset
    case locateBegan
    /// 定位流程收尾（成功取到坐标 / 失败 / 权限被拒）。
    ///
    /// 没有它，`.locating` 会永久粘住：定位一旦因权限被拒而不回调坐标，
    /// `isBusy` 就再也不会回到 false。
    case locateEnded
    case fetchBegan(generation: Int)
    case succeeded(updatedAt: Date, generation: Int)
    case failed(message: String, generation: Int)
}

/// 搜索相位机的驱动事件。
enum CitySearchEvent: Equatable, Sendable {
    case cleared
    case began(query: String, generation: Int)
    case succeeded(query: String, generation: Int, items: [WeatherLocation])
    case failed(query: String, generation: Int, message: String)
}

/// 天气 / 搜索相位机。
///
/// **纯逻辑**：不依赖 SwiftUI / CoreLocation / URLSession / UIKit，
/// 因此可被 `scripts/verify_weather_state.swift` 直接镜像并穷举 (相位 × 事件) 全组合验证。
///
/// 固化的不变量：
///
/// 1. **迟到响应不得改变相位**。`accepts(generation:latest:)` 是唯一判据；
///    被拒绝的响应连 `isBusy` 都不能碰 —— 这正是「先返回者提前熄火」的修法。
/// 2. **`.reset` 之后必定回到 `.idle`**，且 `isBusy == false`，与之前是哪个相位无关。
/// 3. **相位不会无故丢失代次**：任何被采纳的 `fetchBegan(g)` 之后，
///    只有代次 ≥ g 的事件能改变相位。
/// 4. **搜索相位永不自称“有结果”却携带空 query**：`results` / `failed` 都带 query。
enum WeatherStatePolicy {
    /// 缓存新鲜度窗口（原为 `fetchWeather` 内联的 7200 秒字面量）。
    static let cacheTTL: TimeInterval = 7200

    /// 缓存是否仍然新鲜。
    static func isCacheFresh(updatedAt: Date, now: Date, ttl: TimeInterval = cacheTTL) -> Bool {
        now.timeIntervalSince(updatedAt) < ttl
    }

    /// 响应采纳判定：**只有代次不早于当前代次才采纳**。
    static func accepts(generation: Int, latest: Int) -> Bool {
        generation >= latest
    }

    /// 界面是否需要显示「加载中」：定位与拉取都算忙碌。
    static func isBusy(_ phase: WeatherPhase) -> Bool {
        switch phase {
        case .locating, .fetching: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// 严格等价于旧实现的 `isFetching`（只由 `fetchWeather` 置位）。
    /// 与 `isBusy` 的**唯一**分歧点是 `.locating` —— 门禁对这一分歧有显式断言。
    static func isFetching(_ phase: WeatherPhase) -> Bool {
        if case .fetching = phase { return true }
        return false
    }

    /// 相位转移。`latestGeneration` 是当前活跃请求的代次。
    ///
    /// 早于 `latestGeneration` 的事件一律**原样返回当前相位** —— 不写、不清、
    /// 不改 `isBusy`。这是本状态机的核心纪律。
    static func reduce(_ phase: WeatherPhase,
                       event: WeatherEvent,
                       latestGeneration: Int) -> WeatherPhase {
        switch event {
        case .reset:
            return .idle

        case .locateBegan:
            // 已有拉取在飞行时不降级为定位态，避免把飞行中的进度抹掉。
            return isBusy(phase) ? phase : .locating

        case .locateEnded:
            // 只收尾定位态：不碰 ready / failed / fetching。
            return phase == .locating ? .idle : phase

        case .fetchBegan(let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .fetching(generation: generation)

        case .succeeded(let updatedAt, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .ready(updatedAt: updatedAt)

        case .failed(let message, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .failed(message: message, generation: generation)
        }
    }
}

/// 搜索相位机（与天气相位机共用同一条代次采纳规则）。
enum CitySearchPolicy {
    static func isSearching(_ phase: CitySearchPhase) -> Bool {
        if case .searching = phase { return true }
        return false
    }

    /// 搜索结果的只读投影（兼容旧入口）。
    static func results(_ phase: CitySearchPhase) -> [WeatherLocation] {
        if case .results(_, _, let items) = phase { return items }
        return []
    }

    static func reduce(_ phase: CitySearchPhase,
                       event: CitySearchEvent,
                       latestGeneration: Int) -> CitySearchPhase {
        switch event {
        case .cleared:
            return .idle

        case .began(let query, let generation):
            guard WeatherStatePolicy.accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .searching(query: query, generation: generation)

        case .succeeded(let query, let generation, let items):
            guard WeatherStatePolicy.accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .results(query: query, generation: generation, items: items)

        case .failed(let query, let generation, let message):
            guard WeatherStatePolicy.accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .failed(query: query, generation: generation, message: message)
        }
    }
}
