import CoreGraphics
import Foundation

// MARK: - 下拉返回握手（M17）

/// 下拉返回握手相位。
///
/// 为什么需要它：旧实现只用一个 `pullDownEngaged: Bool`，却同时编码两件事 ——
/// 「已在画纸之外向下起手（armed）」与「已判定提交 onRequestDismiss（committed）」。
/// 一个 bool 只有两极：一旦在提交前被 `.cancelled` 复位，正在进行的判定就与
/// 「根本没起手」不可区分；反过来，「已提交」这个中间态也无法被观测、无法被穷举测试。
/// 相位机把三态显式化：`idle → armed → committed`，两个内联魔数（90 / 700）也一并具名。
enum PullDownPhase: Equatable, Sendable {
    /// 未起手。
    case idle
    /// 已在画纸之外向下起手，等待松手判定。
    case armed
    /// 已达阈值，等待回调 `onRequestDismiss`。
    case committed

    /// 是否已进入「下拉返回」流程（`armed` 或 `committed`）。
    ///
    /// 这是旧 `pullDownEngaged == true` 的**严格等价**投影 —— 之所以单独提供，
    /// 是为了让既有调用点零破坏地迁移过来，语义上却不再把「起手」与「提交」混为一谈。
    var isEngaged: Bool {
        switch self {
        case .idle: return false
        case .armed, .committed: return true
        }
    }
}

/// 下拉返回握手的驱动事件。
enum PullDownEvent: Equatable, Sendable {
    /// `gestureRecognizerShouldBegin` 判定通过（画纸之外起手 + 以向下为主）。
    case shouldBeginAccepted
    /// `gestureRecognizerShouldBegin` 判定否决。
    case shouldBeginRejected
    /// 松手：携带最终位移与速度，用于提交阈值判定。
    case ended(translationY: CGFloat, velocityY: CGFloat)
    /// 手势被取消或失败。
    case cancelled
}

/// 下拉返回握手相位机（纯逻辑，可被门禁镜像并穷举「相位 × 事件」全组合验证）。
enum PullDownPolicy {
    /// 位移阈值（原为 `handlePullDown` 里内联的 90 字面量）。
    static let distanceThreshold: CGFloat = 90
    /// 速度阈值（原为 `handlePullDown` 里内联的 700 字面量）。
    static let velocityThreshold: CGFloat = 700

    /// 是否已达「返回主页面」的提交阈值。
    ///
    /// **严格大于**：与旧内联判定 `translation.y > 90 || velocity.y > 700` **逐位等价**，
    /// 边界值（恰好 90 / 700）**不**触发返回 —— 门禁对 9 组边界值逐点钉死了这一点。
    static func commits(translationY: CGFloat,
                        velocityY: CGFloat,
                        distance: CGFloat = distanceThreshold,
                        velocity: CGFloat = velocityThreshold) -> Bool {
        translationY > distance || velocityY > velocity
    }

    /// 相位转移。`ended` 是唯一的提交判定点：
    ///
    /// * 只有 `armed` / `committed`（即 `isEngaged`）才有资格判定，`idle` 收到 `ended`
    ///   原样返回 —— 逐位等价于旧实现的 `guard pullDownEngaged else { return }`；
    /// * 无论是否达阈值，`ended` 之后都**不再停留在 `armed`**（回 `committed` 或 `idle`）——
    ///   逐位等价于旧实现的「松手即 `pullDownEngaged = false`」。
    ///
    /// `.committed` 因此**不是终态**：`.cancelled` / `.reset` / 下一次 `ended` 都能把它带走。
    static func reduce(_ phase: PullDownPhase, event: PullDownEvent) -> PullDownPhase {
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

// MARK: - 原生菜单退场冷却（M18）

/// 原生菜单退场冷却相位（取代「时间戳当状态」）。
///
/// 为什么需要它：旧实现用 `menuActionGuardUntil: Date` 当状态 ——
/// ① 挂钟时间不是状态：`Date()` 抖一下、主线程卡顿一下，行为就变；
/// ② 它是公开可写属性，任何地方都能把它推来推去，语义全靠约定；
/// ③ 「冷却中」这个相位不进任何状态机，无法被穷举测试。
///
/// 关键设计决策：`coasting` 的**退出条件不是挂钟时间，而是触摸生命周期**。
/// 菜单退场透传下来的其实是**一次**触摸，弹一次就够；因此把冷却窗口定义为
/// 「恰好一次点击」：`coasting` 收到 `tapReceived` 即消费掉这次透传并回到 `open`。
enum MenuGuardPhase: Equatable, Sendable {
    /// 菜单未动作或冷却已结束，画布点击正常处理。
    case open
    /// 刚从菜单点选动作，退场触摸可能透传，忽略画布点击。
    case coasting

    /// 是否应吞掉这一次画布点击。这是旧 `Date() < menuActionGuardUntil` 的等价投影。
    var blocksCanvasTap: Bool { self == .coasting }
}

/// 原生菜单冷却的驱动事件。
enum MenuGuardEvent: Equatable, Sendable {
    /// 用户在原生菜单里点选了一个动作（可能触发菜单退场透传）。
    case menuActionSelected
    /// 画布接受到一次点击。
    case tapReceived
    /// 显式复位（例如切换页面 / 退出编辑）。
    case reset
}

/// 原生菜单退场冷却相位机（纯逻辑，可被门禁镜像并穷举「相位 × 事件」全组合验证）。
enum MenuGuardPolicy {
    /// 相位转移。
    ///
    /// 用触摸计数而非挂钟时间的原因：挂钟窗口要么太短（吞不住透传，问题照旧），
    /// 要么太长（顺手吃掉用户的正常点击），且主线程卡顿会让它随机命中任一侧；
    /// 「一次透传 = 一次点击」是确定性的、可穷举的，行为不随时间漂移。
    static func reduce(_ phase: MenuGuardPhase, event: MenuGuardEvent) -> MenuGuardPhase {
        switch event {
        case .menuActionSelected:
            return .coasting

        case .tapReceived:
            // 消费掉这一次透传触摸 → 回到 open（冷却窗口 = 恰好一次点击）。
            return .open

        case .reset:
            return .open
        }
    }
}
