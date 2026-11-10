import Foundation

/// 日历刷新相位（M5「CalendarEventStore 刷新生命周期」的显式相位机）。
///
/// **为什么需要它**：旧实现把刷新生命周期拆成三个互不相干的隐式旗标 ——
/// `isRefreshing` 存储布尔 + `defer { isRefreshing = false }` 包住 `await`、
/// `lastRefresh` 用时间谓词当状态、`lastError` 混装全局失败与逐订阅失败。
/// 三者叠加出三类用户报回来的回退：
///
/// 1. **加载态提前熄火**：并发刷新时先返回的那次 `defer` 会把旗标清掉，界面于是在
///    另一趟请求仍在飞行时把加载指示收回。
/// 2. **迟到的刷新结果覆盖新结果**：没有代次纪律，先发出的陈旧刷新落地时会盖回旧结果。
/// 3. **冷却窗口无处存放**：`now.timeIntervalSince(lastRefresh) < 900` 是每次现算的
///    时间比较，不是状态 —— 一旦相位切走，窗口就丢了。
///
/// 相位 + 代次把这三件事收进一个显式状态机：只有代次不早于当前代次的响应才允许
/// 改变相位（见 `RefreshPolicy.reduce`）。
///
/// **纯逻辑**：不依赖 SwiftUI / SwiftData / UIKit / URLSession，
/// 因此可被 `scripts/verify_refresh_state.swift` 直接镜像并穷举 (相位 × 事件) 全组合验证。
enum RefreshPhase: Equatable, Sendable {
    case idle
    /// 正在拉取，携带开局时刻与本趟代次。
    case refreshing(startedAt: Date, generation: Int)
    /// 最近一次**被采纳**的刷新成功；冷却窗口作为**状态**保存在这里，
    /// 而不是每次现算 `now.timeIntervalSince(lastRefresh) < cooldown`。
    case coolingDown(until: Date, generation: Int)
    /// 最近一次**被采纳**的刷新失败。
    case failed(message: String, generation: Int)

    /// 界面上的「刷新中」：只有 `.refreshing` 算，严格等价于旧的存储旗标。
    var isRefreshing: Bool { RefreshPolicy.isRefreshing(self) }

    /// 失败信息（供兼容只读入口使用）。
    var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

/// 刷新相位机的驱动事件。
enum RefreshEvent: Equatable, Sendable {
    /// 开局一趟刷新：(开始时刻, 代次)。
    case began(startedAt: Date, generation: Int)
    /// 一趟刷新成功落地：(落地时刻, 代次) —— 落地后进入冷却窗口。
    case succeeded(at: Date, generation: Int)
    /// 一趟刷新失败落地：(信息, 落地时刻, 代次)。
    case failed(message: String, at: Date, generation: Int)
    /// 清空（订阅被清空 / 显式 `clear()`）：**恒回到 `.idle`**。
    case cleared
}

/// 刷新相位机的转移函数与判据。
///
/// 固化的不变量：
///
/// 1. **迟到响应不得改变相位**。`accepts(generation:latest:)` 是唯一判据；
///    代次早于 `latestGeneration` 的事件连 `isRefreshing` 都不能碰
///    —— 这正是「先返回者提前熄火」的修法。
/// 2. **成功后进入 `.coolingDown(until: at + cooldown)`**，冷却窗口是**状态**，
///    不是每次现算的时间比较。
/// 3. **代次相等必须采纳**（`>=`），否则单次同步刷新会被自己拒绝。
/// 4. **`.cleared` 恒回到 `.idle`**，与之前是哪个相位无关。
enum RefreshPolicy {
    /// 冷却窗口（原为 `refresh(subscriptions:force:)` 内联的 900 秒字面量）。
    static let cooldown: TimeInterval = 900

    /// 响应采纳判定：**只有代次不早于当前代次才采纳**。
    static func accepts(generation: Int, latest: Int) -> Bool {
        return generation >= latest
    }

    /// 相位是否处于「刷新中」。
    static func isRefreshing(_ phase: RefreshPhase) -> Bool {
        if case .refreshing = phase { return true }
        return false
    }

    /// 是否跳过本次刷新。
    ///
    /// **逐位等价**于旧实现的三合一谓词：`!force && 冷却窗口内 && !events.isEmpty`。
    /// 其中「冷却窗口内」用状态 `now < until` 表达；由于
    /// `lastRefresh == until - cooldown`，它与旧式
    /// `now.timeIntervalSince(lastRefresh) < cooldown` 完全同解（含 t+900 端点）。
    static func shouldSkip(phase: RefreshPhase, now: Date, force: Bool, hasEvents: Bool) -> Bool {
        guard !force, hasEvents else { return false }
        guard case .coolingDown(let until, _) = phase else { return false }
        return now < until
    }

    /// 相位转移。`latestGeneration` 是当前活跃刷新的代次。
    ///
    /// 早于 `latestGeneration` 的事件一律**原样返回当前相位** —— 不写、不清、
    /// 不熄火。这是本状态机的核心纪律。
    static func reduce(_ phase: RefreshPhase, event: RefreshEvent, latestGeneration: Int) -> RefreshPhase {
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
