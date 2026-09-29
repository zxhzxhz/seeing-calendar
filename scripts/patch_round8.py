#!/usr/bin/env python3
"""Round-8 patch:
1) 选区包围盒必须反映"进行中的变换"（否则拖动时选区框不跟随）；
2) 单图四角缩放改为以图元中心为不动点（与整体变形基准一致）。
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


patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        (
            """    func selectionBounds() -> CGRect {
        var result = CGRect.null
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            let box = CanvasGeometry.boundingBox(entity.worldQuad)
            result = result.isNull ? box : result.union(box)
        }
        if !selectedStrokes.isEmpty {
            let box = strokesBounds(selectedStrokes)
            if !box.isNull { result = result.isNull ? box : result.union(box) }
        }
        return result.isNull ? .zero : result
    }""",
            """    /// 选区包围盒。
    ///
    /// 关键：拖动过程中被选中的**笔迹**只是浮层预览被施加了变换，模型数据要等手指离开才烘焙，
    /// 因此这里必须把「进行中的变换」也计入，否则选区框会停在原地、直到手势结束才\"跳\"过去
    /// （表现为：移动时只有物体动、选区不跟随；结束后才追上来）。
    func selectionBounds() -> CGRect {
        var result = CGRect.null
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            let box = CanvasGeometry.boundingBox(entity.worldQuad)
            result = result.isNull ? box : result.union(box)
        }
        if !selectedStrokes.isEmpty {
            var box = strokesBounds(selectedStrokes)
            if let delta = groupAccumulatedDelta, !box.isNull {
                box = box.applying(delta)   // 视觉上的当前位置
            }
            if !box.isNull { result = result.isNull ? box : result.union(box) }
        }
        return result.isNull ? .zero : result
    }"""
        ),
        (
            """    private func applyImageCornerScale(index: Int, point: CGPoint) {
        guard let id = effectiveImageID,
              let entity = entity(for: id),
              let base = gestureBaseTransform else { return }
        let baseInverse = base.inverted()
        let size = entity.visibleSize
        let localCorners = [CGPoint(x: 0, y: 0),
                            CGPoint(x: size.width, y: 0),
                            CGPoint(x: size.width, y: size.height),
                            CGPoint(x: 0, y: size.height)]
        guard index >= 0, index < localCorners.count else { return }
        let anchorLocal = localCorners[(index + 2) % 4]
        let cornerLocal = localCorners[index]
        let pointLocal = point.applying(baseInverse)

        let vectorX = cornerLocal.x - anchorLocal.x
        let vectorY = cornerLocal.y - anchorLocal.y
        let hasX = abs(vectorX) > 1
        let hasY = abs(vectorY) > 1
        var scaleX: CGFloat = hasX ? max(0.05, (pointLocal.x - anchorLocal.x) / vectorX) : 1
        var scaleY: CGFloat = hasY ? max(0.05, (pointLocal.y - anchorLocal.y) / vectorY) : 1
        // 四角手柄强制等比（spec：拖拽四角圆点默认锁定宽高比）
        if hasX && hasY {
            let uniform = abs(vectorX) >= abs(vectorY) ? scaleX : scaleY
            scaleX = uniform
            scaleY = uniform
        } else if hasX {
            scaleY = scaleX
        } else {
            scaleX = scaleY
        }

        // 缩放定义在图元**局部**坐标系、锚点为局部角点：
        // 正确写法是「局部 delta → 再 base」，实测可保证锚点不动且被拖角精确跟随手指。
        let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: scaleX, sy: scaleY)
        entity.update(transform: base.applyingLocalDelta(localDelta))
        refreshSelectionOverlay()
    }""",
            """    /// 单图四角缩放：**以图元（= 选区）正中心为不动点**等比缩放，与整体变形保持一致。
    /// 缩放比例取手指位移在「中心 → 手柄」轴上的投影比（与整体变形的算法同源）。
    private func applyImageCornerScale(index: Int, point: CGPoint) {
        guard let id = effectiveImageID,
              let entity = entity(for: id),
              let base = gestureBaseTransform else { return }
        let baseInverse = base.inverted()
        let size = entity.visibleSize
        let centerLocal = CGPoint(x: size.width / 2, y: size.height / 2)
        let localCorners = [CGPoint(x: 0, y: 0),
                            CGPoint(x: size.width, y: 0),
                            CGPoint(x: size.width, y: size.height),
                            CGPoint(x: 0, y: size.height)]
        guard index >= 0, index < localCorners.count else { return }
        let cornerLocal = localCorners[index]
        let pointLocal = point.applying(baseInverse)

        let axis = CGPoint(x: cornerLocal.x - centerLocal.x, y: cornerLocal.y - centerLocal.y)
        let lengthSquared = axis.x * axis.x + axis.y * axis.y
        guard lengthSquared > 1 else { return }
        let delta = CGPoint(x: pointLocal.x - centerLocal.x, y: pointLocal.y - centerLocal.y)
        let ratio = (delta.x * axis.x + delta.y * axis.y) / lengthSquared
        let uniform = max(0.05, ratio)

        // 局部坐标系缩放，不动点取局部中心（映射到世界即图元中心）。
        let localDelta = CGAffineTransform.worldScale(anchor: centerLocal, sx: uniform, sy: uniform)
        entity.update(transform: base.applyingLocalDelta(localDelta))
        refreshSelectionOverlay()
    }"""
        ),
    ],
)

print("done")
