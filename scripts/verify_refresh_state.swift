#!/usr/bin/env swift
//
//  verify_refresh_state.swift
//  M5「CalendarEventStore 刷新生命周期」相位机门禁（CI 以 --strict 执行）
//
//  钉三类用户实测报回来的回退：
//
//  【加载态提前熄火】旧实现用存储布尔旗标 + `defer { isRefreshing = false }` 包住
//     `await`。并发刷新时先返回的那次会把旗标提前清掉，界面于是在另一趟请求仍在
//     飞行时把加载指示收回。本门禁从两个方向钉死它：
//     ① 相位 + 代次的纯逻辑语义（断言 1、2、3）；
//     ② 生产源码不得再出现 `defer { isRefreshing` 与存储式旗标这一形状（断言 0，文本护栏）。
//
//  【迟到的刷新结果覆盖新结果】没有代次纪律，先发出的陈旧刷新落地时会盖回旧结果。
//     本门禁用「重叠刷新序列」与「破坏变体反证」钉死它（断言 2、5）。
//
//  【冷却窗口无处存放】旧实现把窗口写成每次现算的时间谓词
//     `now.timeIntervalSince(lastRefresh) < 900`。本门禁要求窗口是**状态**，
//     并逐位等价地复现旧谓词（断言 4）。
//
//  运行：swift scripts/verify_refresh_state.swift [--strict]
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

// MARK: - 被测逻辑（生产代码 RefreshPhasePolicy.swift 的镜像）

enum Phase: Equatable {
    case idle
    case refreshing(startedAt: Date, generation: Int)
    case coolingDown(until: Date, generation: Int)
    case failed(message: String, generation: Int)
}

enum Event: Equatable {
    case began(startedAt: Date, generation: Int)
    case succeeded(at: Date, generation: Int)
    case failed(message: String, at: Date, generation: Int)
    case cleared
}

enum Policy {
    static let cooldown: TimeInterval = 900

    static func accepts(generation: Int, latest: Int) -> Bool {
        return generation >= latest
    }

    static func isRefreshing(_ phase: Phase) -> Bool {
        if case .refreshing = phase { return true }
        return false
    }

    static func shouldSkip(phase: Phase, now: Date, force: Bool, hasEvents: Bool) -> Bool {
        guard !force, hasEvents else { return false }
        guard case .coolingDown(let until, _) = phase else { return false }
        return now < until
    }

