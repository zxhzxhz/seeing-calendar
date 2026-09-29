#!/usr/bin/env python3
"""Round-11 patch: 笔迹变换改为「只合成 transform，绝不重建 path」——修复带 mask 的笔迹变换后消失。"""
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
            """    func transformStrokes(_ strokes: [PKStroke], by delta: CGAffineTransform) -> [PKStroke] {
        let uniform = max(0.01, sqrt(abs(delta.a * delta.d - delta.b * delta.c)))
        return strokes.compactMap { stroke in
            let count = stroke.path.count
            guard count > 0 else { return nil }
            var points: [PKStrokePoint] = []
            points.reserveCapacity(count)
            for index in 0..<count {
                let point = stroke.path[index]
                let location = point.location.applying(stroke.transform).applying(delta)
                points.append(PKStrokePoint(location: location,
                                            timeOffset: point.timeOffset,
                                            size: CGSize(width: point.size.width * uniform,
                                                         height: point.size.height * uniform),
                                            opacity: point.opacity,
                                            force: point.force,
                                            azimuth: point.azimuth,
                                            altitude: point.altitude))
            }
            return PKStroke(ink: stroke.ink,
                            path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                            transform: .identity,
                            mask: stroke.mask)
        }
    }""",
            """    /// 变换笔迹：**只把 delta 合成到 `stroke.transform`，绝不重建 path**。
    ///
    /// 为什么必须是这种写法（真机 bug + 官方语义双重确认）：
    ///  · 范围擦除（`PKEraserTool.EraserType.bitmap`）不会删除 path 上的点，
    ///    而是给笔迹加上 **mask** 来裁剪渲染 —— WWDC20：
    ///    "Masked strokes are typically created when the pixel eraser is used to erase only a portion
    ///     of a stroke … Masks can have holes. Or they can cut a stroke into multiple pieces."
    ///  · `mask` 是 **pretransform** 空间的（官方文档：The pretransform mask used to clip the
    ///    rendering of the stroke），与 path 同处笔迹局部坐标系。
    ///  ⇒ 若把变换烘焙进 path 控制点却沿用旧 mask，裁剪区就停留在旧位置，
    ///    与新的几何错位 —— 现象正是「被擦断的线在变形/移动/旋转后消失或只剩一小截」。
    ///  · 改为合成 `transform` 后，path 与 mask 作为同一个局部空间被整体变换，天然保持一致；
    ///    而且 `renderBounds` 的文档明确 transform 作用于**渲染结果**（含线宽），
    ///    因此整体缩放时笔迹宽度会按比例自然缩放，无需再手工乘 size。
    ///  · 附带收益：O(1)（不再逐点重建）、零保真损失（PencilKit 的点是"有损压缩存储"，重建会掉精度）。
    func transformStrokes(_ strokes: [PKStroke], by delta: CGAffineTransform) -> [PKStroke] {
        strokes.map { stroke in
            PKStroke(ink: stroke.ink,
                     path: stroke.path,
                     transform: stroke.transform.concatenating(delta),
                     mask: stroke.mask)
        }
    }"""
        ),
    ],
)

print("done")
