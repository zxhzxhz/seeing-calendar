import CoreGraphics
import Foundation

// MARK: - 贴图拖动相位机（M10）

/// 一次单指拖动的相位。
///
/// 为什么需要它：旧实现用 **5 个扁平字段**共同表达一次拖动的生命周期 ——
/// `isMoving` / `gestureBase` / `gestureStartPoint` / `hasLeftDeadZone` / `gestureStartWindow`，
/// 没有任何类型约束。`.began` / `.changed` / `.ended` 三个分支各自手工维护
/// 「这 5 个字段是否同时成立」，例如 `.changed` 里那句
/// `guard let base = gestureBase, let parent = superview, var start = gestureStartPoint else { return }`
/// 就是在替一个本可以类型化的相位做防御：字段组合的合法子集只存在于作者脑子里，
/// 少置一个、漏清一个都只能靠人眼复核。
///
/// 相位机把合法状态显式化为三态，并把两个内联魔数（死区 `3` / 亚像素 `0.5`）一并具名：
/// `idle → armed（`.began` 已到但还没出死区）→ dragging（已出死区）`。
/// 于是「基点、锚点、窗口锚点是否同时存在」由类型保证，防御式 `guard` 不再需要。
enum DragPhase: Equatable, Sendable {
    /// 没有进行中的拖动。
    case idle
    /// 手势已成立，但还没越过起始死区（吃掉误触与触摸抖动）。
    case armed(base: CGAffineTransform, anchor: CGPoint, windowAnchor: CGPoint)
    /// 已越过死区，`anchor` 已重锚到当前位置（因此死区不产生任何跳变）。
    case dragging(base: CGAffineTransform, anchor: CGPoint)

    /// 是否允许重挂载视图（即「不属于本次拖动」）。
    ///
    /// 为真的**恰好是** `.idle` —— 这是 #「拖拽期间严禁 `removeFromSuperview`
    /// （会取消进行中的手势）」的类型化表达。`.armed` 不算「允许重挂载」：
    /// 手势已经成立，此时重挂载同样会打断本手势。
    var allowsRemount: Bool { self == .idle }

    /// 是否正在被拖动。
    ///
    /// 旧 `isMoving` 存储旗标的**严格等价**投影：`.began` 之后（armed）到
    /// `.ended` 之前皆为真，语义与旧实现逐位一致。
    var isMoving: Bool {
        switch self {
        case .idle: return false
        case .armed, .dragging: return true
        }
    }

    /// 本次拖动的基点变换（`idle` 为 nil）。
    ///
    /// 位移必须**恒以基点为参考**（见 `DragPolicy.translation`），因此基点一旦
    /// 在 `.began` 落定，整段拖动期间不再变化 —— `.dragging` 只是把锚点重锚，
    /// 基点保持不变。
    var activeBase: CGAffineTransform? {
        switch self {
        case .idle: return nil
        case .armed(let base, _, _): return base
        case .dragging(let base, _): return base
        }
    }

    /// 本次拖动的锚点（`idle` 为 nil）。位移一律相对它计算（**绝不增量累加**）。
    var activeAnchor: CGPoint? {
        switch self {
        case .idle: return nil
        case .armed(_, let anchor, _): return anchor
        case .dragging(_, let anchor): return anchor
        }
    }
}

/// 拖动相位机的驱动事件。
enum DragEvent: Equatable, Sendable {
    /// 手势成立（对应 `.began`）：携带基点、世界锚点与窗口锚点。
    case began(base: CGAffineTransform, anchor: CGPoint, windowAnchor: CGPoint)
    /// 手指移动（对应 `.changed`）。
    ///
    /// `anchor` 取**画布世界坐标**（用于算位移），`windowAnchor` 取**窗口坐标**
    /// （用于量死区，免受画布 zoomScale 与图元自身变换影响）。
    case moved(anchor: CGPoint, windowAnchor: CGPoint)
    /// 手势结束 / 取消 / 失败（对应 `.ended` / `.cancelled` / `.failed`）。
    case ended
}

