import UIKit

extension CGAffineTransform {
    /// 世界坐标系的纯平移。
    /// **必须配合 `base.applyingWorldDelta(_:)` 使用**；直接 `worldTranslation(d).concatenating(base)`
    /// 会把位移施加在局部坐标系里（被图元自身缩放比缩放），这正是「手指位移 ≠ 图元位移」的根因。
    static func worldTranslation(_ offset: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y)
    }

    /// 以 anchor 为不动点的世界坐标系缩放。
    static func worldScale(anchor: CGPoint, sx: CGFloat, sy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                          tx: anchor.x - sx * anchor.x,
                          ty: anchor.y - sy * anchor.y)
    }

    /// 以 center 为不动点的世界坐标系旋转。
    static func worldRotation(center: CGPoint, angle: CGFloat) -> CGAffineTransform {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                                 tx: center.x - (cosine * center.x - sine * center.y),
                                 ty: center.y - (sine * center.x + cosine * center.y))
    }

    var linearPart: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
    }

    /// 仅提取旋转角（假定无剪切、等比缩放）。
    var rotationAngle: CGFloat { atan2(b, a) }

    var uniformScale: CGFloat { (abs(a) + abs(d)) / 2 }

    /// 对点应用变换（与 `CGPoint.applying(_:)` 语义一致的表达式写法）。
    func applied(to point: CGPoint) -> CGPoint {
        point.applying(self)
    }

    // MARK: - 叠加 delta 的两种语义（实测：a.concatenating(b) = 先 a 后 b）

    /// 把**世界坐标系**的 delta 叠加到既有变换上：结果 = 先本变换、再 delta。
    /// 用于：贴图位移、旋转手柄、复合选区整体变换。
    func applyingWorldDelta(_ delta: CGAffineTransform) -> CGAffineTransform {
        concatenating(delta)
    }

    /// 把**局部坐标系**的 delta 叠加到既有变换上：结果 = 先 delta、再本变换。
    /// 用于：四角等比缩放（缩放定义在图元自身坐标系且锚点为局部角点）、裁剪的局部平移。
    func applyingLocalDelta(_ delta: CGAffineTransform) -> CGAffineTransform {
        delta.concatenating(self)
    }

    /// 让 `UIView.transform` 在父视图坐标系下等价于世界变换 `delta`。
    ///
    /// UIView 的 transform 是**绕视图中心**施加的，即有效映射为
    ///     effective = T(c) ∘ transform ∘ T(-c)        （函数序）
    /// 要令 effective == delta，必须赋值为
    ///     transform = T(c) ∘ delta ∘ T(-c)
    /// 用 concatenating（a.concatenating(b) = 先 a 后 b）表达即：T(c) → delta → T(-c)。
    /// 注意符号方向：写成 T(-c) → delta → T(c) 会把不动点镜像到错误一侧
    /// （表现为「十字画在中心，但内容绕着别处缩放/旋转」）。
    func viewConjugate(aboutCenter center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .concatenating(self)
            .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
    }
}

enum CanvasGeometry {
    /// 射线法：点是否落在任意简单多边形内。
    static func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in 0..<polygon.count {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let denominator = b.y - a.y
                if abs(denominator) > .ulpOfOne {
                    let x = (b.x - a.x) * (point.y - a.y) / denominator + a.x
                    if point.x < x { inside.toggle() }
                }
            }
            previous = current
        }
        return inside
    }

    // MARK: - 多边形相交

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint,
                                          _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func onSegment(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            min(a.x, b.x) - 0.0001 <= c.x && c.x <= max(a.x, b.x) + 0.0001
                && min(a.y, b.y) - 0.0001 <= c.y && c.y <= max(a.y, b.y) + 0.0001
        }
        let o1 = orientation(p1, p2, q1)
        let o2 = orientation(p1, p2, q2)
        let o3 = orientation(q1, q2, p1)
        let o4 = orientation(q1, q2, p2)
        if (o1 > 0) != (o2 > 0), (o3 > 0) != (o4 > 0) { return true }
        if abs(o1) < 0.0001, onSegment(p1, p2, q1) { return true }
        if abs(o2) < 0.0001, onSegment(p1, p2, q2) { return true }
        if abs(o3) < 0.0001, onSegment(q1, q2, p1) { return true }
        if abs(o4) < 0.0001, onSegment(q1, q2, p2) { return true }
        return false
    }

    /// 两个简单多边形是否相交（含完全包含）。
    /// 判定三条：① 任一方顶点落在对方内部；② 任一对边相交。
    /// 这比「四角/中心点落入」宽松得多 —— 套索只是擦过贴图边缘也应选中。
    static func polygonsIntersect(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        guard lhs.count >= 2, rhs.count >= 2 else { return false }
        if lhs.contains(where: { polygon(rhs, contains: $0) }) { return true }
        if rhs.contains(where: { polygon(lhs, contains: $0) }) { return true }
        for index in lhs.indices {
            let a1 = lhs[index]
            let a2 = lhs[(index + 1) % lhs.count]
            for other in rhs.indices {
                let b1 = rhs[other]
                let b2 = rhs[(other + 1) % rhs.count]
                if segmentsIntersect(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    static func path(points: [CGPoint], closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// 1° 步进旋转 + 15° / 45° / 90° 吸附（spec：触觉震动吸附）。
    static func snappedAngle(_ angle: CGFloat, tolerance: CGFloat = 1.5) -> (angle: CGFloat, snapped: Bool) {
        let radiansPerDegree = CGFloat.pi / 180
        let degrees = angle / radiansPerDegree
        let rounded = degrees.rounded()
        for multiple in [90.0, 45.0, 15.0] {
            let nearest = (rounded / multiple).rounded() * multiple
            if abs(nearest - rounded) <= tolerance {
                return (nearest * radiansPerDegree, true)
            }
        }
        return (rounded * radiansPerDegree, false)
    }
}
