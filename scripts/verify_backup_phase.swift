#!/usr/bin/env swift
//
//  verify_backup_phase.swift
//  M8「备份 / 恢复生命周期」相位机门禁（CI 以 --strict 执行）
//
//  钉三类「隐式状态机退回成多个字段共同涌现」的回退：
//
//  【失败与成功并存】旧实现用 `lastError` + `lastSummary` 两个平行字段描述终态，
//    二者可以同时非 nil（指纹告警接着恢复成功、或成功后又失败）。`BackupView` 的两个
//    `if let` 分支于是会同时命中，`RootView` 的分支也会漂移。本门禁用**穷举不变量**
//    钉死它：`.failed` / `.finished` 是互斥终态，`failureMessage` 与 `summary`
//    永不同时非 nil（断言 1），并用破坏变体反证检查器不是恒真（断言 5）。
//
//  【状态文案与忙碌位脱钩 / 等待用户被存两份】旧实现里 `statusText` 与 `isWorking`
//    是两个字段描述一个相位（能构造出「正在整理数据…」配 `isWorking == false`），
//    而「是否在等待用户选择策略」被 `pendingRestore != nil` 与
//    `RootView.showRestoreDialog` 同时持有。本门禁从两个方向钉死：
//    ① 文本护栏：生产源码里不得再有那批存储声明与 `showRestoreDialog`（断言 0）；
//    ② 语义护栏：`isWorking` / `acceptsNewRequest` 的真值表逐位锁定（断言 1、2）。
//
//  【进度残值】旧实现 `progress` 是 0…1 浮点，空闲时可能停在上一次的 1.0。
//    本门禁断言非进度相位下 `progress` 恒为 0，并逐位验证 `clampedProgress`
//    单调不降且落在 0…1（断言 3）。
//
//  运行：swift scripts/verify_backup_phase.swift [--strict]
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

// MARK: - 被测逻辑（生产代码 BackupPhasePolicy.swift 的镜像）

/// 镜像 RestoreMode（`fullOverwrite` / `smartMerge`）。
enum Strategy: Equatable {
    case fullOverwrite
    case smartMerge
}

/// 镜像 RestoreSummary。
struct Summary: Equatable {
    var mode: Strategy = .smartMerge
    var workspaces = 0
    var days = 0
    var pages = 0
    var images = 0
    var subscriptions = 0
}

/// 镜像 RestoreBundle（门禁只关心「载荷是否被相位携带」，不关心内容）。
struct Bundle: Equatable {
    var tag: Int
}

enum Phase: Equatable {
    case idle
    case exporting(progress: Double)
    case validating
    case awaitingStrategy(pending: Bundle, choice: Strategy, warning: String?)
    case restoring(progress: Double)
    case finished(message: String, summary: Summary)
    case failed(message: String)

    var isWorking: Bool { Policy.isWorking(self) }
    var progress: Double { Policy.progress(self) }
    var statusText: String { Policy.statusText(self) }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var summary: Summary? {
        if case .finished(_, let summary) = self { return summary }
        return nil
    }

    var isAwaitingStrategy: Bool { Policy.isAwaitingStrategy(self) }

    var pendingRestore: Bundle? {
        if case .awaitingStrategy(let pending, _, _) = self { return pending }
        return nil
    }

    var warningMessage: String? {
        if case .awaitingStrategy(_, _, let warning) = self { return warning }
        return nil
    }

    /// 兼容投影：失败信息或完整性告警。
    var lastError: String? { failureMessage ?? warningMessage }
}

enum Event: Equatable {
    case exportBegan
    case exportProgressed(Double)
    case exportSucceeded(message: String, summary: Summary)
    case importBegan
    case importParsed(Bundle, Strategy, warning: String?)
    case strategyChosen(Strategy)
    case restoreBegan
    case restoreProgressed(Double)
    case restoreSucceeded(message: String, summary: Summary)
    case failed(message: String)
    case dismissed
}

enum Policy {
    static func isWorking(_ phase: Phase) -> Bool {
        switch phase {
        case .exporting, .validating, .restoring: return true
        case .idle, .awaitingStrategy, .finished, .failed: return false
        }
    }

