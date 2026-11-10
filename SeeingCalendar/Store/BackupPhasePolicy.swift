import Foundation

/// 备份 / 恢复生命周期的相位。
///
/// **为什么需要它**：旧实现的「备份 / 恢复生命周期」由 5 个互不相干的存储字段 +
/// `RootView` 里第 6 个 `showRestoreDialog` 共同涌现，于是四类非法态可以凭空构造：
///
/// 1. **状态文案与忙碌位脱钩**：`statusText` 与 `isWorking` 之间没有任何强制关系 ——
///    「正在整理数据…」配 `isWorking == false` 是能构造出来的（早退路径正是这样）。
/// 2. **失败与成功并存**：`lastError` 与 `lastSummary` 可以同时非 nil（指纹告警接恢复成功、
///    成功后又失败），`BackupView` 的两个 `if let` 分支会同时命中。
/// 3. **进度残值**：`progress` 是 0…1 浮点，空闲时可能停在上一次的 `1.0`。
/// 4. **等待用户选择这件事被存了两份**：`pendingRestore != nil` 与 `showRestoreDialog`，
///    两份可以漂移。
///
/// 显式化之后，相位是**单一真值**，其余全部是它的只读投影；上述非法态从根上不可表达，
/// 且本类型是 `Equatable` + `Sendable` 的纯值类型，可被
/// `scripts/verify_backup_phase.swift` 直接镜像并穷举 (相位 × 事件) 全组合验证。
enum BackupPhase: Equatable, Sendable {
    case idle
    /// 正在打包归档。`progress` 是 0…1。
    case exporting(progress: Double)
    /// 正在校验所选归档。
    case validating
    /// 已解析出待恢复内容，**正在等用户选择恢复策略**（这就是被 `showRestoreDialog` 重复持有的那个事实）。
    ///
    /// `pending` 同时是 `pendingRestore` 投影的来源，「是否在等待用户选择」由它派生（`isAwaitingStrategy`）——
    /// 于是这件事**只有一份真值**。`choice` 是当前已选（默认）策略；`warning` 是完整性告警
    /// （例如指纹与清单不一致）—— 告警允许与「待恢复」共存，但**绝不**与失败终态混装。
    case awaitingStrategy(pending: RestoreBundle, choice: RestoreStrategyChoice, warning: String?)
    /// 正在执行恢复。
    case restoring(progress: Double)
    /// 终态：成功。`summary` 非空，`message` 是给人看的一句话。
    case finished(message: String, summary: RestoreSummary)
    /// 终态：失败。`message` 非空。
    case failed(message: String)

    /// 「忙碌」：只读投影（严格等价于旧的 `isWorking`）。
    var isWorking: Bool { BackupPolicy.isWorking(self) }

    /// 进度值；不处于进度相位时恒为 0（消除残值）。
    var progress: Double { BackupPolicy.progress(self) }

    /// 状态文案；对齐旧 `statusText` 的每个赋值点。
    var statusText: String { BackupPolicy.statusText(self) }

    /// 失败信息；**只有 `.failed` 才非空** —— 与 `.finished` 互斥
    /// （这是修掉「失败与成功并存」的关键）。
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// 成功摘要；**只有 `.finished` 才非空**。
    var summary: RestoreSummary? {
        if case .finished(_, let summary) = self { return summary }
        return nil
    }

    /// 是否正在等待用户选择恢复策略（**唯一真值**，`RootView` 的弹窗改为读它）。
    var isAwaitingStrategy: Bool { BackupPolicy.isAwaitingStrategy(self) }

    /// 待恢复内容（从 `.awaitingStrategy` 携带的载荷里取）。
    var pendingRestore: RestoreBundle? {
        if case .awaitingStrategy(let pending, _, _) = self { return pending }
        return nil
    }

    /// 完整性告警（指纹不一致等）；只在 `.awaitingStrategy` 携带它时非空。
    var warningMessage: String? {
        if case .awaitingStrategy(_, _, let warning) = self { return warning }
        return nil
    }
}

/// 恢复策略选项。
///
/// **直接复用生产中的 `RestoreMode`**（`fullOverwrite` / `smartMerge`），
/// 不另造同形枚举 —— 同形枚举会成为「同一事实的第二个持有者」，正是本任务要消灭的东西。
typealias RestoreStrategyChoice = RestoreMode

