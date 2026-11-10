#!/usr/bin/env swift
//
//  verify_weather_state.swift
//  天气 / 城市搜索相位机门禁（CI 以 --strict 执行）
//
//  钉三类用户实测报回来的回退：
//
//  【加载态提前熄火】旧实现用 `isFetching = true` + `defer { isFetching = false }`
//     包住 `await`。两次请求重叠（例如「自动定位」刚触发一次、用户又点刷新）时，
//     先返回的那次会把标志提前清掉，界面于是在另一次请求仍在飞行时显示
//     「暂无缓存天气」。本门禁从两个方向钉死它：
//     ① 相位 + 代次的纯逻辑语义（断言 1、2）；
//     ② 生产源码不得再出现 `defer { isFetching` 这一形状（断言 0，文本护栏）。
//
//  【渲染回合变成状态机时钟】旧实现的 `weather(for:)` 是个 getter，却在缓存未命中时
//     `Task { await fetchWeather(for: date) }`。于是 SwiftUI 求值一次就发一次网络请求。
//     本门禁用 declarationBody 精确断言：`weather(for:)` 体内不得出现 `Task {`。
//
//  【搜索结果与输入框对不上】快速连续输入会并发发出多次搜索，旧实现里任何一次返回
//     都会覆盖 `searchResults`。本门禁用代次乱序序列钉死它（断言 4）。
//
//  运行：swift scripts/verify_weather_state.swift [--strict]
//

import Foundation

// MARK: - 迷你断言框架

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    checks += 1
    if lhs != rhs { failures.append("\(label)：期望 \(rhs)，实际 \(lhs)") }
}

// MARK: - 被测逻辑（生产代码的镜像）

/// 镜像 SeeingCalendar/Store/WeatherStatePolicy.swift 的 WeatherLocation 替身。
struct Loc: Equatable {
    let name: String
}

enum Phase: Equatable {
    case idle
    case locating
    case fetching(generation: Int)
    case ready(updatedAt: Date)
    case failed(message: String, generation: Int)

    var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

enum Event: Equatable {
    case reset
    case locateBegan
    case locateEnded
    case fetchBegan(generation: Int)
    case succeeded(updatedAt: Date, generation: Int)
    case failed(message: String, generation: Int)
}

enum SearchPhase: Equatable {
    case idle
    case searching(query: String, generation: Int)
    case results(query: String, generation: Int, items: [Loc])
    case failed(query: String, generation: Int, message: String)

    var items: [Loc] {
        if case .results(_, _, let items) = self { return items }
        return []
    }

    var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }
}

enum SearchEvent: Equatable {
    case cleared
    case began(query: String, generation: Int)
    case succeeded(query: String, generation: Int, items: [Loc])
    case failed(query: String, generation: Int, message: String)
}

enum Policy {
    static let cacheTTL: TimeInterval = 7200

    static func isCacheFresh(updatedAt: Date, now: Date, ttl: TimeInterval = cacheTTL) -> Bool {
        now.timeIntervalSince(updatedAt) < ttl
    }

    static func accepts(generation: Int, latest: Int) -> Bool {
        generation >= latest
    }

    static func isBusy(_ phase: Phase) -> Bool {
        switch phase {
        case .locating, .fetching: return true
        case .idle, .ready, .failed: return false
        }
    }

    static func isFetching(_ phase: Phase) -> Bool {
        if case .fetching = phase { return true }
        return false
    }