    static func isAwaitingStrategy(_ phase: Phase) -> Bool {
        if case .awaitingStrategy = phase { return true }
        return false
    }

    static func progress(_ phase: Phase) -> Double {
        switch phase {
        case .exporting(let value), .restoring(let value): return value
        case .idle, .validating, .awaitingStrategy, .finished, .failed: return 0
        }
    }

    static func statusText(_ phase: Phase) -> String {
        switch phase {
        case .idle: return ""
        case .exporting: return "正在打包 .vcal 归档…"
        case .validating: return "正在校验归档…"
        case .awaitingStrategy: return "归档校验通过"
        case .restoring: return "正在恢复数据…"
        case .finished(let message, _): return message
        case .failed: return "操作失败"
        }
    }

    static func acceptsNewRequest(_ phase: Phase) -> Bool {
        switch phase {
        case .idle, .finished, .failed: return true
        case .exporting, .validating, .awaitingStrategy, .restoring: return false
        }
    }

    static func clampedProgress(_ value: Double, current: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return max(current, clamped)
    }

    static func reduce(_ phase: Phase, event: Event) -> Phase {
        switch event {
        case .exportBegan:
            return acceptsNewRequest(phase) ? .exporting(progress: 0) : phase

        case .exportProgressed(let value):
            if case .exporting(let current) = phase {
                return .exporting(progress: clampedProgress(value, current: current))
            }
            return phase

        case .exportSucceeded(let message, let summary):
            if case .exporting = phase {
                return .finished(message: message, summary: summary)
            }
            return phase

        case .importBegan:
            return acceptsNewRequest(phase) ? .validating : phase

        case .importParsed(let pending, let choice, let warning):
            if case .validating = phase {
                return .awaitingStrategy(pending: pending, choice: choice, warning: warning)
            }
            return phase

        case .strategyChosen(let choice):
            if case .awaitingStrategy(let pending, _, let warning) = phase {
                return .awaitingStrategy(pending: pending, choice: choice, warning: warning)
            }
            return phase

        case .restoreBegan:
            if case .awaitingStrategy = phase {
                return .restoring(progress: 0)
            }
            return phase

        case .restoreProgressed(let value):
            if case .restoring(let current) = phase {
                return .restoring(progress: clampedProgress(value, current: current))
            }
            return phase

        case .restoreSucceeded(let message, let summary):
            if case .restoring = phase {
                return .finished(message: message, summary: summary)
            }
            return phase

        case .failed(let message):
            return .failed(message: message)

        case .dismissed:
            return .idle
        }
    }
}

// MARK: - 破坏变体：旧形状（失败 / 成功各自平行持有，互不清空）

/// 旧实现的行为形状：`lastError` / `lastSummary` 是两个各自独立、互不清空的字段。
struct BrokenState: Equatable {
    var isWorking = false
    var progress = 0.0
    var statusText = ""
    var lastError: String?
    var lastSummary: Summary?
    var pendingRestore: Bundle?
}

enum BrokenBackupPolicy {
    static func reduce(_ state: BrokenState, event: Event) -> BrokenState {
        var s = state
        switch event {
        case .exportBegan:
            guard !s.isWorking else { return s }
            s.isWorking = true
            s.progress = 0
            s.statusText = "正在打包 .vcal 归档…"
            s.lastError = nil
            return s

        case .exportProgressed(let value):
            s.progress = value
            return s

        case .exportSucceeded(let message, let summary):
            s.isWorking = false
            s.progress = 1
            s.statusText = message
            s.lastSummary = summary          // ★ 旧形状：成功不清 lastError
            return s

        case .importBegan:
            guard !s.isWorking else { return s }
            s.isWorking = true
            s.statusText = "正在校验归档…"
            s.lastError = nil
            return s

        case .importParsed(let bundle, _, let warning):
            s.isWorking = false
            s.pendingRestore = bundle
            s.statusText = "归档校验通过"
            if let warning { s.lastError = warning }   // ★ 告警与待恢复并存
            return s

        case .strategyChosen:
            return s

        case .restoreBegan:
            s.isWorking = true
            return s

        case .restoreProgressed(let value):
            s.progress = value
            return s

        case .restoreSucceeded(let message, let summary):
            s.isWorking = false
            s.pendingRestore = nil
            s.statusText = message
            s.lastSummary = summary           // ★ 关键旧形状：不清 lastError
            return s

        case .failed(let message):
            s.isWorking = false
            s.lastError = message
            s.statusText = "操作失败"          // ★ 不清 lastSummary
            return s

        case .dismissed:
            s.lastError = nil
            s.lastSummary = nil
            s.pendingRestore = nil
            return s
        }
    }
}

