#!/usr/bin/env swift
//
//  verify_pager_phase.swift
//  翻月相位机门禁（CI 以 --strict 执行）
//
//  钉三类「隐式状态机」悄悄退回成两个字段共同涌现的回退：
//
//  【落位纪律靠手抄】旧实现把「落位动画期间屏蔽新手势」在 `swipeGesture.onChanged`、
//    `.onEnded` 和 `settle(to:commit:)` 里各写了一遍 `guard !state.isSettling`。漏抄一处，
//    弹簧动画就会被新手势打断 → 月序错乱。本门禁从两个方向钉死它：
//    ① 文本护栏：`guard !state.isSettling` 在 MonthPager.swift 里不得再出现（断言 0）；
//    ② 语义护栏：`.settling × dragChanged / dragBegan / dragEnded` 相位必须原样不变（断言 1）。
//
//  【两条复位路径】`settle()` 与 `springBack()` 曾各改各的 `offset`，没有共同收敛点。
//    本门禁用穷举断言：未提交的松手必定回到 `.idle`，落位收尾也只从 `.settling` 回到 `.idle`。
//
//  【阻尼 / 方向判定被顺手改写】阻尼 0.45 与速度阈值 220、距离比例 0.13 曾内联在手势闭包里。
//    本门禁对 `dampedOffset` / `swipeDirection` 逐位重算（断言 2、3），并留下破坏变体反证
//    （断言 4）确保检查器不会退化成恒真。
//
//  运行：swift scripts/verify_pager_phase.swift [--strict]
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

enum Phase: Equatable {
    case idle
    case dragging(offset: CGFloat)
    case settling(offset: CGFloat)

    var offset: CGFloat {
        switch self {
        case .idle: return 0
        case .dragging(offset: let value), .settling(offset: let value): return value
        }
    }

    var isSettling: Bool {
        if case .settling = self { return true }
        return false
    }

    var acceptsGesture: Bool { !isSettling }
}

enum Event: Equatable {
    case dragBegan
    case dragChanged(offset: CGFloat)
    case dragEnded(committed: Bool)
    case settleFinished
}

enum Policy {
    static let swipeVelocityThreshold: CGFloat = 220
    static let swipeDistanceFraction: CGFloat = 0.13

    static func isSettling(_ phase: Phase) -> Bool {
        if case .settling = phase { return true }
        return false
    }

    static func reduce(_ phase: Phase, event: Event) -> Phase {
        switch event {
        case .dragBegan:
            return phase.acceptsGesture ? .dragging(offset: phase.offset) : phase

        case .dragChanged(offset: let offset):
            return phase.isSettling ? phase : .dragging(offset: offset)

        case .dragEnded(committed: let committed):
            if phase.isSettling { return phase }
            return committed ? .settling(offset: phase.offset) : .idle

        case .settleFinished:
            return phase.isSettling ? .idle : phase
        }
    }

    static func dampedOffset(translation: CGFloat, limit: CGFloat, overdamp: CGFloat) -> CGFloat {
        let magnitude = abs(translation)
        guard magnitude > limit else { return translation }
        let damped = limit + (magnitude - limit) * overdamp
        return translation > 0 ? damped : -damped
    }

    static func swipeDistanceThreshold(containerWidth: CGFloat,
                                       fraction: CGFloat = swipeDistanceFraction) -> CGFloat {
        containerWidth * fraction
    }

    static func swipeDirection(velocityX: CGFloat,
                               offset: CGFloat,
                               threshold: CGFloat,
                               velocityThreshold: CGFloat = swipeVelocityThreshold) -> Int {
        if velocityX > velocityThreshold { return -1 }
        if velocityX < -velocityThreshold { return 1 }
        if offset > threshold { return -1 }
        if offset < -threshold { return 1 }
        return 0
    }

    /// 落位动画期间对外可见的缩略图代次（nil = 未冻结）。
    static func updatedFrozenVersion(current frozen: Int?, isSettling: Bool, live: Int) -> Int? {
        guard isSettling else { return nil }
        return frozen ?? live
    }
}

