#!/usr/bin/env python3
"""Round-5 fix: 统一 CGAffineTransform 合成方向（以 CI 实测为准），位移改为「基点 + 世界位移」。

实测事实（scripts/verify_transform_math.swift 在 macOS 上跑真实 CoreGraphics）：
    scale2.concatenating(shift10) 作用于 (1,0) → (12,0)
    ⇒ a.concatenating(b) 的语义是「先应用 a，再应用 b」

由此推出的正确写法：
    世界坐标 delta（位移 / 旋转 / 整体变换）: base.concatenating(delta)
    局部坐标 delta（角手柄缩放 / 裁剪平移）: delta.concatenating(base)
"""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def patch(rel: str, pairs: list[tuple[str, str]]) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"MISS in {rel}: {old[:90]!r}")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("patched", rel)


# 1) 变换语义显式化：新增 applyingWorldDelta / applyingLocalDelta，避免再次搞错合成方向
patch(
    "SeeingCalendar/Canvas/CanvasGeometry.swift",
    [
        (
            """extension CGAffineTransform {
    /// 世界坐标系的纯平移（左乘语义：先平移，再应用右侧变换）。
    static func worldTranslation(_ offset: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y)
    }""",
            """extension CGAffineTransform {
    /// 世界坐标系的纯平移。
    /// **必须配合 `base.applyingWorldDelta(_:)` 使用**；直接 `worldTranslation(d).concatenating(base)`
    /// 会把位移施加在局部坐标系里（被图元自身缩放比缩放），这正是「手指位移 ≠ 图元位移」的根因。
    static func worldTranslation(_ offset: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y)
    }"""
        ),
        (
            """    /// 对点应用变换（与 `CGPoint.applying(_:)` 语义一致的表达式写法）。
    func applied(to point: CGPoint) -> CGPoint {
        point.applying(self)
    }
}""",
            """    /// 对点应用变换（与 `CGPoint.applying(_:)` 语义一致的表达式写法）。
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

    /// 让 `UIView.transform` 在父视图坐标系下等价于世界变换 `delta`
    /// （UIView 的 transform 是以视图中心为原点施加的，需做一次共轭校正）。
    func viewConjugate(aboutCenter center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(self)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
}"""
        ),
    ],
)

# 2) 位移：基点模型 + 世界坐标 delta + 两级去抖
patch(
    "SeeingCalendar/Canvas/ImageEntityView.swift",
    [
        (
            """    /// 是否正在被拖动。拖拽期间严禁重挂载（removeFromSuperview 会取消进行中的手势）。
    private(set) var isMoving = false""",
            """    /// 是否正在被拖动。拖拽期间严禁重挂载（removeFromSuperview 会取消进行中的手势）。
    private(set) var isMoving = false

    /// 起始死区（屏幕点）：吃掉误触与触摸抖动，退出死区时重新锚定，因此不会产生跳变。
    private static let dragDeadZone: CGFloat = 3
    /// 亚像素更新阈值（世界点）：手指几乎静止时不做无意义重排；始终以基点为参考，不会丢位移。
    private static let dragEpsilon: CGFloat = 0.5
    private var hasLeftDeadZone = false
    private var gestureStartWindow: CGPoint = .zero"""
        ),
        (
            """        case .began:
            // 必须先置位：onSelect 会触发“选中置顶”，此时若重挂载会立刻打断本手势。
            isMoving = true
            gestureBase = worldTransform
            gestureStartPoint = gesture.location(in: superview)
            onSelect?(self)
            onBeginMove?(self)
        case .changed:
            guard let base = gestureBase, let parent = superview, let start = gestureStartPoint else { return }
            // 注意：此处必须使用 location 差值而非 translation(in:)，
            // 否则在缩放过的祖先坐标系（画布 zoomScale ≠ 1）下，手指位移与贴图位移不等距。
            let current = gesture.location(in: parent)
            let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
            worldTransform = CGAffineTransform.worldTranslation(delta).concatenating(base)
            applyWorldTransform()
            onTransformChanged?(self)
        case .ended, .cancelled, .failed:
            // 先复位再回调：容器会在 onEndMove 里补做延迟的“置顶重挂载”。
            isMoving = false
            gestureBase = nil
            gestureStartPoint = nil
            onEndMove?(self)""",
            """        case .began:
            // 必须先置位：onSelect 会触发“选中置顶”，此时若重挂载会立刻打断本手势。
            isMoving = true
            gestureBase = worldTransform
            // 基点模型：首触点为锚，之后一律「当前点 − 基点」求位移，不做增量累加（避免误差累积）。
            gestureStartPoint = gesture.location(in: superview)
            gestureStartWindow = gesture.location(in: window ?? superview ?? self)
            hasLeftDeadZone = false
            onSelect?(self)
            onBeginMove?(self)
        case .changed:
            guard let base = gestureBase, let parent = superview, var start = gestureStartPoint else { return }
            let current = gesture.location(in: parent)

            // 去抖 ①：起始死区。在手势刚成立时忽略极小位移，避免误触/抖动；
            //          退出死区时把基点重锚到当前位置 —— 因此死区不会造成任何跳变。
            if !hasLeftDeadZone {
                let reference = window ?? parent
                let windowPoint = gesture.location(in: reference)
                let travel = hypot(windowPoint.x - gestureStartWindow.x, windowPoint.y - gestureStartWindow.y)
                guard travel >= Self.dragDeadZone else { return }
                hasLeftDeadZone = true
                gestureStartPoint = current
                start = current
            }

            // 位移 = 当前点 − 基点，两个点都取自**画布世界坐标系**：
            // 因此天然免受画布 zoomScale、图元自身缩放/旋转的影响（比值恒为 1）。
            let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)

            // 去抖 ②：亚像素过滤。手指近乎静止时不触发重排；
            //          因为位移始终相对基点计算，所以不会像增量式实现那样丢失位移。
            guard abs(delta.x) > Self.dragEpsilon || abs(delta.y) > Self.dragEpsilon else { return }

            worldTransform = base.applyingWorldDelta(.worldTranslation(delta))
            applyWorldTransform()
            onTransformChanged?(self)
        case .ended, .cancelled, .failed:
            // 先复位再回调：容器会在 onEndMove 里补做延迟的“置顶重挂载”。
            isMoving = false
            gestureBase = nil
            gestureStartPoint = nil
            hasLeftDeadZone = false
            onEndMove?(self)"""
        ),
    ],
)