/// 拖动相位机（纯逻辑，不依赖 UIKit / SwiftUI）。
///
/// 因此可被 `scripts/verify_drag_phase.swift` 直接镜像并穷举「相位 × 事件」全组合验证。
///
/// 固化的不变量：
///
/// 1. **`translation` 恒以基点为参考**（`current − anchor`），绝不增量累加 ——
///    旧实现的两条注释都强调这一点：亚像素帧被过滤掉时不丢位移，多次移动也不会漂移。
/// 2. **死区退出时基点重锚**：`.armed → .dragging` 必须把 `anchor` 换成当前位置，
///    因此死区**不产生跳变**（退出那一帧的位移恒为 `current − current = .zero`）。
/// 3. **`leftDeadZone` 用窗口坐标度量**（`windowAnchor`），不用世界坐标 ——
///    否则画布 zoomScale 会改变死区手感。
/// 4. **`.ended` 从任何非 idle 相位都回到 `.idle`（幂等）**；`idle` 收到 `moved` 原样返回。
/// 5. **`allowsRemount` 为真的恰好是 `.idle`**。
enum DragPolicy {
    /// 起始死区（原为 `ImageEntityView.dragDeadZone` 的 3，屏幕点）。
    static let deadZone: CGFloat = 3
    /// 亚像素更新阈值（原为 `ImageEntityView.dragEpsilon` 的 0.5，世界点）。
    static let epsilon: CGFloat = 0.5

    /// 世界位移 = 当前点 − 基点（**绝不做增量累加**，避免误差累积）。
    ///
    /// 这是旧实现两条注释共同强调的基点模型：位移永远相对一个**固定参考**计算，
    /// 而不是把每帧的小增量加起来。好处有二 ——
    /// ① 亚像素帧被过滤掉时位移不丢（下一帧仍从基点重新度量）；
    /// ② 往返回到基点时位移精确为 `.zero`，不像增量式实现那样累积浮点漂移。
    static func translation(anchor: CGPoint, from base: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x - base.x, y: anchor.y - base.y)
    }

    /// 是否已越过死区（用**窗口坐标**度量，因此免受画布 zoomScale 与图元自身变换影响）。
    ///
    /// **严格 `>= deadZone` 才算越界**：与旧内联判定 `travel >= Self.dragDeadZone`
    /// 逐位等价，恰好 `deadZone` 点**已经**越界。门禁对 2.9 / 3.0 / 3.1 逐点钉死了这一点。
    static func leftDeadZone(current: CGPoint, anchor: CGPoint, deadZone: CGFloat = deadZone) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) >= deadZone
    }

    /// 是否值得重排（亚像素过滤，**严格 `>`**）。
    ///
    /// 与旧内联判定 `abs(delta.x) > epsilon || abs(delta.y) > epsilon` 逐位等价；
    /// 恰好 `epsilon` **不**触发（门禁对 0.4 / 0.5 / 0.6 逐点钉死）。
    static func exceedsEpsilon(_ delta: CGPoint, epsilon: CGFloat = epsilon) -> Bool {
        abs(delta.x) > epsilon || abs(delta.y) > epsilon
    }

    /// 相位转移。
    ///
    /// * `.began`：从**任何**相位进入 `.armed`（重新起手即重置基点与新锚点）。
    /// * `.moved`：
    ///   - `idle` 原样返回 —— 逐位等价于旧实现「没有基点就 `return`」；
    ///   - `armed` 未出死区原样返回，出死区则**重锚**（`anchor = 当前位置`）并转 `.dragging`；
    ///   - `dragging` 保持基点与锚点不变 —— 位移恒相对同一基点计算，不累加。
    /// * `.ended`：从任何非 idle 相位回到 `.idle`（幂等）；`idle` 收到后仍是 `.idle`。
    static func reduce(_ phase: DragPhase, event: DragEvent) -> DragPhase {
        if case .began(let base, let anchor, let windowAnchor) = event {
            // 重新起手即重置基点与新锚点。
            return .armed(base: base, anchor: anchor, windowAnchor: windowAnchor)
        }
        if case .ended = event {
            // ended 从任何非 idle 相位都回到 .idle，且对 idle 幂等。
            return .idle
        }
        guard case .moved(let anchor, let windowAnchor) = event else { return phase }
        // idle 收到 moved 原样返回 —— 逐位等价于旧实现「没有基点就 return」。
        if case .idle = phase { return .idle }
        if case .armed(let base, _, let windowStart) = phase {
            guard leftDeadZone(current: windowAnchor, anchor: windowStart) else { return phase }
            // 退出死区时把锚点换成当前位置 —— 因此死区不产生任何跳变。
            return .dragging(base: base, anchor: anchor)
        }
        // dragging：保持基点与锚点不变 —— 位移恒相对同一基点计算，不累加。
        return phase
    }
}
