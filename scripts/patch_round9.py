#!/usr/bin/env python3
"""Round-9 patch:
A) 修正 viewConjugate 的共轭方向（UIView 绕 center 施加：effective = T(c)·x·T(-c)）；
B) hitTest 中手柄必须胜过内部拖动区（此前 continue 让底层把触摸抢走 → “只有右下角手柄有作用”）；
C) 点按选区内 → 重新弹出菜单；点在贴图上 → 选中贴图（此前被"保持选中"分支吞掉）。
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


# A) 共轭方向修正
patch(
    "SeeingCalendar/Canvas/CanvasGeometry.swift",
    [
        (
            """    /// 让 `UIView.transform` 在父视图坐标系下等价于世界变换 `delta`
    /// （UIView 的 transform 是以视图中心为原点施加的，需做一次共轭校正）。
    func viewConjugate(aboutCenter center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(self)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }""",
            """    /// 让 `UIView.transform` 在父视图坐标系下等价于世界变换 `delta`。
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
    }""",
        )
    ],
)

# B) + C) 覆盖层：手柄优先 + 菜单重弹入口 + 手柄/菜单判定与内部区分离
patch(
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        (
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
    }""",
            """    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 手柄的 44pt 判定区在小图上会互相重叠，此时必须按「离哪个手柄中心最近」来裁决。
        // 关键：手柄必须**立即胜出**，不能被下层的内部拖动区接管
        // （此前先收集手柄再继续扫描，底层 interiorView 会把触摸抢走 → 表现为「只有右下角手柄有作用」）。
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
            if let nearestHandle { return nearestHandle.view }
            if let hit = subview.hitTest(local, with: event) { return hit }
        }
        if let nearestHandle { return nearestHandle.view }
        return isLassoActive ? self : nil
    }"""
        ),
        (
            """    /// 命中测试：仅判定「手柄 / 菜单 / 内部拖动区」等真实交互元素。
    /// 供容器判断「这次点击是否应取消选区」。
    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }""",
            """    /// 命中测试：仅判定「手柄 / 菜单 / 内部拖动区」等真实交互元素。
    /// 供容器判断「这次点击是否应取消选区」。
    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }

    /// 只判定手柄/菜单（**不含**内部拖动区）：用于区分「点在手柄上」与「点在选区内」。
    func hitsHandleOrMenu(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 && subview !== interiorView {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }

    /// 重新弹出菜单（用户再次点按选区时使用）。
    func presentMenu() {
        guard !menuActions.isEmpty else { return }
        lastPresentedTag = -1
        syncEditMenu(force: true)
    }"""
        ),
    ],
)

# C) 容器点击分发：贴图优先 → 选区内重弹菜单 → 否则取消选中
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainerView.swift",
    [
        (
            """        // 落在选区手柄 / 原生菜单 / 内部拖动区：不参与“点空白取消选择”
        if selectionOverlay.hitsInteractiveElement(point) { return }
        // 落在选区内部：同样保持选中（取消选中只发生在点选区之外时）
        if selectionOverlay.containsSelection(point) { return }

        // 落在贴图上：交给贴图自身的点选逻辑
        for entity in imageViews.reversed() where !entity.isHidden && entity.alpha > 0.01 {
            if entity.bounds.contains(entity.convert(point, from: self)) { return }
        }
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            clearSelection()
        }""",
            """        // 1) 手柄 / 浮动菜单：交给它们自己处理
        if selectionOverlay.hitsHandleOrMenu(point) { return }

        // 2) 点在贴图上：无论当前处于套索态还是变形态，都应能选中该贴图。
        //    （变形态下触摸会被"内部拖动区"接管，贴图自身的点按手势收不到事件，
        //      因此这里由容器代劳选中，并重新弹出菜单。）
        for entity in imageViews.reversed() where !entity.isHidden && entity.alpha > 0.01 {
            if entity.bounds.contains(entity.convert(point, from: self)) {
                selectImage(id: entity.itemID, additive: false)
                selectionOverlay.presentMenu()
                return
            }
        }

        // 3) 点在选区内（非贴图、非手柄）：保持选中并重新弹出菜单
        if selectionOverlay.containsSelection(point) {
            selectionOverlay.presentMenu()
            return
        }

        // 4) 点在选区之外：取消选中
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            clearSelection()
        }"""
        ),
    ],
)

print("done")
