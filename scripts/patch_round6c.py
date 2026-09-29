#!/usr/bin/env python3
"""Round-6 patch C: 选区覆盖层 —— 手柄判定补正、复合选区内部拖动、菜单避让、变形文案。"""
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
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        # 委托新增「内部拖动」
        (
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint])
}""",
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint])
    /// 复合选区内拖动：整体平移。
    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragInterior point: CGPoint,
                          state: UIGestureRecognizer.State)
}"""
        ),
        # 内部拖动识别器
        (
            """        addInteraction(editMenu)
    }""",
            """        addInteraction(editMenu)
        addGestureRecognizer(interiorPan)
    }

    /// 复合选区内部拖动 = 整体平移。
    private lazy var interiorPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleInteriorPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        return pan
    }()

    @objc private func handleInteriorPan(_ gesture: UIPanGestureRecognizer) {
        guard isInteriorDraggable else { return }
        delegate?.selectionOverlay(self, didDragInterior: gesture.location(in: self), state: gesture.state)
    }

    /// 复合选区（纯笔迹 / 笔迹+贴图）内部可整体拖动。
    /// 单图与裁剪态不接管内部：那两种状态由贴图自身的手势负责移动。
    var isInteriorDraggable: Bool {
        switch mode {
        case .composite, .compositeTransform: return true
        default: return false
        }
    }

    /// 复合选区的世界包围盒。
    private var compositeRect: CGRect? {
        switch mode {
        case .composite(let rect), .compositeTransform(let rect): return rect
        default: return nil
        }
    }"""
        ),
        # 命中判定：内部也算「命中选区自身」
        (
            """    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isLassoActive { return true }
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: event) { return true }
        }
        return false
    }""",
            """    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isLassoActive { return true }
        if hitsInteractiveElement(point) { return true }
        // 复合选区内部同样属于「选区自身」：用于整体拖动，也用于避免误清选区。
        if let rect = compositeRect, rect.insetBy(dx: -8, dy: -8).contains(point) { return true }
        return false
    }"""
        ),
        (
            """    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }""",
            """    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        if let rect = compositeRect, rect.insetBy(dx: -8, dy: -8).contains(point) { return true }
        return false
    }"""
        ),
        # 菜单避让：加大与选区的间距，避免压住手柄
        (
            """    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        let gap = 22 * scale""",
            """    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        // 间距刻意放大：菜单必须完全避开选区边缘的缩放/旋转手柄。
        let gap = 46 * scale"""
        ),
        # 手柄命中补正
        (
            """/// 单个控制手柄：白色实心 + 蓝色描边 + 可选图形。
@MainActor
final class SelectionHandleView: UIView {
    let kind: SelectionHandleKind
    let baseSize: CGSize""",
            """/// 单个控制手柄：白色实心 + 蓝色描边 + 可选图形。
/// 视觉尺寸保持精致，但命中区域按 HIG 补正到 44pt —— 解决“控制点很难点到”。
@MainActor
final class SelectionHandleView: UIView {
    /// 最小可点边长（屏幕 pt，等价于本视图 bounds 单位：手柄做了 1/zoom 反向缩放）。
    static let minimumHitSize: CGFloat = 44

    let kind: SelectionHandleKind
    let baseSize: CGSize

    /// 判定补正：视觉 16pt 的手柄拥有 44pt 的可点范围。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.minimumHitSize - bounds.width) / 2)
        let dy = max(0, (Self.minimumHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }"""
        ),
    ],
)

# 菜单文案：「缩放变形」→「变形」
patch(
    "SeeingCalendar/Canvas/CanvasValueTypes.swift",
    [
        (
            """        case .transform: return "缩放变形\"""",
            """        case .transform: return "变形\""""
        ),
    ],
)

print("done")
