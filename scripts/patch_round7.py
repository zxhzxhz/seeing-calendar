#!/usr/bin/env python3
"""Round-7 patch: 菜单避让 + 变形以整体区域中心为基准 + 手柄命中最近优先。"""
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


# ── 1. 覆盖层：裁剪/变形态不再用浮动菜单（改底部工具条）；图片菜单锚点移到下边中点并加大间距；
#      手柄命中"最近优先"，解决小图上 44pt 判定区互相重叠导致点错手柄。
patch(
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        (
            """    private func menuActions(for mode: Mode) -> [SelectionAction] {
        switch mode {
        case .none:
            return []
        case .composite:
            return [.copy, .cut, .delete, .transform]
        case .compositeTransform:
            return [.finishTransform]
        case .image:
            return [.copy, .crop, .replace, .bringToFront, .sendToBack, .delete]
        case .cropping:
            return [.finishCrop, .cancelCrop]
        }
    }""",
            """    /// 浮动菜单只用于「对象级」动作。
    /// 裁剪与变形是**模式级**动作，放在编辑器底部工具条 —— 避免菜单压住正在使用的手柄
    /// （这正是「裁剪控制点第一次拖动会停住」的真实原因：第一次点到了菜单，菜单随即收起，第二次才点到手柄）。
    private func menuActions(for mode: Mode) -> [SelectionAction] {
        switch mode {
        case .none, .cropping, .compositeTransform:
            return []
        case .composite:
            return [.copy, .cut, .delete, .transform]
        case .image:
            return [.copy, .crop, .replace, .bringToFront, .sendToBack, .delete]
        }
    }"""
        ),
        (
            """    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        // 间距刻意放大：菜单必须完全避开选区边缘的缩放/旋转手柄。
        let gap = 46 * scale
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.maxY + gap)
        case .image(let quad), .cropping(let quad):
            guard let lowest = quad.max(by: { $0.y < $1.y }) else { return nil }
            return CGPoint(x: lowest.x, y: lowest.y + gap)
        }
    }""",
            """    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        // 间距 = 手柄命中半径(22) + 菜单半高(≈25) + 余量 → 确保菜单完全不压手柄。
        let gap = 60 * scale
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.maxY + gap)
        case .image(let quad), .cropping(let quad):
            guard let lowest = quad.max(by: { $0.y < $1.y }) else { return nil }
            // 关键：用**下边中点**而不是最下方那个角点 —— 角点即右下角，
            // 系统以锚点为中心弹出菜单，菜单会直接盖住右下角缩放手柄与底部中点裁剪手柄。
            let bottomCenterX = quad.map(\\.x).reduce(0, +) / CGFloat(quad.count)
            return CGPoint(x: bottomCenterX, y: lowest.y + gap)
        }
    }"""
        ),
        (
            """    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() where !subview.isHidden && subview.alpha > 0.01 {
            let local = convert(point, to: subview)
            guard subview.point(inside: local, with: event) else { continue }
            if let hit = subview.hitTest(local, with: event) { return hit }
        }
        return isLassoActive ? self : nil
    }""",
            """    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 手柄的 44pt 判定区在小图上会互相重叠，此时必须按「离哪个手柄中心最近」来裁决，
        // 否则会点到相邻手柄（表现为“拖角手柄却只动了一个边”）。
        var nearestHandle: (view: SelectionHandleView, distance: CGFloat)?
        for subview in subviews.reversed() where !subview.isHidden && subview.alpha > 0.01 {
            let local = convert(point, to: subview)
            guard subview.point(inside: local, with: event) else { continue }
            if let handle = subview as? SelectionHandleView {
                let distance = hypot(local.x - handle.bounds.midX, local.y - handle.bounds.midY)
                if nearestHandle == nil || distance < nearestHandle!.distance {
                    nearestHandle = (handle, distance)
                }
                continue
            }
            if let hit = subview.hitTest(local, with: event) { return hit }
        }
        if let nearestHandle { return nearestHandle.view }
        return isLassoActive ? self : nil
    }"""
        ),
    ],
)