/// 破坏变体：落位期间**仍接受拖动** —— 旧隐式状态机漏掉 guard 时就是这个形状。
enum BrokenPolicy {
    static func reduce(_ phase: Phase, event: Event) -> Phase {
        switch event {
        case .dragBegan:
            return .dragging(offset: phase.offset)
        case .dragChanged(offset: let offset):
            return .dragging(offset: offset)              // ★ 不管是否落位
        case .dragEnded(committed: let committed):
            return committed ? .settling(offset: phase.offset) : .idle
        case .settleFinished:
            return .idle
        }
    }

    /// 破坏变体：落位期间**不冻结**缩略图代次（= 旧行为）。
    static func updatedFrozenVersion(current frozen: Int?, isSettling: Bool, live: Int) -> Int? {
        nil
    }
}

/// 旧 `.onChanged` 的内联阻尼逻辑（逐位参考实现）。
func referenceDampedOffset(translation: CGFloat, limit: CGFloat, overdamp: CGFloat) -> CGFloat {
    let dx = translation
    if abs(dx) > limit {
        let over = abs(dx) - limit
        let damped = limit + over * overdamp
        return dx > 0 ? damped : -damped
    }
    return dx
}

/// 旧 `.onEnded` 的内联方向判定逻辑（逐位参考实现）。
func referenceSwipeDirection(velocityX: CGFloat,
                             offset: CGFloat,
                             threshold: CGFloat,
                             velocityThreshold: CGFloat) -> Int {
    if velocityX > velocityThreshold { return -1 }
    if velocityX < -velocityThreshold { return 1 }
    if offset > threshold { return -1 }
    if offset < -threshold { return 1 }
    return 0
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 剥掉 `//` 行注释与 `/* */` 块注释。
///
/// 计数类断言必须作用在剥注释后的源码上：本文件的说明注释里也会写 `.equatable()`
/// 这类字面量，直接对原文计数会把注释也算进去（第一次落地就踩了这个坑）。
func stripComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    let end = source.endIndex
    while index < end {
        let next = source.index(after: index)
        if source[index] == "/", next < end, source[next] == "/" {
            while index < end, source[index] != "\n" { index = source.index(after: index) }
        } else if source[index] == "/", next < end, source[next] == "*" {
            index = source.index(after: next)
            while index < end {
                let probe = source.index(after: index)
                if source[index] == "*", probe < end, source[probe] == "/" { index = source.index(after: probe); break }
                index = probe
            }
        } else {
            out.append(source[index])
            index = next
        }
    }
    return out
}

/// 统计子串出现次数（用于钉「唯一一处」这类结构不变量）。
func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = found.upperBound
    }
    return count
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

// MARK: - 穷举输入

private let allPhases: [Phase] = [
    .idle,
    .dragging(offset: 120),
    .dragging(offset: -120),
    .settling(offset: 300)
]

/// 与相位枚举一一对应的 4 个事件（`dragEnded` 取「未提交」这一支作为代表）。
private let allEvents: [Event] = [
    .dragBegan,
    .dragChanged(offset: 240),
    .dragEnded(committed: false),
    .settleFinished
]

private func isDragEvent(_ event: Event) -> Bool {
    switch event {
    case .dragBegan, .dragChanged, .dragEnded: return true
    case .settleFinished: return false
    }
}

// MARK: - 断言 0：与生产源码同源（文本护栏 + 负向护栏）