    static func reduce(_ phase: Phase, event: Event, latestGeneration: Int) -> Phase {
        switch event {
        case .reset:
            return .idle

        case .locateBegan:
            return isBusy(phase) ? phase : .locating

        case .locateEnded:
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

    static func reduceSearch(_ phase: SearchPhase, event: SearchEvent, latestGeneration: Int) -> SearchPhase {
        switch event {
        case .cleared:
            return .idle

        case .began(let query, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .searching(query: query, generation: generation)

        case .succeeded(let query, let generation, let items):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .results(query: query, generation: generation, items: items)

        case .failed(let query, let generation, let message):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .failed(query: query, generation: generation, message: message)
        }
    }
}

/// 破坏变体：忽略代次、无条件采纳 —— 旧实现的行为形状。
enum BrokenPolicy {
    static func reduce(_ phase: Phase, event: Event, latestGeneration: Int) -> Phase {
        switch event {
        case .reset:
            return .idle
        case .locateBegan:
            return Policy.isBusy(phase) ? phase : .locating
        case .locateEnded:
            return phase == .locating ? .idle : phase
        case .fetchBegan(let generation):
            return .fetching(generation: generation)
        case .succeeded(let updatedAt, _):
            return .ready(updatedAt: updatedAt)
        case .failed(let message, let generation):
            return .failed(message: message, generation: generation)
        }
    }
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 取出某个声明的主体（花括号配平）。找不到返回 nil。
func declarationBody(of declaration: String, in source: String) -> String? {
    guard let start = source.range(of: declaration),
          let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var index = open.lowerBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        else if character == "}" {
            depth -= 1
            if depth == 0 { return String(source[open.lowerBound...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private let allPhases: [Phase] = [
    .idle,
    .locating,
    .fetching(generation: 1),
    .ready(updatedAt: epoch),
    .failed(message: "boom", generation: 1)
]

private let allEvents: [Event] = [
    .reset,
    .locateBegan,
    .locateEnded,
    .fetchBegan(generation: 1),
    .succeeded(updatedAt: epoch, generation: 1),
    .failed(message: "boom", generation: 1)
]

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    let policy = productionSource("SeeingCalendar/Store/WeatherStatePolicy.swift")
    check(policy != nil, "找不到 WeatherStatePolicy.swift")
    check(policy?.contains("enum WeatherPhase: Equatable, Sendable") == true,
          "WeatherPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy?.contains("case locating") == true, "WeatherPhase 必须保留 .locating")
    check(policy?.contains("case fetching(generation: Int)") == true,
          "WeatherPhase.fetching 必须携带代次")
    check(policy?.contains("case ready(updatedAt: Date)") == true, "WeatherPhase 必须保留 .ready")
    check(policy?.contains("case failed(message: String, generation: Int)") == true,
          "WeatherPhase.failed 必须同时携带信息与代次")
    check(policy?.contains("case locateEnded") == true,
          "必须保留 locateEnded —— 否则 .locating 会永久粘住 isBusy")
    check(policy?.contains("static func accepts(generation: Int, latest: Int) -> Bool") == true,
          "代次采纳判定必须是独立可测的纯函数")
    check(policy?.contains("generation >= latest") == true,
          "采纳规则必须是 >=（相等即采纳），否则单次同步请求会被自己拒绝")
    check(policy?.contains("static func isFetching(_ phase: WeatherPhase) -> Bool") == true,
          "isFetching 必须与 isBusy 分离：刷新按钮的 disabled 语义是「拉取天气」")
    check(policy?.contains("return phase == .locating ? .idle : phase") == true,
          "locateEnded 只允许收尾定位态，不得碰 ready / failed / fetching")
    check(policy?.contains("static let cacheTTL: TimeInterval = 7200") == true,
          "缓存窗口必须是具名常量，不许再在 fetchWeather 里写 7200 字面量")

    let service = productionSource("SeeingCalendar/Store/WeatherService.swift")
    check(service != nil, "找不到 WeatherService.swift")
    check(service?.contains("private(set) var weatherPhase: WeatherPhase = .idle") == true,
          "weatherPhase 必须是单一真值入口")
    check(service?.contains("private(set) var searchPhase: CitySearchPhase = .idle") == true,
          "searchPhase 必须是单一真值入口")
    check(service?.contains("var isFetching: Bool { weatherPhase.isFetching }") == true,
          "isFetching 必须降级为只读投影")
    check(service?.contains("var searchResults: [WeatherLocation] { searchPhase.items }") == true,
          "searchResults 必须降级为只读投影")
    // ★ 真实编译抓出来的回归：M4 首次落地漏了 isSearching 投影，
    // swift-frontend -parse 只看语法所以放行，直到 xcodebuild 才报没有该成员。
    check(service?.contains("var isSearching: Bool { searchPhase.isSearching }") == true,
          "★ isSearching 必须降级为只读投影（缺了就是编译错误，不是行为差异）")
    check(service?.contains("var lastError: String? { weatherPhase.failureMessage ?? searchPhase.failureMessage }") == true,
          "lastError 必须降级为只读投影")
    check(service?.contains("private func emit(_ event: WeatherEvent)") == true,
          "必须存在唯一的天气相位写入点")
    check(service?.contains("private func emitSearch(_ event: CitySearchEvent)") == true,
          "必须存在唯一的搜索相位写入点")
    check(service?.contains("weatherGeneration &+= 1") == true,
          "fetchWeather 必须推进拉取代次")
    check(service?.contains("searchGeneration &+= 1") == true,
          "搜索路径必须推进搜索代次（含清空输入时作废在途请求）")
    check(service?.contains("emit(.fetchBegan(generation: generation))") == true,
          "fetchBegan 必须携带本次代次")

    // 负向护栏：旧形状不得回潮
    check(service?.contains("private(set) var isFetching = false") != true,
          "不得回退为 isFetching 存储旗标")
    // 精确到函数体：文件级检查会被「识别旧形状」的说明性注释误伤。
    if let fetchBody = declarationBody(of: "func fetchWeather(for date: Date) async", in: service ?? "") {
        check(!fetchBody.contains("defer { isFetching"),
              "★ fetchWeather 体内不得回退为 defer 熄火（这正是「提前熄火」的成因）")
        check(fetchBody.contains("emit(.fetchBegan(generation: generation))"),
              "fetchWeather 必须以携带代次的 fetchBegan 开局")
    } else {
        check(false, "无法定位 fetchWeather 的函数体 —— 签名改了吗？")
    }
    check(service?.contains("private(set) var searchResults: [WeatherLocation] = []") != true,
          "不得回退为 searchResults 存储数组")
    check(service?.contains("private(set) var isSearching = false") != true,
          "不得回退为 isSearching 存储旗标")

    // 渲染路径纯净性：weather(for:) 体内不得发起请求
    if let body = declarationBody(of: "func weather(for date: Date) -> WeatherInfo?", in: service ?? "") {
        check(!body.contains("Task {"),
              "weather(for:) 是渲染路径入口，体内不得出现 Task {（渲染求值不得触发网络）")
        check(!body.contains("fetchWeather"),
              "weather(for:) 不得直接调用 fetchWeather")
        check(body.contains("cachedWeather(for: date)"),
              "weather(for:) 必须委派给无副作用的 cachedWeather(for:)")
    } else {
        check(false, "无法定位 weather(for:) 的函数体 —— 签名改了吗？")
    }

    check(service?.contains("func requestWeather(for date: Date) -> Task<Void, Never>") == true,
          "必须提供显式请求入口 requestWeather(for:)")
}

// MARK: - 断言 1：相位 × 事件的穷举不变量

func verifyExhaustiveInvariants() {
    for phase in allPhases {
        for event in allEvents {
            for latest in [0, 1, 2] {
                let next = Policy.reduce(phase, event: event, latestGeneration: latest)
                let label = "\(phase) × \(event) @latest=\(latest)"

                if case .reset = event {
                    checkEqual(next, .idle, "\(label) 的 reset 必须回到 idle")
                    check(!Policy.isBusy(next), "\(label) 的 reset 之后不得仍为忙碌")
                }

                let rejected: Bool
                switch event {
                case .fetchBegan(let g), .succeeded(_, let g), .failed(_, let g):
                    rejected = !Policy.accepts(generation: g, latest: latest)
                default:
                    rejected = false
                }
                if rejected {
                    checkEqual(next, phase, "\(label) 的迟到事件必须原样返回旧相位")
                }

                if Policy.accepts(generation: 1, latest: latest) {
                    switch event {
                    case .succeeded:
                        checkEqual(next, .ready(updatedAt: epoch), "\(label) 的采纳后必须落到 ready")
                    case .failed:
                        checkEqual(next, .failed(message: "boom", generation: 1), "\(label) 的采纳后必须落到 failed")
                    default:
                        break
                    }
                }

                if Policy.isFetching(next) {
                    check(Policy.isBusy(next), "\(label) isFetching 蕴含 isBusy")
                }

                checkEqual(Policy.isBusy(next) != Policy.isFetching(next), next == .locating,
                           "\(label) isBusy 与 isFetching 的分歧必须恰好是 .locating")

                if case .locateBegan = event, Policy.isBusy(phase) {
                    checkEqual(next, phase, "\(label) locateBegan 不得抹掉飞行中的进度")
                }

                if case .locateEnded = event {
                    // 只要求「不再停在定位态」：locateEnded 刻意不碰 ready / failed / fetching。
                    check(next != .locating, "\(label) locateEnded 之后绝不能仍停在定位态（否则永久粘住）")
                }
            }
        }
    }

    check(Policy.accepts(generation: 3, latest: 3), "代次相等必须采纳（否则单次同步请求会被自己拒绝）")
    check(Policy.accepts(generation: 4, latest: 3), "更新的代次必须采纳")
    check(!Policy.accepts(generation: 2, latest: 3), "更旧的代次必须拒绝")
}

// MARK: - 断言 2：重叠请求不得互相提前熄火

func verifyGenerationAdoption() {
    var phase: Phase = .idle
    phase = Policy.reduce(phase, event: .fetchBegan(generation: 1), latestGeneration: 1)
    check(Policy.isFetching(phase), "第一次请求应在拉取中")

    phase = Policy.reduce(phase, event: .fetchBegan(generation: 2), latestGeneration: 2)
    checkEqual(phase, .fetching(generation: 2), "第二次请求应推进代次")

    phase = Policy.reduce(phase, event: .succeeded(updatedAt: epoch, generation: 1), latestGeneration: 2)
    checkEqual(phase, .fetching(generation: 2),
               "★ 迟到响应不得改变相位 —— 旧实现在这里会提前熄火成非忙碌")
    check(Policy.isFetching(phase), "★ 第二次请求仍在飞行时，界面必须继续显示加载中")

    phase = Policy.reduce(phase, event: .failed(message: "stale", generation: 1), latestGeneration: 2)
    checkEqual(phase, .fetching(generation: 2), "★ 迟到的失败也不得覆盖相位")

    phase = Policy.reduce(phase, event: .succeeded(updatedAt: epoch, generation: 2), latestGeneration: 2)
    checkEqual(phase, .ready(updatedAt: epoch), "最新的响应必须落地")
    check(!Policy.isBusy(phase), "落地后不得仍为忙碌")

    var single: Phase = .idle
    single = Policy.reduce(single, event: .fetchBegan(generation: 1), latestGeneration: 1)
    single = Policy.reduce(single, event: .failed(message: "net", generation: 1), latestGeneration: 1)
    checkEqual(single, .failed(message: "net", generation: 1), "单次请求的失败必须落地")
    checkEqual(single.failureMessage, "net", "失败信息必须可读")
}

// MARK: - 断言 3：定位相位不得粘住

func verifyLocatingCoherence() {
    var phase: Phase = .idle
    phase = Policy.reduce(phase, event: .locateBegan, latestGeneration: 0)
    checkEqual(phase, .locating, "requestLocation 应进入定位态")
    check(Policy.isBusy(phase), "定位态算忙碌")
    check(!Policy.isFetching(phase), "★ 定位态不得让刷新按钮变灰（isFetching 语义严格是「拉取天气」）")

    phase = Policy.reduce(phase, event: .locateEnded, latestGeneration: 0)
    checkEqual(phase, .idle, "定位收尾必须回到 idle")
    check(!Policy.isBusy(phase), "★ 收尾后 isBusy 必须为 false —— 否则权限被拒时永久粘住")

    for other in [Phase.ready(updatedAt: epoch), .failed(message: "x", generation: 1), .fetching(generation: 1), .idle] {
        let after = Policy.reduce(other, event: .locateEnded, latestGeneration: 1)
        checkEqual(after, other, "locateEnded 不得改写 \(other)")
    }

    let flying = Policy.reduce(.fetching(generation: 1), event: .locateBegan, latestGeneration: 1)
    checkEqual(flying, .fetching(generation: 1), "locateBegan 不得抹掉飞行中的拉取")
}

// MARK: - 断言 4：搜索结果必须与输入框一致（乱序响应）

func verifySearchOrdering() {
    var phase: SearchPhase = .idle

    phase = Policy.reduceSearch(phase, event: .began(query: "bei", generation: 1), latestGeneration: 1)
    check(phase.isSearching, "第一次搜索应在搜索中")

    phase = Policy.reduceSearch(phase, event: .began(query: "beijing", generation: 2), latestGeneration: 2)
    checkEqual(phase, .searching(query: "beijing", generation: 2), "第二次搜索应推进代次")

    phase = Policy.reduceSearch(phase,
                                event: .succeeded(query: "bei", generation: 1, items: [Loc(name: "北京")]),
                                latestGeneration: 2)
    check(phase.items.isEmpty, "★ 迟到的 q1 结果不得写入 —— 否则建议列表与输入框对不上")
    checkEqual(phase, .searching(query: "beijing", generation: 2), "★ 陈旧的搜索结果不得改变相位")

    phase = Policy.reduceSearch(phase,
                                event: .succeeded(query: "beijing", generation: 2, items: [Loc(name: "北京"), Loc(name: "北京市")]),
                                latestGeneration: 2)
    checkEqual(phase.items.count, 2, "最新一次搜索的结果必须落地")

    phase = Policy.reduceSearch(phase, event: .cleared, latestGeneration: 3)
    checkEqual(phase, .idle, "清空输入必须回到 idle")
    check(phase.items.isEmpty, "清空后不得残留建议")

    let late = Policy.reduceSearch(phase,
                                   event: .succeeded(query: "beijing", generation: 2, items: [Loc(name: "北京")]),
                                   latestGeneration: 3)
    check(late.items.isEmpty, "★ 清空之后到达的响应不得把建议列表写回来")

    var fresh: SearchPhase = .idle
    fresh = Policy.reduceSearch(fresh, event: .began(query: "sh", generation: 5), latestGeneration: 5)
    let staleFailure = Policy.reduceSearch(fresh,
                                           event: .failed(query: "sh", generation: 4, message: "boom"),
                                           latestGeneration: 5)
    checkEqual(staleFailure, .searching(query: "sh", generation: 5), "陈旧的搜索失败不得覆盖相位")
}

// MARK: - 断言 5：缓存新鲜度边界

func verifyCacheFreshness() {
    let now = epoch
    check(Policy.isCacheFresh(updatedAt: now, now: now), "刚写入的缓存必须新鲜")
    check(Policy.isCacheFresh(updatedAt: now.addingTimeInterval(-7199), now: now), "7199 秒前仍新鲜")
    check(!Policy.isCacheFresh(updatedAt: now.addingTimeInterval(-7201), now: now), "7201 秒前已过期")
    check(!Policy.isCacheFresh(updatedAt: now.addingTimeInterval(-7200), now: now), "恰好 7200 秒即过期（半开区间）")
    checkEqual(Policy.cacheTTL, 7200, "TTL 必须仍是 2 小时")
}

// MARK: - 断言 6：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    var caught = false
    for phase in allPhases {
        for latest in [1, 2] {
            for event in allEvents {
                let good = Policy.reduce(phase, event: event, latestGeneration: latest)
                let bad = BrokenPolicy.reduce(phase, event: event, latestGeneration: latest)
                if brokenVariantWouldMisbehave(phase: phase, event: event, latest: latest) {
                    caught = caught || (good != bad)
                }
            }
        }
    }
    check(caught, "★ 忽略代次的破坏变体必须与正确实现产生不同结果（检查器不能退化成恒真）")

    let flying: Phase = .fetching(generation: 2)
    let good = Policy.reduce(flying, event: .succeeded(updatedAt: epoch, generation: 1), latestGeneration: 2)
    let bad = BrokenPolicy.reduce(flying, event: .succeeded(updatedAt: epoch, generation: 1), latestGeneration: 2)
    checkEqual(good, flying, "正确实现必须拒绝迟到响应")
    checkEqual(bad, .ready(updatedAt: epoch), "破坏变体确实会把相位改成 ready —— 反证有效")
    check(good != bad, "正反两实现必须在迟到响应上分歧")

    check(Policy.accepts(generation: 3, latest: 3), "边界上相等必须采纳")
    check(!(4 == 3) && Policy.accepts(generation: 4, latest: 3),
          "★ 严格相等变体会拒绝更新的代次 —— 必须与 >= 分歧，门禁据此识别回退")
}

private func brokenVariantWouldMisbehave(phase: Phase, event: Event, latest: Int) -> Bool {
    if case .fetchBegan(let g) = event { return g < latest && phase != .fetching(generation: g) }
    if case .succeeded = event, latest > 1 { return phase != .ready(updatedAt: epoch) }
    if case .failed = event, latest > 1 { return phase != .failed(message: "boom", generation: 1) }
    return false
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyGenerationAdoption()
verifyLocatingCoherence()
verifySearchOrdering()
verifyCacheFreshness()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 天气相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
