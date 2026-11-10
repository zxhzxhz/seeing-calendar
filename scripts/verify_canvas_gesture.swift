#!/usr/bin/env swift
//
//  verify_canvas_gesture.swift
//  画布手势相位机门禁（CI 以 --strict 执行）
//
//  钉三类用户实测报回来的回退：
//
//  【下拉返回握手退化成单个 bool】旧实现用 `pullDownEngaged: Bool` 同时编码
//     「已在画纸之外向下起手」与「已判定提交 onRequestDismiss」。一个 bool 只有两极：
//     提交前被 .cancelled 复位后，「正在判定」与「根本没起手」不可区分；反之
//     「已提交」这个中间态也观测不到、无法穷举。且阈值 90 / 700 是内联魔数。
//     本门禁把它显式成 `idle → armed → committed` 三态相位机，并用「相位 × 事件」
//     穷举 + 9 组阈值边界逐位等价钉死。
//
//  【原生菜单冷却退回挂钟时间】旧实现拿 `menuActionGuardUntil: Date` 当状态：
//     挂钟时间不是状态（`Date()` 抖一下、主线程卡顿一下就变行为），且公开可写、
//     语义靠约定、不可穷举。现改为触摸生命周期驱动的 `open / coasting` 相位机，
//     冷却窗口 = 恰好一次点击。本门禁用穷举 + 破坏变体反证钉死。
//
//  【hitTest 里查询 UIEvent.allTouches】已知陷阱：初次落笔常常取不到该触摸，
//     据此分流会导致「关闭手指开关后完全无法套索」。本门禁用文本护栏钉死
//     两台画布文件里 `allTouches` 出现次数必须为 0。
//
//  运行：swift scripts/verify_canvas_gesture.swift [--strict]
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

enum PullPhase: Equatable {
    case idle
    case armed
    case committed

    var isEngaged: Bool {
        switch self {
        case .idle: return false
        case .armed, .committed: return true
        }
    }
}

enum PullEvent: Equatable {
    case shouldBeginAccepted
    case shouldBeginRejected
    case ended(translationY: CGFloat, velocityY: CGFloat)
    case cancelled
}

enum PullPolicy {
    static let distanceThreshold: CGFloat = 90
    static let velocityThreshold: CGFloat = 700

    static func commits(translationY: CGFloat,
                        velocityY: CGFloat,
                        distance: CGFloat = distanceThreshold,
                        velocity: CGFloat = velocityThreshold) -> Bool {
        translationY > distance || velocityY > velocity
    }

    static func reduce(_ phase: PullPhase, event: PullEvent) -> PullPhase {
        switch event {
        case .shouldBeginAccepted:
            return .armed
        case .shouldBeginRejected:
            return .idle
        case .ended(let translationY, let velocityY):
            guard phase.isEngaged else { return phase }
            return commits(translationY: translationY, velocityY: velocityY) ? .committed : .idle
        case .cancelled:
            return .idle
        }
    }
}

/// 破坏变体：阈值用 `>=`（原严格 `>` 的常见误改）。
enum BrokenThresholdPullPolicy {
    static func commits(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        translationY >= PullPolicy.distanceThreshold || velocityY >= PullPolicy.velocityThreshold
    }

    static func reduce(_ phase: PullPhase, event: PullEvent) -> PullPhase {
        switch event {
        case .shouldBeginAccepted: return .armed
        case .shouldBeginRejected: return .idle
        case .ended(let translationY, let velocityY):
            guard phase.isEngaged else { return phase }
            return commits(translationY: translationY, velocityY: velocityY) ? .committed : .idle
        case .cancelled: return .idle
        }
    }
}

enum GuardPhase: Equatable {
    case open
    case coasting

    var blocksCanvasTap: Bool { self == .coasting }
}

enum GuardEvent: Equatable {
    case menuActionSelected
    case tapReceived
    case reset
}