# 3) 四处变换统一到实测语义
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        (
            """        let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: scaleX, sy: scaleY)
        let worldDelta = base.concatenating(localDelta).concatenating(baseInverse)
        entity.update(transform: worldDelta.concatenating(base))
        refreshSelectionOverlay()""",
            """        // 缩放定义在图元**局部**坐标系、锚点为局部角点：
        // 正确写法是「局部 delta → 再 base」，实测可保证锚点不动且被拖角精确跟随手指。
        let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: scaleX, sy: scaleY)
        entity.update(transform: base.applyingLocalDelta(localDelta))
        refreshSelectionOverlay()"""
        ),
        (
            """        let delta = CGAffineTransform.worldRotation(center: center, angle: snapped.angle - baseRotation)
        entity.update(transform: delta.concatenating(base))
        refreshSelectionOverlay()""",
            """        // 旋转定义在**世界**坐标系（绕世界中心）→ 先 base 后 delta。
        let delta = CGAffineTransform.worldRotation(center: center, angle: snapped.angle - baseRotation)
        entity.update(transform: base.applyingWorldDelta(delta))
        refreshSelectionOverlay()"""
        ),
        (
            """        let translation = CGAffineTransform(translationX: base.natural.width * (newCrop.origin.x - base.crop.origin.x),
                                            y: base.natural.height * (newCrop.origin.y - base.crop.origin.y))
        entity.update(cropRect: newCrop, worldTransform: translation.concatenating(base.transform))""",
            """        // 裁剪平移发生在**原图局部**坐标系（新视窗原点相对基准视窗的偏移）→ 先 delta 后 base。
        let translation = CGAffineTransform(translationX: base.natural.width * (newCrop.origin.x - base.crop.origin.x),
                                            y: base.natural.height * (newCrop.origin.y - base.crop.origin.y))
        entity.update(cropRect: newCrop, worldTransform: base.transform.applyingLocalDelta(translation))"""
        ),
        (
            """    private func applyGroupDelta(_ delta: CGAffineTransform) {
        groupAccumulatedDelta = delta
        isGroupTransforming = true
        for (id, base) in groupBaseTransforms {
            entity(for: id)?.update(transform: delta.concatenating(base))
        }
        floatingPreview?.transform = delta
        refreshSelectionOverlay()
    }""",
            """    private func applyGroupDelta(_ delta: CGAffineTransform) {
        groupAccumulatedDelta = delta
        isGroupTransforming = true
        for (id, base) in groupBaseTransforms {
            // 整体变换是世界坐标系的 delta（组锚点不动）→ 先 base 后 delta。
            entity(for: id)?.update(transform: base.applyingWorldDelta(delta))
        }
        if let preview = floatingPreview {
            // UIView.transform 绕自身中心施加，需共轭校正才能等价于世界 delta，
            // 否则“浮动笔迹预览”会与最终落盘的笔迹错位。
            preview.transform = delta.viewConjugate(aboutCenter: preview.center)
        }
        refreshSelectionOverlay()
    }"""
        ),
    ],
)

print("done")