/// 把正确相位翻译成破坏变体的初始状态（用于序列级反证）。
func brokenFrom(_ phase: Phase) -> BrokenState {
    var state = BrokenState()
    state.isWorking = phase.isWorking
    state.progress = phase.progress
    state.statusText = phase.statusText
    state.lastError = phase.failureMessage
    state.lastSummary = phase.summary
    state.pendingRestore = phase.pendingRestore
    return state
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

// MARK: - 穷举输入

private let sampleStrategy: Strategy = .smartMerge
private let sampleSummary = Summary()

/// 8 个相位（`awaitingStrategy` / `exporting` 各含带载荷变体，覆盖载荷分支）。
private let allPhases: [Phase] = [
    .idle,
    .exporting(progress: 0.42),
    .validating,
    .awaitingStrategy(pending: Bundle(tag: 7), choice: .smartMerge, warning: nil),
    .awaitingStrategy(pending: Bundle(tag: 7), choice: .smartMerge, warning: "warn"),
    .restoring(progress: 0.5),
    .finished(message: "ok", summary: Summary()),
    .failed(message: "boom")
]

/// 11 个事件。
private let allEvents: [Event] = [
    .exportBegan,
    .exportProgressed(0.5),
    .exportSucceeded(message: "ok", summary: sampleSummary),
    .importBegan,
    .importParsed(Bundle(tag: 1), .smartMerge, warning: nil),
    .strategyChosen(.fullOverwrite),
    .restoreBegan,
    .restoreProgressed(0.5),
    .restoreSucceeded(message: "ok", summary: sampleSummary),
    .failed(message: "boom"),
    .dismissed
]

private func isProgressPhase(_ phase: Phase) -> Bool {
    switch phase {
    case .exporting, .restoring: return true
    case .idle, .validating, .awaitingStrategy, .finished, .failed: return false
    }
}

/// 「忙碌」相位：严格等价于旧 `isWorking`（导出 / 校验 / 恢复）。
private func isBusyPhase(_ phase: Phase) -> Bool {
    switch phase {
    case .exporting, .validating, .restoring: return true
    case .idle, .awaitingStrategy, .finished, .failed: return false
    }
}

private func isTerminal(_ phase: Phase) -> Bool {
    switch phase {
    case .finished, .failed: return true
    case .idle, .exporting, .validating, .awaitingStrategy, .restoring: return false
    }
}

// MARK: - 断言 0：与生产源码同源（文本护栏 + 负向护栏）

func verifySourceGuardrails() {
    let policy = productionSource("SeeingCalendar/Store/BackupPhasePolicy.swift")
    check(policy != nil, "找不到 BackupPhasePolicy.swift")
    check(policy?.contains("enum BackupPhase: Equatable, Sendable") == true,
          "BackupPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy?.contains("case exporting(progress: Double)") == true,
          "exporting 必须携带进度")
    check(policy?.contains("case validating") == true, "必须保留 validating")
    check(policy?.contains("case awaitingStrategy(pending: RestoreBundle, choice: RestoreStrategyChoice, warning: String?)") == true,
          "★ awaitingStrategy 必须携带待恢复内容 —— pendingRestore 与 isAwaitingStrategy 都由它派生")
    check(policy?.contains("case restoring(progress: Double)") == true, "restoring 必须携带进度")
    check(policy?.contains("case finished(message: String, summary: RestoreSummary)") == true,
          "★ finished 是终态且携带摘要")
    check(policy?.contains("case failed(message: String)") == true,
          "★ failed 是终态，且**只**携带信息（保证与 finished 互斥）")
    check(policy?.contains("typealias RestoreStrategyChoice = RestoreMode") == true,
          "★ 恢复策略必须复用生产枚举 RestoreMode，不得另造同形枚举")
    check(policy?.contains("enum BackupEvent: Equatable, Sendable") == true,
          "BackupEvent 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy?.contains("static func isWorking(_ phase: BackupPhase) -> Bool") == true,
          "isWorking 必须是独立可测的纯函数")
    check(policy?.contains("case .exporting, .validating, .restoring: return true") == true,
          "忙碌集合必须恰是 exporting / validating / restoring")
    check(policy?.contains("case .idle, .awaitingStrategy, .finished, .failed: return false") == true,
          "★ awaitingStrategy 不算忙碌（旧实现里该相位 defer 已执行）")
    check(policy?.contains("static func acceptsNewRequest(_ phase: BackupPhase) -> Bool") == true,
          "acceptsNewRequest 必须是独立可测的纯函数")
    check(policy?.contains("case .idle, .finished, .failed: return true") == true,
          "★ 接纳新请求的恰好是 idle / finished / failed")
    check(policy?.contains("static func clampedProgress(_ value: Double, current: Double) -> Double") == true,
          "clampedProgress 必须是独立可测的纯函数")
    check(policy?.contains("let clamped = min(max(value, 0), 1)") == true,
          "进度必须夹在 0…1")
    check(policy?.contains("return max(current, clamped)") == true,
          "★ 进度必须单调不降（防回调乱序倒退）")
    check(policy?.contains("static func reduce(_ phase: BackupPhase, event: BackupEvent) -> BackupPhase") == true,
          "相位转移必须是唯一收敛点 reduce")

    let service = productionSource("SeeingCalendar/Store/BackupService.swift")
    check(service != nil, "找不到 BackupService.swift")
    check(service?.contains("private(set) var phase: BackupPhase = .idle") == true,
          "phase 必须是单一一真值入口")
    check(service?.contains("var isWorking: Bool { phase.isWorking }") == true,
          "isWorking 必须降级为只读投影")
    check(service?.contains("var progress: Double { phase.progress }") == true,
          "progress 必须降级为只读投影")
    check(service?.contains("var statusText: String { phase.statusText }") == true,
          "statusText 必须降级为只读投影")
    check(service?.contains("var lastError: String? { phase.failureMessage ?? phase.warningMessage }") == true,
          "lastError 必须降级为只读投影")
    check(service?.contains("var lastSummary: RestoreSummary? { phase.summary }") == true,
          "lastSummary 必须降级为只读投影")
    check(service?.contains("var pendingRestore: RestoreBundle? { phase.pendingRestore }") == true,
          "pendingRestore 必须降级为只读投影")
    check(service?.contains("var isAwaitingStrategy: Bool { phase.isAwaitingStrategy }") == true,
          "isAwaitingStrategy 必须显式暴露给视图层")
    check(service?.contains("private func emit(_ event: BackupEvent)") == true,
          "必须存在唯一的相位写入点 emit")
    check(service?.contains("phase = BackupPolicy.reduce(phase, event: event)") == true,
          "emit 必须委派给 BackupPolicy.reduce")
    check(service?.contains("guard BackupPolicy.acceptsNewRequest(phase) else { return nil }") == true,
          "★ writeArchive 入口的重入守卫必须走类型化判据")
    check(service?.contains("guard BackupPolicy.acceptsNewRequest(phase) else { return false }") == true,
          "★ prepareRestore 入口的重入守卫必须走类型化判据")

    // 负向护栏：旧形状不得回潮。
    check(service?.contains("private(set) var isWorking = false") != true,
          "★ 不得回退为 isWorking 存储旗标")
    check(service?.contains("private(set) var progress: Double = 0") != true,
          "★ 不得回退为 progress 存储字段")
    check(service?.contains("private(set) var statusText = \"\"") != true,
          "★ 不得回退为 statusText 存储字段")
    check(service?.contains("private(set) var lastError: String?") != true,
          "★ 不得回退为 lastError 存储字段")
    check(service?.contains("private(set) var lastSummary: RestoreSummary?") != true,
          "★ 不得回退为 lastSummary 存储字段")
    check(service?.contains("private(set) var pendingRestore: RestoreBundle?") != true,
          "★ 不得回退为 pendingRestore 存储字段")

    let root = productionSource("SeeingCalendar/Views/RootView.swift")
    check(root != nil, "找不到 RootView.swift")
    check(root?.contains("backup.isAwaitingStrategy") == true,
          "★ 恢复弹窗必须直接读 backup.isAwaitingStrategy（消除第 6 个持有者）")
    check(root?.contains("@State private var showRestoreDialog = false") != true,
          "★ showRestoreDialog 存储必须删除 —— 同一事实不得有两个持有者")
    check(root?.contains("showRestoreDialog") != true,
          "★ 不得再出现 showRestoreDialog（连注释也不留）")
}

// MARK: - 断言 1：相位 × 事件穷举不变量

func verifyExhaustiveInvariants() {
    var terminalPairs = 0
    var distinctSkips = 0

    for phase in allPhases {
        for event in allEvents {
            let next = Policy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"

            // 不变量 1：终态互斥 —— 失败信息与成功摘要永不同时非 nil。
            check(!(next.failureMessage != nil && next.summary != nil),
                  "\(label) 非法态：failureMessage 与 summary 同时非 nil")
            check(!(next.lastError != nil && next.summary != nil),
                  "\(label) 非法态：lastError 与 summary 同时非 nil")

            // 不变量 2：isWorking 与相位形状逐位一致。
            checkEqual(Policy.isWorking(next), isBusyPhase(next),
                       "\(label) isWorking 必须恰为 exporting / validating / restoring")

            // 不变量 3：acceptsNewRequest 恰为 idle / finished / failed。
            let accepts = next == .idle || isTerminal(next)
            checkEqual(Policy.acceptsNewRequest(next), accepts,
                       "\(label) acceptsNewRequest 必须恰为 idle / finished / failed")
            // 单向蕴含：接纳新请求的相位一律不忙碌（awaitingStrategy 不忙碌却也不接纳，故不是双向）。
            check(!Policy.acceptsNewRequest(next) || !Policy.isWorking(next),
                  "\(label) acceptsNewRequest 为真时必须不忙碌")

            // 不变量 4 + 进度无残值。
            if isProgressPhase(next) {
                check(next.progress >= 0 && next.progress <= 1,
                      "\(label) 进度必须落在 0…1")
            } else {
                checkEqual(next.progress, 0, "\(label) 非进度相位的 progress 必须为 0（无残值）")
            }

            // 终态形状。
            if isTerminal(next) {
                terminalPairs += 1
                if case .finished = next {
                    check(next.failureMessage == nil, "\(label) finished 不得携带失败信息")
                    check(next.summary != nil, "\(label) finished 必须携带摘要")
                }
                if case .failed = next {
                    check(next.failureMessage != nil, "\(label) failed 必须携带信息")
                    check(next.summary == nil, "\(label) failed 不得携带摘要")
                }
            }

            // 不变量 5：dismissed 恒回 idle。
            if case .dismissed = event {
                checkEqual(next, .idle, "\(label) dismissed 必须回到 idle")
                check(next.failureMessage == nil && next.summary == nil,
                      "\(label) dismissed 之后失败信息与摘要必须清空")
            }

            // 不变量 6：importParsed 落到 awaitingStrategy 并携带载荷。
            if case .importParsed(let pending, let choice, let warning) = event {
                if phase == .validating {
                    checkEqual(next, .awaitingStrategy(pending: pending, choice: choice, warning: warning),
                               "\(label) importParsed 必须进入 awaitingStrategy 并携带原载荷")
                    checkEqual(next.pendingRestore, pending, "\(label) pendingRestore 必须由载荷派生")
                    check(next.isAwaitingStrategy, "\(label) importParsed 之后必须自称等待策略")
                } else {
                    checkEqual(next, phase, "\(label) 非 validating 相位的 importParsed 必须是 no-op")
                }
            }

            // awaitingStrategy 的载荷投影。
            if case .awaitingStrategy = next {
                check(next.pendingRestore != nil, "\(label) awaitingStrategy 必须能取到待恢复内容")
                check(next.isAwaitingStrategy, "\(label) awaitingStrategy 必须自称等待策略")
            } else {
                check(!next.isAwaitingStrategy, "\(label) 非 awaitingStrategy 不得自称等待策略")
                check(next.pendingRestore == nil, "\(label) 非 awaitingStrategy 不得残留待恢复内容")
            }
        }
    }

    // 覆盖度自检：循环不得被写空（否则门禁退化成恒真）。
    check(terminalPairs > 0, "穷举必须至少命中若干终态（否则循环被写空）")
    checkEqual(allPhases.count, 8, "穷举相位表必须覆盖 8 个相位")
    checkEqual(allEvents.count, 11, "穷举事件表必须覆盖 11 个事件")

    // 明确记录多次被跳过的相位分支，避免「distinctSkips」被优化掉。
    distinctSkips += allPhases.filter { !Policy.acceptsNewRequest($0) }.count
    checkEqual(distinctSkips, 5, "不接受新请求的代表相位必须恰有 5 个（exporting / validating / 两种 awaiting / restoring）")
}

// MARK: - 断言 2：isWorking / acceptsNewRequest 真值表逐位等价

func verifyProjectionTruthTables() {
    // isWorking：严格等价于旧实现（导出 / 校验 / 恢复为真）。
    check(!Policy.isWorking(.idle), "idle 不忙碌")
    check(Policy.isWorking(.exporting(progress: 0.3)), "exporting 忙碌")
    check(Policy.isWorking(.validating), "validating 忙碌")
    check(!Policy.isWorking(.awaitingStrategy(pending: Bundle(tag: 1), choice: sampleStrategy, warning: nil)),
          "★ awaitingStrategy 不忙碌 —— 旧实现里该相位 defer 已执行，用户能操作")
    check(Policy.isWorking(.restoring(progress: 0.3)), "restoring 忙碌")
    check(!Policy.isWorking(.finished(message: "ok", summary: sampleSummary)), "finished 不忙碌")
    check(!Policy.isWorking(.failed(message: "boom")), "failed 不忙碌")

    // acceptsNewRequest：恰为 idle / finished / failed。
    check(Policy.acceptsNewRequest(.idle), "idle 接受新请求")
    check(!Policy.acceptsNewRequest(.exporting(progress: 0.3)), "exporting 拒绝新请求")
    check(!Policy.acceptsNewRequest(.validating), "validating 拒绝新请求")
    check(!Policy.acceptsNewRequest(.awaitingStrategy(pending: Bundle(tag: 1), choice: sampleStrategy, warning: nil)),
          "awaitingStrategy 拒绝新请求（用户正在做选择）")
    check(!Policy.acceptsNewRequest(.restoring(progress: 0.3)), "restoring 拒绝新请求")
    check(Policy.acceptsNewRequest(.finished(message: "ok", summary: sampleSummary)), "finished 接受新请求")
    check(Policy.acceptsNewRequest(.failed(message: "boom")), "failed 接受新请求")

    // 状态文案投影逐位对齐旧赋值点。
    checkEqual(Policy.statusText(.idle), "", "idle 状态文案为空")
    checkEqual(Policy.statusText(.exporting(progress: 0.3)), "正在打包 .vcal 归档…", "exporting 文案")
    checkEqual(Policy.statusText(.validating), "正在校验归档…", "validating 文案")
    checkEqual(Policy.statusText(.awaitingStrategy(pending: Bundle(tag: 1), choice: sampleStrategy, warning: nil)),
               "归档校验通过", "awaitingStrategy 文案")
    checkEqual(Policy.statusText(.finished(message: "备份完成（12 KB）", summary: sampleSummary)),
               "备份完成（12 KB）", "finished 文案必须走落地消息")
    checkEqual(Policy.statusText(.failed(message: "boom")), "操作失败", "failed 文案为稳定标签")
}

// MARK: - 断言 3：clampedProgress 单调且落在 0…1

func verifyClampedProgress() {
    checkEqual(Policy.clampedProgress(2.0, current: 0.1), 1.0, "越上界的进度必须被夹到 1")
    checkEqual(Policy.clampedProgress(-1.0, current: 0.1), 0.1, "越下界不得低于当前值")
    checkEqual(Policy.clampedProgress(-1.0, current: 0.0), 0.0, "越下界且当前为 0 时结果为 0")
    checkEqual(Policy.clampedProgress(0.3, current: 0.8), 0.8, "★ 乱序（倒退）输入必须保持当前值")
    checkEqual(Policy.clampedProgress(0.9, current: 0.8), 0.9, "前向进度必须采纳")
    checkEqual(Policy.clampedProgress(0.0, current: 0.0), 0.0, "零到零")
    checkEqual(Policy.clampedProgress(1.0, current: 1.0), 1.0, "到顶后保持 1")

    // 单调性：任意两个越界 / 乱序输入，结果永不倒退且恒在 0…1。
    for raw in [-5.0, -0.1, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 9.0] {
        var current = 0.0
        let stepped = Policy.clampedProgress(raw, current: current)
        check(stepped >= current, "clampedProgress(\(raw)) 不得低于当前值")
        check(stepped >= 0 && stepped <= 1, "clampedProgress(\(raw)) 必须落在 0…1")
        current = stepped
    }

    // 相位内进度只增不减：连续回调乱序也不倒退。
    var phase: Phase = .idle
    phase = Policy.reduce(phase, event: .exportBegan)
    phase = Policy.reduce(phase, event: .exportProgressed(0.6))
    phase = Policy.reduce(phase, event: .exportProgressed(0.2))
    checkEqual(phase.progress, 0.6, "★ 乱序回到较小值必须被挡下（进度不倒退）")
    phase = Policy.reduce(phase, event: .exportProgressed(1.2))
    checkEqual(phase.progress, 1.0, "越界回调必须被夹到 1")
}

// MARK: - 断言 4：完整重放序列

func verifyReplaySequences() {
    // 导出：began → 0.15 → 1.0 → 成功 → 关闭 → idle。
    var p: Phase = .idle
    p = Policy.reduce(p, event: .exportBegan)
    checkEqual(p, .exporting(progress: 0), "导出开局必须落在 exporting(0)")
    check(p.isWorking, "导出中必须忙碌")
    p = Policy.reduce(p, event: .exportProgressed(0.15))
    checkEqual(p, .exporting(progress: 0.15), "导出进度 0.15 必须落地")
    p = Policy.reduce(p, event: .exportProgressed(1.0))
    checkEqual(p, .exporting(progress: 1.0), "导出进度 1.0 必须落地")
    p = Policy.reduce(p, event: .exportSucceeded(message: "备份完成", summary: sampleSummary))
    checkEqual(p, .finished(message: "备份完成", summary: sampleSummary), "导出成功必须落到 finished")
    check(!p.isWorking && p.failureMessage == nil, "成功终态必须不忙碌且无失败信息")
    check(Policy.acceptsNewRequest(p), "成功终态必须接受新请求")
    p = Policy.reduce(p, event: .dismissed)
    checkEqual(p, .idle, "关闭后必须回到 idle")
    check(p.summary == nil && p.failureMessage == nil, "回到 idle 必须清空摘要与失败信息")

    // 恢复：导入 → 解析 → 等待策略 → 选策略 → 开始恢复 → 进度 → 成功 → 关闭。
    var r: Phase = .idle
    r = Policy.reduce(r, event: .importBegan)
    checkEqual(r, .validating, "导入开局必须落在 validating")
    r = Policy.reduce(r, event: .importParsed(Bundle(tag: 3), .smartMerge, warning: nil))
    checkEqual(r, .awaitingStrategy(pending: Bundle(tag: 3), choice: .smartMerge, warning: nil),
               "解析完成必须落到 awaitingStrategy 并携带载荷")
    check(r.isAwaitingStrategy && !r.isWorking, "★ 等待策略期间必须不忙碌（用户能操作）")
    checkEqual(r.pendingRestore, Bundle(tag: 3), "待恢复内容必须可读")
    r = Policy.reduce(r, event: .strategyChosen(.fullOverwrite))
    checkEqual(r, .awaitingStrategy(pending: Bundle(tag: 3), choice: .fullOverwrite, warning: nil),
               "选定策略必须改写 choice 且保持等待态")
    r = Policy.reduce(r, event: .restoreBegan)
    checkEqual(r, .restoring(progress: 0), "开始恢复必须落在 restoring(0)")
    r = Policy.reduce(r, event: .restoreProgressed(0.5))
    checkEqual(r, .restoring(progress: 0.5), "恢复进度必须落地")
    r = Policy.reduce(r, event: .restoreSucceeded(message: "合并完成", summary: sampleSummary))
    checkEqual(r, .finished(message: "合并完成", summary: sampleSummary), "恢复成功必须落到 finished")
    check(r.pendingRestore == nil, "成功后不得残留待恢复内容")
    r = Policy.reduce(r, event: .dismissed)
    checkEqual(r, .idle, "恢复关闭后必须回到 idle")

    // 指纹告警：与待恢复并存，但绝不与终态串味。
    let warned = Policy.reduce(.validating,
                               event: .importParsed(Bundle(tag: 9), .smartMerge, warning: "指纹不一致"))
    checkEqual(warned.warningMessage, "指纹不一致", "告警必须可从相位读出")
    check(warned.summary == nil, "告警态不得携带摘要")
    checkEqual(warned.failureMessage, nil, "告警不是失败终态")
}

// MARK: - 断言 5：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    // 正确实现：任何相位都不会同时有错误与摘要。
    check(!allPhases.contains { $0.lastError != nil && $0.summary != nil },
          "正确实现的任何相位都不得同时持有错误与摘要")

    // 关键分歧序列：先成功，再失败。
    let s = sampleSummary
    var broken = BrokenState()
    broken = BrokenBackupPolicy.reduce(broken, event: .exportSucceeded(message: "ok", summary: s))
    broken = BrokenBackupPolicy.reduce(broken, event: .failed(message: "boom"))
    check(broken.lastError != nil && broken.lastSummary != nil,
          "★ 破坏变体（失败不清成功摘要）确实会造出「错误 + 摘要」并存 —— 反证有效")

    var good: Phase = .idle
    good = Policy.reduce(good, event: .exportSucceeded(message: "ok", summary: s))
    good = Policy.reduce(good, event: .failed(message: "boom"))
    checkEqual(good, .failed(message: "boom"), "正确实现：失败必须覆盖成功，不得残留摘要")
    check(good.failureMessage != nil && good.summary == nil,
          "★ 正确实现：失败终态绝不携带摘要")

    // 序列级扫描：正反两实现必须在某些 (相位 × 事件) 上就「错误与摘要并存」分歧。
    var caught = false
    for phase in allPhases {
        let baseline = brokenFrom(phase)
        for event in allEvents {
            let goodNext = Policy.reduce(phase, event: event)
            let brokenNext = BrokenBackupPolicy.reduce(baseline, event: event)
            let goodCoexists = goodNext.lastError != nil && goodNext.summary != nil
            let brokenCoexists = brokenNext.lastError != nil && brokenNext.lastSummary != nil
            if goodCoexists != brokenCoexists { caught = true }
        }
    }
    check(caught, "★ 破坏变体必须与正确实现在「错误 + 摘要并存」上分歧（检查器不得退化成恒真）")

    // 门禁不得退化成恒真：正确的 reduce 必须真的会改变相位。
    check(Policy.reduce(.idle, event: .exportBegan) != .idle,
          "正确的 reduce 必须会把 idle 推进到 exporting（否则检查器恒真）")
    check(Policy.reduce(.idle, event: .importBegan) != .idle,
          "正确的 reduce 必须会把 idle 推进到 validating")
    check(Policy.reduce(.idle, event: .dismissed) == .idle,
          "dismissed 在 idle 上是幂等的")
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyProjectionTruthTables()
verifyClampedProgress()
verifyReplaySequences()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 备份相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