# ── 2. 容器：抽出 perform(action)，供底部工具条复用；整体变形改为「以选区中心为基准的等比缩放」
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        (
            """    private func applyGroupScale(index: Int, point: CGPoint) {
        let base = groupBaseBounds
        guard !base.isNull else { return }
        let corners = CanvasGeometry.corners(of: base)
        var anchor: CGPoint
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1

        if index < 4 {
            anchor = corners[(index + 2) % 4]
            let corner = corners[index]
            let vectorX = corner.x - anchor.x
            let vectorY = corner.y - anchor.y
            let hasX = abs(vectorX) > 1
            let hasY = abs(vectorY) > 1
            let candidateX = hasX ? max(0.05, (point.x - anchor.x) / vectorX) : 1
            let candidateY = hasY ? max(0.05, (point.y - anchor.y) / vectorY) : 1
            let uniform = abs(vectorX) >= abs(vectorY) ? candidateX : candidateY
            scaleX = uniform
            scaleY = uniform
        } else {
            switch index {
            case 4:
                anchor = CanvasGeometry.midpoint(corners[3], corners[2])
                scaleY = max(0.05, (anchor.y - point.y) / max(1, base.height))
            case 5:
                anchor = CanvasGeometry.midpoint(corners[0], corners[3])
                scaleX = max(0.05, (point.x - anchor.x) / max(1, base.width))
            case 6:
                anchor = CanvasGeometry.midpoint(corners[0], corners[1])
                scaleY = max(0.05, (point.y - anchor.y) / max(1, base.height))
            default:
                anchor = CanvasGeometry.midpoint(corners[1], corners[2])
                scaleX = max(0.05, (anchor.x - point.x) / max(1, base.width))
            }
        }

        applyGroupDelta(CGAffineTransform.worldScale(anchor: anchor, sx: scaleX, sy: scaleY))
    }""",
            """    /// 手柄在世界坐标下的原始位置（以给定矩形为准，与覆盖层的排布规则保持一致）。
    private func groupHandlePoint(_ index: Int, in rect: CGRect) -> CGPoint {
        let corners = CanvasGeometry.corners(of: rect)
        if index < 4 { return corners[index] }
        let edges = [CanvasGeometry.midpoint(corners[0], corners[1]),
                     CanvasGeometry.midpoint(corners[1], corners[2]),
                     CanvasGeometry.midpoint(corners[2], corners[3]),
                     CanvasGeometry.midpoint(corners[3], corners[0])]
        let edgeIndex = min(max(index - 4, 0), edges.count - 1)
        return edges[edgeIndex]
    }

    /// 整体缩放：**以套索确定的整体选中区域中心为不动点**，等比缩放，
    /// 手柄只决定缩放比例（把手指位移投影到「中心 → 手柄」这条轴上），行为与贴图缩放一致。
    private func applyGroupScale(index: Int, point: CGPoint) {
        let base = groupBaseBounds
        guard !base.isNull else { return }
        let center = CGPoint(x: base.midX, y: base.midY)
        let origin = groupHandlePoint(index, in: base)
        let axis = CGPoint(x: origin.x - center.x, y: origin.y - center.y)
        let lengthSquared = axis.x * axis.x + axis.y * axis.y
        guard lengthSquared > 1 else { return }

        let delta = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let ratio = (delta.x * axis.x + delta.y * axis.y) / lengthSquared
        let uniform = max(0.05, ratio)

        applyGroupDelta(CGAffineTransform.worldScale(anchor: center, sx: uniform, sy: uniform))
    }"""
        ),
        (
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        // 原生菜单退场可能把触摸透传到画布，这里登记 0.35s 保护窗口，
        // 避免刚建立的选择状态被「点空白取消选中」立刻清掉。
        menuActionGuardUntil = Date().addingTimeInterval(0.35)
        switch action {""",
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        perform(action)
    }

    /// 选区动作总入口：浮动菜单与编辑器底部工具条共用同一条实现。
    func perform(_ action: SelectionAction) {
        // 原生菜单退场可能把触摸透传到画布，这里登记 0.35s 保护窗口，
        // 避免刚建立的选择状态被「点空白取消选中」立刻清掉。
        menuActionGuardUntil = Date().addingTimeInterval(0.35)
        switch action {"""
        ),
    ],
)

print("done")