/// 备份相位机的驱动事件。
enum BackupEvent: Equatable, Sendable {
    case exportBegan
    case exportProgressed(Double)
    case exportSucceeded(message: String, summary: RestoreSummary)
    case importBegan
    /// 解析完成：待恢复内容 + 默认策略 + 可选的完整性告警。
    case importParsed(RestoreBundle, RestoreStrategyChoice, warning: String?)
    case strategyChosen(RestoreStrategyChoice)
    case restoreBegan
    case restoreProgressed(Double)
    case restoreSucceeded(message: String, summary: RestoreSummary)
    case failed(message: String)
    /// 用户关掉成功 / 失败提示，或放弃待恢复内容，回到 `.idle`。
    case dismissed
}

/// 备份 / 恢复相位机。
///
/// **纯逻辑**：不依赖 SwiftUI / SwiftData / UIKit，因此可被
/// `scripts/verify_backup_phase.swift` 直接镜像并穷举验证。
///
/// 固化的不变量：
///
/// 1. **终态互斥**：`.finished` 与 `.failed` 不可并存 —— `failureMessage` 与 `summary`
///    **永不同时非 nil**（门禁对此做穷举断言）。
/// 2. **`isWorking` 逐位等价于旧的 `isWorking`**：只有 `.exporting` / `.validating` /
///    `.restoring` 为真；`.awaitingStrategy` **不算忙碌**（旧实现里该相位期间
///    `defer { isWorking = false }` 已经执行，用户能操作）。
/// 3. **`acceptsNewRequest` 为真的恰好是 `.idle` / `.finished` / `.failed`**
///    （即旧 `!isWorking` 的全部可达态）。
/// 4. **`clampedProgress` 单调不降且落在 0…1**（防回调乱序导致进度倒退）。
/// 5. **`.dismissed` 从任何相位回到 `.idle`**，随之清空 `lastError` / `lastSummary`
///    （二者本就是 `.finished` / `.failed` 的投影，回 `.idle` 即自然归零）。
/// 6. **`.importParsed` 必须进入 `.awaitingStrategy` 并携带 payload**，
///    `pendingRestore` 与 `isAwaitingStrategy` 由它派生。
enum BackupPolicy {
    /// 是否处于「忙碌」相位。
    ///
    /// **逐位等价于旧的 `isWorking`**：旧实现在 `exportArchive` / `prepareRestore` 体内
    /// `isWorking = true` + `defer { isWorking = false }`，而 `applyPendingRestore`
    /// 全程同步、从不置位。因此忙碌的恰好是 `.exporting` / `.validating` / `.restoring`。
    static func isWorking(_ phase: BackupPhase) -> Bool {
        switch phase {
        case .exporting, .validating, .restoring: return true
        case .idle, .awaitingStrategy, .finished, .failed: return false
        }
    }

    /// 是否正在等待用户选择恢复策略。
    static func isAwaitingStrategy(_ phase: BackupPhase) -> Bool {
        if case .awaitingStrategy = phase { return true }
        return false
    }

    /// 进度投影：只有进度相位有值，其余恒为 0（消除残值）。
    static func progress(_ phase: BackupPhase) -> Double {
        switch phase {
        case .exporting(let value), .restoring(let value): return value
        case .idle, .validating, .awaitingStrategy, .finished, .failed: return 0
        }
    }

    /// 状态文案投影（对齐旧 `statusText` 的每个赋值点）。
    ///
    /// - `.exporting` 覆盖旧的「正在整理数据…」→「正在打包 .vcal 归档…」两段；
    /// - `.validating` 覆盖旧的「正在校验归档…」；
    /// - `.awaitingStrategy` 覆盖旧的「归档校验通过」；
    /// - `.finished` 直接用落地时携带的 `message`（旧「备份完成（…）」或 `summary.message`）；
    /// - `.failed` 用稳定的「操作失败」标签，具体原因由 `failureMessage` 呈现。
    static func statusText(_ phase: BackupPhase) -> String {
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

    /// 是否接受新的备份 / 恢复请求（旧 `guard !isWorking` 的类型化表达）。
    ///
    /// 为真的**恰好**是 `.idle` / `.finished` / `.failed` —— 旧 `!isWorking` 的全部可达态。
    static func acceptsNewRequest(_ phase: BackupPhase) -> Bool {
        switch phase {
        case .idle, .finished, .failed: return true
        case .exporting, .validating, .awaitingStrategy, .restoring: return false
        }
    }

    /// 进度裁剪：先夹在 0…1，再保证**不低于**当前值（防回调乱序导致进度倒退）。
    static func clampedProgress(_ value: Double, current: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return max(current, clamped)
    }

    /// 相位转移。
    ///
    /// 纪律：进度事件只在对应进度相位内生效；成功事件只在对应进行中相位内落地；
    /// `.failed` 从任何相位都可落到失败终态（终态互斥由类型保证）；
    /// `.dismissed` 恒回 `.idle`。
    static func reduce(_ phase: BackupPhase, event: BackupEvent) -> BackupPhase {
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