enum GuardPolicy {
    static func reduce(_ phase: GuardPhase, event: GuardEvent) -> GuardPhase {
        switch event {
        case .menuActionSelected: return .coasting
        case .tapReceived: return .open
        case .reset: return .open
        }
    }
}

/// 破坏变体：`coasting` 永不退出 —— 即「旧的时间戳窗口永不到期」。
enum BrokenGuardPolicy {
    static func reduce(_ phase: GuardPhase, event: GuardEvent) -> GuardPhase {
        switch event {
        case .menuActionSelected: return .coasting
        case .tapReceived: return phase   // ★ 错过消费点，永远吐不回去
        case .reset: return .open
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

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    // ---- 纯逻辑相位机文件 ----
    let policy = productionSource("SeeingCalendar/Canvas/CanvasGesturePolicy.swift") ?? ""
    check(policy.contains("enum PullDownPhase: Equatable, Sendable"),
          "PullDownPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy.contains("case idle"), "PullDownPhase 必须保留 .idle")
    check(policy.contains("case armed"), "PullDownPhase 必须保留 .armed（已起手中间态）")
    check(policy.contains("case committed"), "PullDownPhase 必须保留 .committed（已提交中间态）")
    check(policy.contains("var isEngaged: Bool"), "pullDownEngaged 投影必须走 isEngaged")
    check(policy.contains("enum PullDownEvent: Equatable, Sendable"),
          "PullDownEvent 必须仍是 Equatable + Sendable")
    check(policy.contains("case shouldBeginAccepted"), "必须保留 shouldBeginAccepted 事件")
    check(policy.contains("case shouldBeginRejected"), "必须保留 shouldBeginRejected 事件")
    check(policy.contains("case ended(translationY: CGFloat, velocityY: CGFloat)"),
          "ended 必须携带位移与速度（提交判定的输入）")
    check(policy.contains("case cancelled"), "必须保留 cancelled 事件")
    check(policy.contains("static let distanceThreshold: CGFloat = 90"),
          "位移阈值必须具名化为 90，不许再内联")
    check(policy.contains("static let velocityThreshold: CGFloat = 700"),
          "速度阈值必须具名化为 700，不许再内联")
    check(policy.contains("static func commits(translationY: CGFloat,"),
          "提交判定必须是独立可测的纯函数")
    check(policy.contains("translationY > distance || velocityY > velocity"),
          "提交判定必须严格大于（与旧内联判定逐位等价）")
    check(policy.contains("static func reduce(_ phase: PullDownPhase, event: PullDownEvent) -> PullDownPhase"),
          "必须存在下拉返回相位的转移函数")
    check(policy.contains("enum MenuGuardPhase: Equatable, Sendable"),
          "MenuGuardPhase 必须仍是 Equatable + Sendable")
    check(policy.contains("case open"), "MenuGuardPhase 必须保留 .open")
    check(policy.contains("case coasting"), "MenuGuardPhase 必须保留 .coasting")
    check(policy.contains("var blocksCanvasTap: Bool { self == .coasting }"),
          "blocksCanvasTap 必须严格等价于 .coasting")
    check(policy.contains("enum MenuGuardEvent: Equatable, Sendable"),
          "MenuGuardEvent 必须仍是 Equatable + Sendable")
    check(policy.contains("case menuActionSelected"), "必须保留 menuActionSelected 事件")
    check(policy.contains("case tapReceived"), "必须保留 tapReceived 事件")
    check(policy.contains("case reset"), "必须保留 reset 事件")
    check(policy.contains("static func reduce(_ phase: MenuGuardPhase, event: MenuGuardEvent) -> MenuGuardPhase"),
          "必须存在菜单冷却相位的转移函数")

    // ---- 宿主视图（M17 写入点）----
    let host = productionSource("SeeingCalendar/Canvas/CanvasHostView.swift") ?? ""
    check(host.contains("private(set) var pullDownPhase: PullDownPhase = .idle"),
          "pullDownPhase 必须是单一真值入口")
    check(host.contains("var pullDownEngaged: Bool { pullDownPhase.isEngaged }"),
          "pullDownEngaged 必须降级为只读计算投影")
    check(host.contains("private func emitPullDown(_ event: PullDownEvent)"),
          "必须存在唯一的下拉返回相位写入点")
    check(host.contains("pullDownPhase = PullDownPolicy.reduce(pullDownPhase, event: event)"),
          "唯一写入点必须走 PullDownPolicy.reduce")
    check(host.contains("emitPullDown(.shouldBeginAccepted)"),
          "shouldBegin 通过必须改走相位事件")
    check(host.contains("emitPullDown(.shouldBeginRejected)"),
          "shouldBegin 否决必须改走相位事件")
    check(host.contains("emitPullDown(.ended(translationY: translation.y, velocityY: velocity.y))"),
          "松手必须携带位移与速度喂给相位机")
    check(host.contains("emitPullDown(.cancelled)"),
          "取消 / 失败必须改走相位事件")
    check(host.contains("if pullDownPhase == .committed {"),
          "提交出口必须读相位机而非旧 bool")

    // 负向护栏：旧形状不得回潮
    check(!host.contains("private var pullDownEngaged = false"),
          "★ 不得回退为 `private var pullDownEngaged = false` 存储旗标")
    check(!host.contains("translation.y > 90") && !host.contains("velocity.y > 700"),
          "★ 宿主视图不得再出现内联阈值 90 / 700")

    // ---- 复合画布容器（M18 写入点 + 读点）----
    let container = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") ?? ""
    check(container.contains("private(set) var menuGuardPhase: MenuGuardPhase = .open"),
          "menuGuardPhase 必须是单一真值入口")
    check(container.contains("menuGuardPhase == .coasting ? .distantFuture : .distantPast"),
          "兼容只读投影 menuActionGuardUntil 必须由相位推导")
    check(container.contains("func noteMenuActionSelected() {"),
          "必须存在菜单选中动作的相位写入点")
    check(container.contains("menuGuardPhase = MenuGuardPolicy.reduce(menuGuardPhase, event: .menuActionSelected)"),
          "菜单选中动作必须改走相位事件")
    check(container.contains("if menuGuardPhase.blocksCanvasTap {"),
          "handleContainerTap 必须先读相位")
    check(container.contains("menuGuardPhase = MenuGuardPolicy.reduce(menuGuardPhase, event: .tapReceived)"),
          "handleContainerTap 必须发送 tapReceived 事件（消费一次透传）")

    check(!container.contains("var menuActionGuardUntil: Date = .distantPast"),
          "★ 不得回退为 `var menuActionGuardUntil: Date = .distantPast` 存储属性（时间戳当状态）")

    if let body = declarationBody(of: "func handleContainerTap(_ gesture: UITapGestureRecognizer)", in: container) {
        check(!body.contains("Date() < menuActionGuardUntil"),
              "★ handleContainerTap 体内不得再出现 `Date() < menuActionGuardUntil`（挂钟时间当状态）")
        check(body.contains("menuGuardPhase.blocksCanvasTap"),
              "handleContainerTap 必须读相位 blocksCanvasTap")
        check(body.contains("MenuGuardPolicy.reduce(menuGuardPhase, event: .tapReceived)"),
              "handleContainerTap 必须发送 tapReceived 事件")
    } else {
        check(false, "无法定位 handleContainerTap 的函数体 —— 签名改了吗？")
    }

    // ---- 选区扩展（M18 另一处写点）----
    let selection = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift") ?? ""
    check(selection.contains("noteMenuActionSelected()"),
          "perform(_:) 必须改走相位事件，而不是直接写时间戳")
    check(!selection.contains("menuActionGuardUntil = Date()"),
          "★ 不得再直接给 menuActionGuardUntil 赋时间戳")

    // ---- 已知陷阱护栏：hitTest 里查询 allTouches ----
    let hostAll = host.components(separatedBy: "allTouches").count - 1
    let containerAll = container.components(separatedBy: "allTouches").count - 1
    checkEqual(hostAll, 0, "★ CanvasHostView 不得出现 allTouches（hitTest 阶段不可靠）")
    checkEqual(containerAll, 0, "★ CompositeCanvasContainerView 不得出现 allTouches（hitTest 阶段不可靠）")
}

// MARK: - 断言 1：相位 × 事件的穷举不变量

private let allPullPhases: [PullPhase] = [.idle, .armed, .committed]
private let allPullEvents: [PullEvent] = [
    .shouldBeginAccepted,
    .shouldBeginRejected,
    .ended(translationY: 500, velocityY: 0),
    .cancelled
]
private let allGuardPhases: [GuardPhase] = [.open, .coasting]
private let allGuardEvents: [GuardEvent] = [.menuActionSelected, .tapReceived, .reset]

func verifyExhaustiveInvariants() {
    // (3 × 4) 下拉返回组合
    for phase in allPullPhases {
        for event in allPullEvents {
            let next = PullPolicy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"

            // 相位不会无故“跳级”：只有 shouldBeginAccepted 能进入 armed。
            if case .shouldBeginAccepted = event {
                checkEqual(next, .armed, "\(label)：通过起手必须落到 armed")
            }
            if case .shouldBeginRejected = event {
                checkEqual(next, .idle, "\(label)：否决必须回到 idle")
            }

            // ★ .committed 不是终态：ended 之后必回 .idle 或 .committed，绝不滞留在 armed。
            if case .ended = event {
                check(next == .idle || next == .committed,
                      "\(label)：ended 之后必须回 idle 或 committed，不得停在 armed")
            }

            // 只有「已起手」才有资格判定提交。
            if case .ended = event, !phase.isEngaged {
                checkEqual(next, phase, "\(label)：未起手时 ended 必须原样返回")
            }
        }
    }

    // .committed 可以离开（不是终态）
    checkEqual(PullPolicy.reduce(.committed, event: .cancelled), .idle, ".committed 收到 cancelled 必须回 idle")
    checkEqual(PullPolicy.reduce(.committed, event: .shouldBeginRejected), .idle,
               ".committed 收到 shouldBeginRejected 必须回 idle")
    checkEqual(PullPolicy.reduce(.committed, event: .ended(translationY: 0, velocityY: 0)), .idle,
               ".committed 再次 ended 且未达阈值必须回 idle")

    // .idle 收到 cancelled 仍是 .idle
    checkEqual(PullPolicy.reduce(.idle, event: .cancelled), .idle, ".idle 收到 cancelled 必须仍是 .idle")

    // isEngaged 投影一致性
    for phase in allPullPhases {
        checkEqual(phase.isEngaged, phase == .armed || phase == .committed,
                   "isEngaged 必须恰好是 armed/committed")
    }

    // (2 × 3) 菜单冷却组合
    for phase in allGuardPhases {
        for event in allGuardEvents {
            let next = GuardPolicy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"
            checkEqual(next.blocksCanvasTap, next == .coasting, "\(label)：blocksCanvasTap 必须等价于 coasting")

            if case .tapReceived = event {
                checkEqual(next, .open, "\(label)：tapReceived 之后必须回到 open")
                check(!next.blocksCanvasTap, "\(label)：tapReceived 之后不得再屏蔽画布点击")
            }
            if case .reset = event {
                checkEqual(next, .open, "\(label)：reset 之后必须回到 open")
            }
        }
    }

    // ★ coasting 收到 tapReceived 必须回 open；open 收到 tapReceived 不改变相位
    checkEqual(GuardPolicy.reduce(.coasting, event: .tapReceived), .open,
               "★ coasting 收到 tapReceived 必须回到 open（消费掉一次透传）")
    check(!GuardPolicy.reduce(.coasting, event: .tapReceived).blocksCanvasTap,
          "★ 消费透传之后不得再屏蔽画布点击")
    checkEqual(GuardPolicy.reduce(.open, event: .tapReceived), .open,
               "open 收到 tapReceived 必须原样保持 open")
    checkEqual(GuardPolicy.reduce(.open, event: .menuActionSelected), .coasting,
               "open 收到 menuActionSelected 必须进入 coasting")
}

// MARK: - 断言 2：提交阈值逐位等价

func verifyCommitThreshold() {
    // 旧内联判定：translation.y > 90 || velocity.y > 700（严格大于）
    let distances: [CGFloat] = [89, 90, 91]
    let velocities: [CGFloat] = [699, 700, 701]
    for d in distances {
        for v in velocities {
            let expected = (d > 90) || (v > 700)
            checkEqual(PullPolicy.commits(translationY: d, velocityY: v), expected,
                       "commits(d=\(d), v=\(v)) 必须与手写期望 \(expected) 逐位一致")
        }
    }

    check(!PullPolicy.commits(translationY: 90, velocityY: 700), "恰好 90 / 700 均不得提交（严格大于）")
    check(PullPolicy.commits(translationY: 90.5, velocityY: 0), "位移略过阈值即应提交")
    check(PullPolicy.commits(translationY: 0, velocityY: 700.5), "速度略过阈值即应提交")
    checkEqual(PullPolicy.distanceThreshold, 90, "位移阈值必须是 90")
    checkEqual(PullPolicy.velocityThreshold, 700, "速度阈值必须是 700")

    // phased reduce 在 armed 下的落地必须与 commits 一致
    for d in distances {
        for v in velocities {
            let next = PullPolicy.reduce(.armed, event: .ended(translationY: d, velocityY: v))
            checkEqual(next, PullPolicy.commits(translationY: d, velocityY: v) ? .committed : .idle,
                       "armed × ended(d=\(d), v=\(v)) 的落地必须与 commits 一致")
        }
    }
}

// MARK: - 断言 3：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    // ① coasting 永不退出
    var guardDivergence = 0
    for phase in allGuardPhases {
        for event in allGuardEvents {
            let good = GuardPolicy.reduce(phase, event: event)
            let bad = BrokenGuardPolicy.reduce(phase, event: event)
            if good != bad { guardDivergence += 1 }
        }
    }
    check(guardDivergence > 0,
          "★「coasting 永不退出」的破坏变体必须与正确实现分歧（检查器不得退化成恒真）")

    let goodTap = GuardPolicy.reduce(.coasting, event: .tapReceived)
    let badTap = BrokenGuardPolicy.reduce(.coasting, event: .tapReceived)
    checkEqual(goodTap, .open, "正确实现：coasting × tapReceived → open")
    checkEqual(badTap, .coasting, "破坏变体：coasting × tapReceived 仍滞留在 coasting")
    check(goodTap != badTap, "★ 正反两实现必须在「消费一次透传」上分歧")

    // ② 阈值误用 >=
    var thresholdDivergence = 0
    for d in [CGFloat(89), 90, 91] {
        for v in [CGFloat(699), 700, 701] {
            let good = PullPolicy.reduce(.armed, event: .ended(translationY: d, velocityY: v))
            let bad = BrokenThresholdPullPolicy.reduce(.armed, event: .ended(translationY: d, velocityY: v))
            if good != bad { thresholdDivergence += 1 }
        }
    }
    check(thresholdDivergence > 0, "★「>= 阈值」的破坏变体必须在边界上与正确实现分歧")

    let goodEdge = PullPolicy.reduce(.armed, event: .ended(translationY: 90, velocityY: 0))
    let badEdge = BrokenThresholdPullPolicy.reduce(.armed, event: .ended(translationY: 90, velocityY: 0))
    checkEqual(goodEdge, .idle, "正确实现：恰好 90 不提交")
    checkEqual(badEdge, .committed, "破坏变体：恰好 90 误判为提交")
    check(goodEdge != badEdge, "★ 正反两实现必须在 90 边界上分歧")

    // 门禁不得恒真：至少要有大量真实断言
    check(checks > 40, "断言数量必须足够大（实际 \(checks) 条），否则等于没查")
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyCommitThreshold()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 画布手势相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
