import PencilKit
import UIKit

/// 跨图层统一选区仲裁引擎。
/// 先用 AABB 做粗筛，再对候选笔迹采样做多边形细筛，将套索判定稳定压进一帧预算内。
enum UnifiedLassoArbitrator {
    struct ImageSnapshot {
        var id: UUID
        var quad: [CGPoint]
    }

    struct Result {
        var strokeIndices: [Int] = []
        var imageIDs: [UUID] = []
        var bounds: CGRect = .null
    }

    static func evaluate(lasso: [CGPoint],
                         drawing: PKDrawing,
                         images: [ImageSnapshot]) -> Result {
        var result = Result()
        guard lasso.count >= 3 else { return result }
        let lassoBounds = CanvasGeometry.boundingBox(lasso)

        // 1. 笔迹层：AABB 粗筛 → 采样点细筛（记录索引，避免依赖 PKStroke 等值语义）
        let strokes = drawing.strokes
        for (index, stroke) in strokes.enumerated() {
            guard stroke.renderBounds.intersects(lassoBounds) else { continue }
            if strokeIsInside(stroke, lasso: lasso) {
                result.strokeIndices.append(index)
                result.bounds = result.bounds.isNull
                    ? stroke.renderBounds
                    : result.bounds.union(stroke.renderBounds)
            }
        }

        // 2. 贴图层：四角 + 中心任一点落入套索即命中
        for image in images {
            let quadBounds = CanvasGeometry.boundingBox(image.quad)
            guard !quadBounds.isNull, quadBounds.intersects(lassoBounds) else { continue }
            let center = CGPoint(x: quadBounds.midX, y: quadBounds.midY)
            let hit = image.quad.contains { CanvasGeometry.polygon(lasso, contains: $0) }
                || CanvasGeometry.polygon(lasso, contains: center)
            if hit {
                result.imageIDs.append(image.id)
                result.bounds = result.bounds.isNull ? quadBounds : result.bounds.union(quadBounds)
            }
        }
        return result
    }

    private static func strokeIsInside(_ stroke: PKStroke, lasso: [CGPoint]) -> Bool {
        let path = stroke.path
        let count = path.count
        guard count > 0 else { return false }
        let stride = max(1, count / 24)
        var index = 0
        while index < count {
            let location = path[index].location.applying(stroke.transform)
            if CanvasGeometry.polygon(lasso, contains: location) { return true }
            index += stride
        }
        // 收尾采样：确保最后一个点也被检查
        let lastLocation = path[count - 1].location.applying(stroke.transform)
        return CanvasGeometry.polygon(lasso, contains: lastLocation)
    }
}