    static func reduce(_ phase: Phase, event: Event, latestGeneration: Int) -> Phase {
        switch event {
        case .cleared:
            return .idle

        case .began(let startedAt, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .refreshing(startedAt: startedAt, generation: generation)

        case .succeeded(let at, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .coolingDown(until: at.addingTimeInterval(cooldown), generation: generation)

        case .failed(let message, _, let generation):
            guard accepts(generation: generation, latest: latestGeneration) else { return phase }
            return .failed(message: message, generation: generation)
        }
    }
}

/// 破坏变体：忽略代次、无条件采纳 —— 旧实现「迟到响应覆盖新结果」的行为形状。
enum BrokenPolicy {
    static func reduce(_ phase: Phase, event: Event, latestGeneration: Int) -> Phase {
        switch event {
        case .cleared:
            return .idle
        case .began(let startedAt, let generation):
            return .refreshing(startedAt: startedAt, generation: generation)
        case .succeeded(let at, let generation):
            return .coolingDown(until: at.addingTimeInterval(Policy.cooldown), generation: generation)
        case .failed(let message, _, let generation):
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
    .refreshing(startedAt: epoch, generation: 1),
    .coolingDown(until: epoch, generation: 1),
    .failed(message: "boom", generation: 1)
]

private let allEvents: [Event] = [
    .began(startedAt: epoch, generation: 1),
    .succeeded(at: epoch, generation: 1),
    .failed(message: "boom", at: epoch, generation: 1),
    .cleared
]

private let allLatest = [0, 1, 2]

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    guard let policySource = productionSource("SeeingCalendar/ICS/RefreshPhasePolicy.swift") else {
        check(false, "找不到 RefreshPhasePolicy.swift")
        return
    }
    check(policySource.contains("enum RefreshPhase: Equatable, Sendable"),
          "RefreshPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policySource.contains("case refreshing(startedAt: Date, generation: Int)"),
          "refreshing 必须同时携带开局时刻与代次")
    check(policySource.contains("case coolingDown(until: Date, generation: Int)"),
          "★ 冷却窗口必须是状态（coolingDown.until），不许退化成每次现算的时间比较")
    check(policySource.contains("case failed(message: String, generation: Int)"),
          "failed 必须同时携带信息与代次")
    check(policySource.contains("enum RefreshEvent: Equatable, Sendable"),
          "RefreshEvent 必须仍是 Equatable + Sendable 的纯值类型")
    check(policySource.contains("case began(startedAt: Date, generation: Int)"),
          "began 必须携带开局时刻与代次")
    check(policySource.contains("case succeeded(at: Date, generation: Int)"),
          "succeeded 必须携带落地时刻与代次")
    check(policySource.contains("case cleared"),
          "必须保留 cleared —— 清空恒回到 idle")
    check(policySource.contains("static let cooldown: TimeInterval = 900"),
          "★ 冷却窗口必须是具名常量，不许再在 refresh 里写 900 字面量")
    check(policySource.contains("static func accepts(generation: Int, latest: Int) -> Bool"),
          "代次采纳判定必须是独立可测的纯函数")
    check(policySource.contains("generation >= latest"),
          "采纳规则必须是 >=（相等即采纳），否则单次同步刷新会被自己拒绝")
    check(policySource.contains("static func isRefreshing(_ phase: RefreshPhase) -> Bool"),
          "isRefreshing 必须是独立可测的纯函数")
    check(policySource.contains("static func shouldSkip(phase: RefreshPhase, now: Date, force: Bool, hasEvents: Bool) -> Bool"),
          "shouldSkip 必须把「冷却窗口内」作为显式判据")
    check(policySource.contains("return now < until"),
          "★ 冷却窗口判定必须基于状态 until，而不是现算时间差")
    check(policySource.contains("static func reduce(_ phase: RefreshPhase, event: RefreshEvent, latestGeneration: Int) -> RefreshPhase"),
          "reduce 必须是独立可测的纯函数")

    guard let storeSource = productionSource("SeeingCalendar/ICS/CalendarEventStore.swift") else {
        check(false, "找不到 CalendarEventStore.swift")
        return
    }
    check(storeSource.contains("private(set) var phase: RefreshPhase = .idle"),
          "phase 必须是单一真值入口")
    check(storeSource.contains("var isRefreshing: Bool { phase.isRefreshing }"),
          "isRefreshing 必须降级为只读投影")
    check(storeSource.contains("var lastError: String? { phase.failureMessage }"),
          "lastError 必须降级为只读投影")
    check(storeSource.contains("until.addingTimeInterval(-RefreshPolicy.cooldown)"),
          "★ lastRefresh 必须从 coolingDown.until 反推为 until - cooldown")
    check(storeSource.contains("private var inflight: Task<RefreshOutcome, Never>?"),
          "必须有在途合并句柄")
    check(storeSource.contains("struct RefreshOutcome: Sendable"),
          "RefreshOutcome 必须是 Sendable 值类型（不得装 SwiftData 模型对象）")
    check(storeSource.contains("refreshGeneration &+= 1"),
          "每次开新一趟刷新必须推进代次")
    check(storeSource.contains("RefreshPolicy.accepts(generation: outcome.generation, latest: refreshGeneration)"),
          "★ 结果落地前必须过代次纪律 accepts")
    check(storeSource.contains("await inflight.value"),
          "在途合并必须等待既有那一趟的结论")
    check(storeSource.contains("private func emit(_ event: RefreshEvent)"),
          "必须存在唯一的刷新相位写入点")
    // 交叉护栏：本文件仍须满足 verify_subscription_management 的作用域断言。
    check(storeSource.contains("scope: subscription.workspaceUUIDs"),
          "订阅聚合必须把多选作用域放进快照（verify_subscription_management 亦钉此点）")
    check(storeSource.contains("scope: snapshot.scope"),
          "事件必须带上快照作用域（verify_subscription_management 亦钉此点）")

    // 负向护栏：旧形状不得回潮
    check(!storeSource.contains("private(set) var isRefreshing = false"),
          "★ 不得回退为 isRefreshing 存储旗标")
    guard let refreshBody = declarationBody(of: "func refresh(subscriptions: [ICSSubscription], force: Bool = false) async",
                                            in: storeSource) else {
        check(false, "无法定位 refresh(subscriptions:force:) 的函数体 —— 签名改了吗？")
        return
    }
    check(!refreshBody.contains("defer { isRefreshing"),
          "★ refresh 体内不得回退为 defer 熄火（这正是「提前熄火」的成因）")
    check(refreshBody.contains("emit(.began(startedAt: startedAt, generation: generation))"),
          "refresh 必须以携带代次的 began 开局")
}

// MARK: - 断言 1：相位 × 事件 × 代次 的穷举不变量

func verifyExhaustiveInvariants() {
    for phase in allPhases {
        for event in allEvents {
            for latest in allLatest {
                let next = Policy.reduce(phase, event: event, latestGeneration: latest)
                let label = "\(phase) × \(event) @latest=\(latest)"

                // 不变量 4：cleared 恒回到 idle。
                if case .cleared = event {
                    checkEqual(next, .idle, "\(label) 的 cleared 必须回到 idle")
                    check(!Policy.isRefreshing(next), "\(label) 的 cleared 之后不得仍为刷新中")
                }

                // 不变量 1：代次早于 latest 的事件原样返回旧相位。
                let rejected: Bool
                switch event {
                case .began(_, let g), .succeeded(_, let g), .failed(_, _, let g):
                    rejected = !Policy.accepts(generation: g, latest: latest)
                case .cleared:
                    rejected = false
                }
                if rejected {
                    checkEqual(next, phase, "\(label) 的迟到事件必须原样返回旧相位（不写、不清、不熄火）")
                }

                // 被采纳时各事件的落地形态。
                if Policy.accepts(generation: 1, latest: latest) {
                    switch event {
                    case .began:
                        checkEqual(next, .refreshing(startedAt: epoch, generation: 1),
                                   "\(label) 的采纳后必须落到 refreshing")
                    case .succeeded:
                        // 不变量 2：成功后进入冷却，窗口是状态。
                        checkEqual(next, .coolingDown(until: epoch.addingTimeInterval(Policy.cooldown), generation: 1),
                                   "\(label) 的采纳后必须落到 coolingDown(at + cooldown)")
                    case .failed:
                        checkEqual(next, .failed(message: "boom", generation: 1),
                                   "\(label) 的采纳后必须落到 failed")
                    case .cleared:
                        break
                    }
                }

                // isRefreshing 投影必须与相位形状一致。
                if case .refreshing = next {
                    check(Policy.isRefreshing(next), "\(label) refreshing 相位必须自称刷新中")
                } else {
                    check(!Policy.isRefreshing(next), "\(label) 非 refreshing 相位不得自称刷新中")
                }
            }
        }
    }

    // 不变量 3：代次相等必须采纳。
    check(Policy.accepts(generation: 3, latest: 3), "代次相等必须采纳（否则单次同步请求会被自己拒绝）")
    check(Policy.accepts(generation: 4, latest: 3), "更新的代次必须采纳")
    check(!Policy.accepts(generation: 2, latest: 3), "更旧的代次必须拒绝")
}

// MARK: - 断言 2：重叠刷新不得互相提前熄火 / 迟到覆盖

func verifyOverlapSequence() {
    var phase: Phase = .idle

    phase = Policy.reduce(phase, event: .began(startedAt: epoch, generation: 1), latestGeneration: 1)
    check(Policy.isRefreshing(phase), "第一趟应处于刷新中")

    let second = epoch.addingTimeInterval(10)
    phase = Policy.reduce(phase, event: .began(startedAt: second, generation: 2), latestGeneration: 2)
    checkEqual(phase, .refreshing(startedAt: second, generation: 2), "第二趟应推进代次")

    // 第一趟（陈旧的）先返回。
    phase = Policy.reduce(phase, event: .succeeded(at: epoch, generation: 1), latestGeneration: 2)
    checkEqual(phase, .refreshing(startedAt: second, generation: 2),
               "★ 迟到的第一趟结果不得改变相位 —— 旧实现在这里会提前熄火")
    check(Policy.isRefreshing(phase), "★ 第二趟仍在飞行时，界面必须继续显示刷新中")

    phase = Policy.reduce(phase, event: .failed(message: "stale", at: epoch, generation: 1), latestGeneration: 2)
    checkEqual(phase, .refreshing(startedAt: second, generation: 2), "★ 迟到的失败也不得覆盖相位")

    // 第二趟（最新的）落地。
    phase = Policy.reduce(phase, event: .succeeded(at: second, generation: 2), latestGeneration: 2)
    checkEqual(phase, .coolingDown(until: second.addingTimeInterval(Policy.cooldown), generation: 2),
               "最新的第二趟结果必须落地并进入冷却")
    check(!Policy.isRefreshing(phase), "落地后不得仍为刷新中")

    // 单趟失败必须落地。
    var single: Phase = .idle
    single = Policy.reduce(single, event: .began(startedAt: epoch, generation: 1), latestGeneration: 1)
    single = Policy.reduce(single, event: .failed(message: "net", at: epoch, generation: 1), latestGeneration: 1)
    checkEqual(single, .failed(message: "net", generation: 1), "单趟的失败必须落地")
}

// MARK: - 断言 3：cleared 恒回 idle

func verifyCleared() {
    for phase in allPhases {
        let next = Policy.reduce(phase, event: .cleared, latestGeneration: 999)
        checkEqual(next, .idle, "cleared 必须把 \(phase) 拉回 idle")
        check(!Policy.isRefreshing(next), "cleared 之后 \(phase) 不得仍为刷新中")
    }
}

// MARK: - 断言 4：冷却语义逐位等价于旧式时间谓词

func projectedLastRefresh(_ phase: Phase) -> Date? {
    if case .coolingDown(let until, _) = phase { return until.addingTimeInterval(-Policy.cooldown) }
    return nil
}

func legacyWouldSkip(lastRefresh: Date?, now: Date, force: Bool, hasEvents: Bool) -> Bool {
    if force { return false }
    guard let lastRefresh else { return false }
    return now.timeIntervalSince(lastRefresh) < Policy.cooldown && hasEvents
}

func verifyCooldownSemantics() {
    let t = epoch
    let cool = Policy.reduce(.idle, event: .succeeded(at: t, generation: 1), latestGeneration: 1)
    checkEqual(cool, .coolingDown(until: t.addingTimeInterval(Policy.cooldown), generation: 1),
               "成功后必须进入冷却态（窗口是状态）")

    check(Policy.shouldSkip(phase: cool, now: t.addingTimeInterval(899), force: false, hasEvents: true),
          "★ t+899 仍在冷却窗口内 → 跳过")
    check(!Policy.shouldSkip(phase: cool, now: t.addingTimeInterval(901), force: false, hasEvents: true),
          "★ t+901 已出冷却窗口 → 不跳过")
    check(!Policy.shouldSkip(phase: cool, now: t.addingTimeInterval(900), force: false, hasEvents: true),
          "t+900 端点即出窗口（半开区间，与旧的 < 同解）")
    check(!Policy.shouldSkip(phase: cool, now: t.addingTimeInterval(100), force: true, hasEvents: true),
          "★ force:true 恒不跳过")
    check(!Policy.shouldSkip(phase: cool, now: t.addingTimeInterval(100), force: false, hasEvents: false),
          "★ hasEvents:false 恒不跳过")

    for other in [Phase.idle, .refreshing(startedAt: t, generation: 1), .failed(message: "x", generation: 1)] {
        check(!Policy.shouldSkip(phase: other, now: t, force: false, hasEvents: true),
              "非冷却相位一律不跳过：\(other)")
    }

    // 逐位等价：与旧式 `!force && now.timeIntervalSince(lastRefresh) < 900 && !events.isEmpty`。
    for offset in [-7200, -1, 0, 899, 900, 901, 7200] {
        let now = t.addingTimeInterval(TimeInterval(offset))
        checkEqual(Policy.shouldSkip(phase: cool, now: now, force: false, hasEvents: true),
                   legacyWouldSkip(lastRefresh: projectedLastRefresh(cool), now: now, force: false, hasEvents: true),
                   "shouldSkip 必须逐位等价于旧式时间谓词 @\(offset)")
    }
    checkEqual(Policy.cooldown, 900, "冷却窗口必须仍是 900 秒")
}

// MARK: - 断言 5：反证 —— 破坏变体必须被抓到

func lateEventWouldDiverge(_ event: Event, latest: Int) -> Bool {
    switch event {
    case .began(_, let g), .succeeded(_, let g), .failed(_, _, let g):
        return g < latest
    case .cleared:
        return false
    }
}

func verifyBrokenVariantIsCaught() {
    var caught = false
    for phase in allPhases {
        for event in allEvents {
            for latest in allLatest where lateEventWouldDiverge(event, latest: latest) {
                let good = Policy.reduce(phase, event: event, latestGeneration: latest)
                let bad = BrokenPolicy.reduce(phase, event: event, latestGeneration: latest)
                caught = caught || (good != bad)
            }
        }
    }
    check(caught, "★ 忽略代次的破坏变体必须与正确实现产生不同结果（检查器不能退化成恒真）")

    let flying: Phase = .refreshing(startedAt: epoch, generation: 2)
    let good = Policy.reduce(flying, event: .succeeded(at: epoch, generation: 1), latestGeneration: 2)
    let bad = BrokenPolicy.reduce(flying, event: .succeeded(at: epoch, generation: 1), latestGeneration: 2)
    checkEqual(good, flying, "正确实现必须拒绝迟到响应（相位不被改写）")
    checkEqual(bad, .coolingDown(until: epoch.addingTimeInterval(Policy.cooldown), generation: 1),
               "破坏变体确实会把相位改成冷却 —— 反证有效")
    check(good != bad, "正反两实现必须在迟到响应上分歧")

    check(Policy.accepts(generation: 3, latest: 3), "边界上相等必须采纳")
    check(!(4 == 3) && Policy.accepts(generation: 4, latest: 3),
          "★ 严格相等变体会拒绝更新的代次 —— 必须与 >= 分歧，门禁据此识别回退")
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyOverlapSequence()
verifyCleared()
verifyCooldownSemantics()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 刷新相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
