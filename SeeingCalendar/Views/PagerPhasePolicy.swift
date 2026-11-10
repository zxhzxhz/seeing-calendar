import Foundation

/// 月历翻页相位。
///
/// 为什么需要它：旧实现用 `var offset: CGFloat`（像素偏移）+ `var isSettling = false`
/// 两个字段**共同涌现**出三种状态 —— `idle` / `dragging` / `settling`。这个隐式状态机
/// 有三个代价：
///
/// 1. **纪律靠手抄**：「落位动画期间屏蔽新手势」这条规则在 `swipeGesture.onChanged`、
///    `swipeGesture.onEnded` 和 `settle(to:commit:)` 里各写了一遍 `guard !isSettling`；
///    漏抄一处就会出现「落位动画被新手势打断 → 月序错乱」。
/// 2. **两条复位路径**：`settle()` 与 `springBack()` 各自改 `offset`，没有共同的收敛点。
/// 3. **能力无处可查**：「当前相位能否接受手势 / 能否接受落位」只能读代码反推。
///
/// 本相位机把这三件事显式化：相位是唯一的真值，转移集中到 `PagerPolicy.reduce`，
/// 能力由 `acceptsGesture` 显式回答。纯逻辑、不 import SwiftUI，因此可被
/// `scripts/verify_pager_phase.swift` 直接镜像并穷举 (相位 × 事件) 全组合验证。
enum PagerPhase: Equatable, Sendable {
    /// 静止：无拖动、无落位动画，`offset` 恒为 0。
    case idle
    /// 用户正在拖动，携带当前像素偏移（正为右移、看上一月）。
    case dragging(offset: CGFloat)
    /// 落位弹簧动画进行中，携带动画目标偏移；期间屏蔽一切新手势。
    case settling(offset: CGFloat)

    /// 相位投影出的像素偏移（`idle` 恒为 0）。
    var offset: CGFloat {
        switch self {
        case .idle: return 0
        case .dragging(offset: let value), .settling(offset: let value): return value
        }
    }

    /// 是否正在落位。等价于旧的 `isSettling` 旗标。
    var isSettling: Bool { PagerPolicy.isSettling(self) }

    /// 当前相位能否接受**新手势**：只有静止与拖动中接受；落位期间一律屏蔽，
    /// 否则弹簧动画被打断会导致月序错乱（这正是旧实现三处手抄守卫的语义）。
    var acceptsGesture: Bool { !isSettling }
}

/// 翻月相位机的驱动事件。
enum PagerEvent: Equatable, Sendable {
    /// 手势开始。
    ///
    /// 为完整性而保留：`DragGesture` 在超过最小识别距离后的首个 `.onChanged` 已携带位移，
    /// 因此实际手势路径只用 `dragChanged`；本事件供相位机自证与穷举验证。
    case dragBegan
    /// 拖动中，携带经阻尼换算后的偏移。
    case dragChanged(offset: CGFloat)
    /// 松手。`committed` 为真表示已越过翻页阈值、进入落位；为假表示弹回原位。
    case dragEnded(committed: Bool)
    /// 落位弹簧动画收尾。
    case settleFinished
}

/// 翻月相位机。
///
/// 固化的不变量：
///
/// 1. **落位期间屏蔽新输入**：`.settling` 期间任何 `dragBegan` / `dragChanged` /
///    `dragEnded` 都**原样返回当前相位**，一个字都不改。
/// 2. **弹回必定收敛到 `.idle`**：对手势可接受相位（`.idle` / `.dragging`），
///    `.dragEnded(committed: false)` 必定回到 `.idle`（`offset` 归零）。
/// 3. **落位收尾必定收敛到 `.idle`**：`.settleFinished` 只从 `.settling` 回到 `.idle`，
///    对其它相位是 no-op。
enum PagerPolicy {
    /// 松手方向判定用的速度阈值（原为 `.onEnded` 内联字面量 220）。
    static let swipeVelocityThreshold: CGFloat = 220
    /// 松手方向判定用的距离比例（原为 `.onEnded` 内联字面量 0.13）。
    static let swipeDistanceFraction: CGFloat = 0.13

    /// 是否正在落位。
    static func isSettling(_ phase: PagerPhase) -> Bool {
        if case .settling = phase { return true }
        return false
    }

    /// 落位动画期间对外可见的缩略图代次（`nil` = 未冻结，采用实时值）。
    ///
    /// **为什么必须冻结**：`state.offset` 每帧变化会让 `MonthPager` 重算；
    /// 而 `withAnimation` 的弹簧动画期间，任何让内容树等值判定翻转的输入
    /// （缩略图代次是唯一一个会在任意时刻自己变的）都会让 126 个日格
    /// **在该动画事务内**被重建 —— 视觉上就是「每一格各自在动」。
    /// 落位期间把它钉住，动画全程内容树零重算，位移只剩一次容器变换。
    ///
    /// 不变量：① 非落位 → 一律解冻（返回 nil）；
    /// ② 落位且已冻结 → **原样保留**，动画中途绝不改写（否则又会被击穿）；
    /// ③ 落位且未冻结 → 以当时的实时值冻结。
    static func updatedFrozenVersion(current frozen: Int?, isSettling: Bool, live: Int) -> Int? {
        guard isSettling else { return nil }
        return frozen ?? live
    }

    /// 相位转移 —— 全状态机唯一的收敛点。
    static func reduce(_ phase: PagerPhase, event: PagerEvent) -> PagerPhase {
        switch event {
        case .dragBegan:
            // 落位期间屏蔽新手势；否则进入 dragging（保留既有偏移）。
            return phase.acceptsGesture ? .dragging(offset: phase.offset) : phase

        case .dragChanged(let offset):
            // ★ 落位期间任何拖动都不得改变相位。
            return phase.isSettling ? phase : .dragging(offset: offset)

        case .dragEnded(let committed):
            // 落位期间松手事件同样被屏蔽。
            if phase.isSettling { return phase }
            // 未越过阈值 → 弹回静止；越过 → 进入落位（目标偏移由调用方随后写入）。
            return committed ? .settling(offset: phase.offset) : .idle

        case .settleFinished:
            // ★ 只有落位相位能收尾回静止。
            return phase.isSettling ? .idle : phase
        }
    }

    /// 拖动位移 → 实际施加到 offset 上的值（含超界阻尼）。
    ///
    /// 逐位复现旧 `.onChanged` 的内联逻辑：超出单屏宽度 `limit` 的部分按 `overdamp`
    /// （0.45）阻尼，未超出则原样透传（含 ±0 与恰好等于 `limit` 的边界）。
    static func dampedOffset(translation: CGFloat, limit: CGFloat, overdamp: CGFloat) -> CGFloat {
        let magnitude = abs(translation)
        guard magnitude > limit else { return translation }
        let damped = limit + (magnitude - limit) * overdamp
        return translation > 0 ? damped : -damped
    }

    /// 距离阈值换算：`containerWidth * swipeDistanceFraction`（默认比例即原字面量 0.13）。
    static func swipeDistanceThreshold(containerWidth: CGFloat,
                                       fraction: CGFloat = swipeDistanceFraction) -> CGFloat {
        containerWidth * fraction
    }

    /// 松手方向判定。`+1` → 下一月（内容左移），`-1` → 上一月，`0` → 两者皆不足、弹回。
    ///
    /// 逐位复现旧 `.onEnded` 的内联逻辑：先看速度（阈值 `velocityThreshold`，默认即原
    /// 字面量 220），再看位移（阈值 `threshold`）；每一处都是**严格**大于 / 小于。
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
}