func verifySourceGuardrails() {
    let policyOptional = productionSource("SeeingCalendar/Views/PagerPhasePolicy.swift")
    check(policyOptional != nil, "找不到 PagerPhasePolicy.swift")
    let policy = policyOptional ?? ""

    // 相位与事件必须是纯值类型（不 import SwiftUI，才可被本门禁镜像穷举）。
    check(policy.contains("enum PagerPhase: Equatable, Sendable"),
          "PagerPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy.contains("case idle"), "PagerPhase 必须保留 .idle")
    check(policy.contains("case dragging(offset: CGFloat)"), "PagerPhase.dragging 必须携带偏移")
    check(policy.contains("case settling(offset: CGFloat)"), "PagerPhase.settling 必须携带偏移")
    check(policy.contains("enum PagerEvent: Equatable, Sendable"),
          "PagerEvent 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy.contains("case dragBegan"), "PagerEvent 必须保留 .dragBegan")
    check(policy.contains("case dragChanged(offset: CGFloat)"), "PagerEvent.dragChanged 必须携带偏移")
    check(policy.contains("case dragEnded(committed: Bool)"), "PagerEvent.dragEnded 必须携带提交判定")
    check(policy.contains("case settleFinished"), "PagerEvent 必须保留 .settleFinished")

    // ★ 真实编译抓出来的回归：case 模式里写 `case .dragChanged(offset: offset)` 少了 let，
    // Swift 会把 label 后面的标识符当**已存在的值**解析 → "cannot find in scope"。
    // 镜像实现式门禁天然抓不到「生产文件编译不过」，只能在此钉死文本形状。
    check(policy.contains("case .dragChanged(let offset):"),
          "★ 必须写成 let 绑定形式 case .dragChanged(let offset):")
    check(policy.contains("case .dragEnded(let committed):"),
          "★ 必须写成 let 绑定形式 case .dragEnded(let committed):")
    check(!policy.contains("case .dragChanged(offset: offset):"),
          "★ 不得回退为缺少 let 的简写标签模式（编译错误）")
    check(!policy.contains("case .dragEnded(committed: committed):"),
          "★ 不得回退为缺少 let 的简写标签模式（编译错误）")

    // 能力查询与转移函数必须是独立可测的纯入口。
    check(policy.contains("var acceptsGesture: Bool { !isSettling }"),
          "acceptsGesture 必须显式回答「能否接受新手势」，不得再靠读代码反推")
    check(policy.contains("static func reduce(_ phase: PagerPhase, event: PagerEvent) -> PagerPhase"),
          "相位转移必须是唯一收敛点 reduce")
    check(policy.contains("static func dampedOffset(translation: CGFloat, limit: CGFloat, overdamp: CGFloat) -> CGFloat"),
          "阻尼换算必须是独立可测的纯函数")
    check(policy.contains("static func swipeDirection(velocityX: CGFloat,"),
          "方向判定必须是独立可测的纯函数")
    check(policy.contains("static let swipeVelocityThreshold: CGFloat = 220"),
          "速度阈值必须是具名常量 220")
    check(policy.contains("static let swipeDistanceFraction: CGFloat = 0.13"),
          "距离比例必须是具名常量 0.13")

    // 三条不变量的实现形态必须留痕。
    check(policy.contains("return phase.isSettling ? phase : .dragging(offset: offset)"),
          "★ 落位期间 dragChanged 必须原样返回相位")
    check(policy.contains("return committed ? .settling(offset: phase.offset) : .idle"),
          "★ 未提交的松手必须收敛到 .idle")
    check(policy.contains("return phase.isSettling ? .idle : phase"),
          "★ settleFinished 只允许从 .settling 收敛到 .idle")
    check(policy.contains("if velocityX > velocityThreshold { return -1 }"),
          "速度方向判定必须是严格大于（阈值不触发）")

    let pagerOptional = productionSource("SeeingCalendar/Views/MonthPager.swift")
    check(pagerOptional != nil, "找不到 MonthPager.swift")
    let pager = pagerOptional ?? ""

    // 相位是单一真值，offset / isSettling 只读投影。
    check(pager.contains("private(set) var phase: PagerPhase = .idle"),
          "phase 必须是单一真值入口")
    check(pager.contains("var offset: CGFloat { phase.offset }"),
          "offset 必须降级为只读计算投影")
    check(pager.contains("var isSettling: Bool { phase.isSettling }"),
          "isSettling 必须降级为只读计算投影")

    // 三处手抄守卫收敛成显式的相位能力查询。
    check(pager.contains("guard state.phase.acceptsGesture else { return }"),
          "手势路径必须以 phase.acceptsGesture 作守卫")
    check(pager.contains("guard phase.acceptsGesture else { return }"),
          "settle 也必须以 phase.acceptsGesture 作守卫")
    check(pager.contains("PagerPolicy.dampedOffset(translation: dx, limit: containerWidth, overdamp: 0.45)"),
          "拖动阻尼必须委派给 PagerPolicy.dampedOffset")
    check(pager.contains("PagerPolicy.swipeDirection(velocityX: velocity,"),
          "松手方向必须委派给 PagerPolicy.swipeDirection")
    check(pager.contains("PagerPolicy.swipeDistanceThreshold(containerWidth: containerWidth)"),
          "距离阈值必须委派给 PagerPolicy.swipeDistanceThreshold")
    check(pager.contains("PagerPolicy.reduce(self.phase, event: .settleFinished)"),
          "settle 收尾必须走相位收敛点")
    check(pager.contains("PagerPolicy.reduce(phase, event: .dragEnded(committed: false))"),
          "springBack 必须走同一个相位收敛点")

    // 弹簧参数是性能/观感契约，不得被顺手改。
    check(pager.contains(".spring(response: 0.28, dampingFraction: 0.84)"),
          "settle 的弹簧参数不得改动")
    check(pager.contains(".spring(response: 0.26, dampingFraction: 0.86)"),
          "springBack 的弹簧参数不得改动")

    // 负向护栏：旧形状不得回潮。
    check(!pager.contains("guard !state.isSettling"),
          "★ `guard !state.isSettling` 不得再出现：落位纪律必须收敛到 phase.acceptsGesture")
    check(!pager.contains("var isSettling = false"),
          "不得回退为 isSettling 存储旗标")

    // 精确到 swipeGesture 的计算属性体：守卫必须走相位能力查询。
    if let swipeBody = declarationBody(of: "private var swipeGesture: some Gesture", in: pager) {
        check(!swipeBody.contains("guard !state.isSettling"),
              "★ swipeGesture 体内不得再手抄 `guard !state.isSettling`")
        check(swipeBody.contains("state.phase.acceptsGesture"),
              "swipeGesture 必须改用显式的相位能力查询")
    } else {
        check(false, "无法定位 swipeGesture 的计算属性体 —— 声明串改了吗？")
    }

    verifyContentTreeIsolation()
}

// MARK: - 内容树冻结（位移帧里 126 格必须零重算）

/// 钉住「翻月位移是一次容器变换」这个结构，而不是「每格各自有动效」。
///
/// 用户实测症状：滑动时每一格看起来各自动。成因是 `MonthPager.body` 每帧重算时
/// 会把三页网格与三个选中环**重新构造**（各自在 init 里算 42 个网格日期），
/// 而挂在每页 `.overlay` 里的环不受外层 `.equatable()` 保护、逐帧重求值；
/// 于是任何让等值判定翻转的输入（缩略图代次是唯一会自己变的那个）都会
/// **在落位弹簧的动画事务内**重建 126 格 —— 那就是「每格各自动」。
///
/// 本组断言把这个结构冻住：内容树与环层各自独立成 `Equatable` 类型、各自只构造一次，
/// 位移只剩文件里唯一的一处 `.offset(`。
func verifyContentTreeIsolation() {
    guard let pager = productionSource("SeeingCalendar/Views/MonthPager.swift") else {
        check(false, "找不到 MonthPager.swift")
        return
    }
    // 计数一律作用在剥注释后的源码上：本文件的说明注释里也写了这些字面量。
    let pagerCode = stripComments(pager)
    check(pager.contains("struct MonthPagerGrids: View, Equatable"),
          "★ 三页网格必须封成独立的 Equatable 内容树 MonthPagerGrids")
    check(pager.contains("struct MonthSelectionRingLayer: View, Equatable"),
          "★ 选中环必须独立成层 MonthSelectionRingLayer（否则内容树被迫比较 selectedDate）")

    // 唯一的位移：整份文件只允许一处 `.offset(`。
    checkEqual(countOccurrences(of: ".offset(", in: pagerCode), 1,
               "★ MonthPager.swift 只允许一处 .offset( —— 翻月位移必须是唯一的容器变换")
    check(pager.contains(".offset(x: -containerWidth + state.offset)"),
          "翻月位移必须由 state.offset 驱动")

    // 恰好两处短路：内容树 + 环层。
    // 三处短路，缺一不可：
    //   ① MonthPager.body 里的内容树 MonthPagerGrids
    //   ② MonthPager.body 里的选中环层 MonthSelectionRingLayer
    //   ③ MonthPagerGrids.page(delta:) 里的 MonthGridView（每页一格，源码里只写一处）
    checkEqual(countOccurrences(of: ".equatable()", in: pagerCode), 3,
               "★ 短路点必须恰好三处：内容树 + 环层 + 每页网格")
    checkEqual(countOccurrences(of: "MonthPagerGrids(", in: pagerCode), 1,
               "内容树只能构造一次")
    checkEqual(countOccurrences(of: "MonthSelectionRingLayer(", in: pagerCode), 1,
               "环层只能构造一次")

    // 落位边界冻结缩略图代次。
    check(pager.contains(".onChange(of: state.isSettling)"),
          "落位边界必须触发缩略图代次的冻结/解冻")
    check(pager.contains("PagerPolicy.updatedFrozenVersion(current: frozenThumbnailVersion,"),
          "冻结决策必须委派给 PagerPolicy.updatedFrozenVersion")
    check(pager.contains("frozenThumbnailVersion ?? thumbnailVersion"),
          "内容树必须使用冻结后的代次")

    // 等值判定的分工：内容树不比 selectedDate，环层必须比。
    if let gridsEq = declarationBody(of: "nonisolated static func == (lhs: MonthPagerGrids", in: pager) {
        check(!gridsEq.contains("selectedDate"),
              "★ MonthPagerGrids.== 不得比较 selectedDate，否则点选日期会击穿短路引发 126 格全量重算")
        check(gridsEq.contains("lhs.thumbnailVersion == rhs.thumbnailVersion"),
              "内容树必须比较缩略图代次，否则缩略图变化跨不过短路")
    } else {
        check(false, "无法定位 MonthPagerGrids.== —— 声明串改了吗？")
    }
    if let ringEq = declarationBody(of: "nonisolated static func == (lhs: MonthSelectionRingLayer", in: pager) {
        check(ringEq.contains("lhs.selectedDate == rhs.selectedDate"),
              "★ MonthSelectionRingLayer.== 必须比较 selectedDate，否则点选时选中环不更新")
        check(ringEq.contains("lhs.month == rhs.month"),
              "环层必须比较 month（翻月后环要跟着新页走）")
    } else {
        check(false, "无法定位 MonthSelectionRingLayer.== —— 声明串改了吗？")
    }

    // 内容树不得读取翻月偏移 —— 位移只能由外层容器施加。
    if let gridsStruct = declarationBody(of: "struct MonthPagerGrids: View, Equatable", in: pager) {
        check(!gridsStruct.contains("state.offset"),
              "★ 内容树不得读取翻月偏移 —— 否则位移又回到内容重算路径上")
    } else {
        check(false, "无法定位 struct MonthPagerGrids —— 声明串改了吗？")
    }

    // 负向护栏：旧形状不得回潮。
    check(!pager.contains("private func page(offset delta: Int)"),
          "★ 不得回退为在 MonthPager.body 里每帧构造 MonthGridView 的旧形状")
    check(!pager.contains(".overlay(alignment: .top) {"),
          "★ 选中环不得回退为挂在每页 .overlay（那里的内容不受 .equatable() 保护，会逐帧重求值）")
}

// MARK: - 冻结语义不变量

func verifyThumbnailVersionFreeze() {
    // 不变量 ①：非落位一律解冻。
    checkEqual(Policy.updatedFrozenVersion(current: 7, isSettling: false, live: 9), nil,
               "非落位必须解冻（采用实时代次）")
    checkEqual(Policy.updatedFrozenVersion(current: nil, isSettling: false, live: 9), nil,
               "非落位必须解冻（即使从未冻结过）")

    // 不变量 ②：落位且已冻结 → 原样保留，动画中途绝不改写。
    checkEqual(Policy.updatedFrozenVersion(current: 7, isSettling: true, live: 9), 7,
               "★ 落位期间已冻结的代次必须原样保留 —— 改写就会击穿内容树短路")
    checkEqual(Policy.updatedFrozenVersion(current: 0, isSettling: true, live: 42), 0,
               "★ 冻结值 0 也是有效值，不得被当成「未冻结」")

    // 不变量 ③：落位且未冻结 → 以当时实时值冻结。
    checkEqual(Policy.updatedFrozenVersion(current: nil, isSettling: true, live: 9), 9,
               "落位起始必须冻结当时的实时代次")

    // 重放：动画途中缩略图落地，可见代次必须纹丝不动。
    let atRest = Policy.updatedFrozenVersion(current: nil, isSettling: false, live: 3)
    checkEqual(atRest ?? 3, 3, "静止时可见代次 = 实时代次")
    let atSettleStart = Policy.updatedFrozenVersion(current: atRest, isSettling: true, live: 3)
    let duringAnimation = Policy.updatedFrozenVersion(current: atSettleStart, isSettling: true, live: 4)
    checkEqual(duringAnimation ?? 4, 3,
               "★ 动画途中代次推进不得改变可见代次（126 格必须零重算）")
    let afterSettle = Policy.updatedFrozenVersion(current: duringAnimation, isSettling: false, live: 4)
    checkEqual(afterSettle ?? 4, 4, "落位结束后必须解冻并追上最新代次")

    // 破坏变体反证：不冻结的实现会让 126 格在动画事务内重建。
    let brokenDuring = BrokenPolicy.updatedFrozenVersion(current: atSettleStart, isSettling: true, live: 4)
    check(brokenDuring != duringAnimation,
          "★ 不冻结的破坏变体必须在「动画途中推进代次」上与正确实现分歧")
    checkEqual(brokenDuring, nil, "破坏变体确实解冻了 —— 反证有效")
    check((brokenDuring ?? 4) != (duringAnimation ?? 4),
          "★ 两实现在动画途中必须给出不同的可见代次，否则检查器恒真")
}

// MARK: - 断言 1：相位 × 事件穷举不变量

func verifyExhaustiveInvariants() {
    var settlingBlocksDrags = 0
    var springBackConverged = 0
    var settleFinishedConverged = 0

    for phase in allPhases {
        for event in allEvents {
            let next = Policy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"

            // 不变量 1：落位期间任何拖动事件都不得改变相位。
            if phase.isSettling, isDragEvent(event) {
                checkEqual(next, phase, "\(label) 落位期间的拖动事件必须原样返回相位")
                check(next.isSettling, "\(label) 落位期间不得退出落位")
                settlingBlocksDrags += 1
            }

            // 不变量 2：对手势可接受相位，未提交的松手必定收敛到 .idle。
            if case .dragEnded(committed: let committed) = event, !committed, phase.acceptsGesture {
                checkEqual(next, .idle, "\(label) 未提交的松手必须回到 idle")
                checkEqual(next.offset, 0, "\(label) 回到 idle 后 offset 必须归零")
                springBackConverged += 1
            }

            // 不变量 3：落位收尾只从 .settling 回到 .idle，对其它相位是 no-op。
            if case .settleFinished = event {
                if phase.isSettling {
                    checkEqual(next, .idle, "\(label) 落位收尾必须回到 idle")
                    settleFinishedConverged += 1
                } else {
                    checkEqual(next, phase, "\(label) 非落位相位的 settleFinished 必须是 no-op")
                }
            }

            // 附加：idle 投影偏移恒为 0；不得出现「落位中却仍可接受手势」的非法态。
            if case .idle = next {
                checkEqual(next.offset, 0, "\(label) idle 的 offset 必须为 0")
            }
            check(!(next.isSettling && next.acceptsGesture),
                  "\(label) 非法态：落位中却仍自称可接受手势")
        }
    }

    // 覆盖度自检：防止循环被写空而恒真。
    checkEqual(settlingBlocksDrags, 3, "落位屏蔽拖动必须被覆盖 3 次（dragBegan / dragChanged / dragEnded）")
    checkEqual(springBackConverged, 3, "未提交松手的收敛必须覆盖 idle 与两种 dragging")
    checkEqual(settleFinishedConverged, 1, "落位收尾必须被覆盖 1 次")

    // 落位期间 dragEnded(committed: true) 也必须被屏蔽（穷举表里用的是未提交这一支）。
    checkEqual(Policy.reduce(.settling(offset: 300), event: .dragEnded(committed: true)),
               .settling(offset: 300),
               "★ 落位期间即便是「已提交」的松手也必须被屏蔽")
    checkEqual(Policy.reduce(.settling(offset: -300), event: .dragChanged(offset: 240)),
               .settling(offset: -300),
               "★ 落位期间的拖动不得把相位改成 dragging")
}

// MARK: - 断言 2：阻尼逐位等价

func verifyDampedOffsetEquivalence() {
    let limit: CGFloat = 800
    let cases: [CGFloat] = [-2000, -1200, -800, -400, -50, 0, 50, 400, 800, 1200, 2000]
    for translation in cases {
        let expected = referenceDampedOffset(translation: translation, limit: limit, overdamp: 0.45)
        checkEqual(Policy.dampedOffset(translation: translation, limit: limit, overdamp: 0.45),
                   expected,
                   "dampedOffset(\(translation)) 必须与旧内联逻辑逐位一致")
    }

    // 不超界：原样透传（含边界上「恰好等于 limit」—— 严格大于才阻尼）。
    checkEqual(Policy.dampedOffset(translation: 400, limit: limit, overdamp: 0.45), 400,
               "未超界必须原样透传")
    checkEqual(Policy.dampedOffset(translation: 800, limit: limit, overdamp: 0.45), 800,
               "恰好等于 limit 必须原样透传（严格大于才阻尼）")
    checkEqual(Policy.dampedOffset(translation: 0, limit: limit, overdamp: 0.45), 0,
               "零位移必须透传 0")

    // 超界：按 0.45 阻尼并按符号还原。
    checkEqual(Policy.dampedOffset(translation: 1200, limit: limit, overdamp: 0.45),
               limit + 400 * 0.45,
               "超界 400 必须按 0.45 阻尼")
    checkEqual(Policy.dampedOffset(translation: -1200, limit: limit, overdamp: 0.45),
               -(limit + 400 * 0.45),
               "负数超界必须按符号还原")
}

// MARK: - 断言 3：方向判定逐位等价

func verifySwipeDirectionEquivalence() {
    let threshold: CGFloat = 800 * 0.13   // 104
    let velocityThreshold: CGFloat = 220

    // 速度分支优先。
    checkEqual(Policy.swipeDirection(velocityX: 300, offset: 0, threshold: threshold), -1,
               "向右快速滑必须是上一月")
    checkEqual(Policy.swipeDirection(velocityX: -300, offset: 0, threshold: threshold), 1,
               "向左快速滑必须是下一月")

    // 速度恰好等于阈值：严格大于 / 小于不成立 → 落到位移判定。
    checkEqual(Policy.swipeDirection(velocityX: 220, offset: 0, threshold: threshold), 0,
               "速度恰为 220 不得触发速度分支")
    checkEqual(Policy.swipeDirection(velocityX: -220, offset: 0, threshold: threshold), 0,
               "速度恰为 -220 不得触发速度分支")
    checkEqual(Policy.swipeDirection(velocityX: 220, offset: 200, threshold: threshold), -1,
               "速度仅到阈值时应改看位移")
    checkEqual(Policy.swipeDirection(velocityX: -220, offset: -200, threshold: threshold), 1,
               "速度仅到 -220 时应改看位移")

    // 速度不足 → 位移分支。
    checkEqual(Policy.swipeDirection(velocityX: 0, offset: 200, threshold: threshold), -1,
               "位移超过正阈值 → 上一月")
    checkEqual(Policy.swipeDirection(velocityX: 0, offset: -200, threshold: threshold), 1,
               "位移低于负阈值 → 下一月")
    checkEqual(Policy.swipeDirection(velocityX: 0, offset: threshold, threshold: threshold), 0,
               "位移恰好等于阈值不得触发（严格大于）")
    checkEqual(Policy.swipeDirection(velocityX: 0, offset: -threshold, threshold: threshold), 0,
               "位移恰好等于负阈值不得触发")
    checkEqual(Policy.swipeDirection(velocityX: 0, offset: 0, threshold: threshold), 0,
               "速度与位移皆不足 → 0")

    // 与手写参考实现逐位一致（覆盖速度阈值内外 × 位移阈值内外）。
    for velocity in [CGFloat(-500), -220, -100, 0, 100, 220, 500] {
        for offset in [CGFloat(-200), -104, -50, 0, 50, 104, 200] {
            checkEqual(Policy.swipeDirection(velocityX: velocity, offset: offset, threshold: threshold),
                       referenceSwipeDirection(velocityX: velocity, offset: offset,
                                               threshold: threshold, velocityThreshold: velocityThreshold),
                       "swipeDirection(v=\(velocity), o=\(offset)) 必须与旧内联逻辑逐位一致")
        }
    }

    // 参数化默认值必须等于原字面量，且省略实参等价于显式传入默认值。
    checkEqual(Policy.swipeVelocityThreshold, 220, "速度阈值默认值必须是原字面量 220")
    checkEqual(Policy.swipeDistanceFraction, 0.13, "距离比例默认值必须是原字面量 0.13")
    checkEqual(Policy.swipeDirection(velocityX: 300, offset: 0, threshold: threshold),
               Policy.swipeDirection(velocityX: 300, offset: 0, threshold: threshold,
                                     velocityThreshold: Policy.swipeVelocityThreshold),
               "省略速度阈值时必须与显式传入默认值一致")
    checkEqual(Policy.swipeDistanceThreshold(containerWidth: 800),
               800 * Policy.swipeDistanceFraction,
               "距离阈值换算必须等于宽度乘以比例")
}

// MARK: - 断言 4：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    var caught = false
    for phase in allPhases {
        for event in allEvents {
            let good = Policy.reduce(phase, event: event)
            let bad = BrokenPolicy.reduce(phase, event: event)
            if phase.isSettling, isDragEvent(event) {
                caught = caught || (good != bad)
            }
        }
    }
    check(caught, "★ 「落位期间仍接受拖动」的破坏变体必须与正确实现分歧（检查器不得退化成恒真）")

    let settling: Phase = .settling(offset: 300)
    let good = Policy.reduce(settling, event: .dragChanged(offset: -240))
    let bad = BrokenPolicy.reduce(settling, event: .dragChanged(offset: -240))
    checkEqual(good, settling, "正确实现必须屏蔽落位期间的拖动")
    checkEqual(bad, .dragging(offset: -240), "破坏变体确实会在落位期间接受拖动 —— 反证有效")
    check(good != bad, "正反两实现必须在「落位期间拖动」上分歧")

    // 检查器不得退化成恒真：正确的 reduce 必须真的会改变相位。
    check(Policy.reduce(.idle, event: .dragChanged(offset: 50)) != .idle,
          "正确的 reduce 必须会把 idle 推进到 dragging（否则检查器恒真）")
    check(Policy.reduce(.dragging(offset: 50), event: .dragEnded(committed: true)) != .dragging(offset: 50),
          "正确的 reduce 必须会把 dragging 推进到 settling")
}

// MARK: - 运行

verifySourceGuardrails()
verifyThumbnailVersionFreeze()
verifyExhaustiveInvariants()
verifyDampedOffsetEquivalence()
verifySwipeDirectionEquivalence()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 翻月相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
