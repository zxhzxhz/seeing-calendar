import Foundation

/// 单指归属：画布（绘制）还是外层滚动视图（平移）。
enum FingerRouting: Equatable, Sendable {
    case pansCanvas
    case drawsOnCanvas
}

/// 单指触控路由策略（M9）。
///
/// 为什么需要它：旧实现把这条规则写成一个内联三元表达式
/// `scrollView.panGestureRecognizer.minimumNumberOfTouches = (手指书写 && 会绘制) ? 2 : 1`，
/// 策略值无处存放、无法被穷举测试，也说不清它为什么是「两个维度相与」。
/// 抽成纯函数后，(2 × 7) 全组合可被门禁逐位钉死。
enum TouchRoutingPolicy {
    /// 单指的最终归属。
    ///
    /// **两个正交维度必须同时成立**：
    /// ① `isFingerDrawingEnabled` 是用户的**偏好**（愿不愿意用手指写字）；
    /// ② `inputMode.drawsWithFinger` 是**当前模式的性质**（导航态会把单指让给平移）。
    ///
    /// 只有两者都成立，单指才归画布（外层 pan 需双指、保留缩放）；任一不成立，单指都归
    /// 外层滚动视图平移。之所以拆成两个维度而不是塞进一个 bool：偏好与模式可以任意组合
    /// （「关掉手指书写 + 套索态」与「打开手指书写 + 导航态」都合法，行为却相反），
    /// 相与才是「既想用手指写、又确实在写」这一唯一开画的时刻。
    static func fingerRouting(isFingerDrawingEnabled: Bool, inputMode: CanvasInputMode) -> FingerRouting {
        (isFingerDrawingEnabled && inputMode.drawsWithFinger) ? .drawsOnCanvas : .pansCanvas
    }

    /// 外层 pan 所需的最少触点数（1 = 单指平移画布；2 = 单指留给绘制，保留双指平移）。
    static func panMinimumNumberOfTouches(for routing: FingerRouting) -> Int {
        routing == .drawsOnCanvas ? 2 : 1
    }

    /// 便捷组合入口。
    static func panMinimumNumberOfTouches(isFingerDrawingEnabled: Bool, inputMode: CanvasInputMode) -> Int {
        panMinimumNumberOfTouches(
            for: fingerRouting(isFingerDrawingEnabled: isFingerDrawingEnabled, inputMode: inputMode))
    }
}
