#!/usr/bin/env python3
"""Round-12 patch: 变形态在缩放/旋转后保持；点框内保持变形态并弹菜单、点框外退出。

用户定义的退出语义：
- 一次缩放/旋转后 → **保持**变形态（可连续操作）
- 单点选区框内 → 保持变形态 + **弹出编辑菜单**
- 单点选区框外 → 退出变形态并收起菜单
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


# A) 手势结束不再清掉变形态
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        (
            """    private func endHandleGesture(_ kind: SelectionHandleKind) {
        isAdjustingSelection = false
        switch kind {
        case .imageCorner, .imageRotate:
            isGroupTransforming = false
            cropBase = nil
        case .imageEdge:
            // 保持裁剪态，等待用户点“完成裁剪”；下次手势会重新采集基准。
            cropBase = nil
        case .groupCorner, .groupRotate:
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            isGroupTransforming = false
            groupBaseTransforms = [:]
        }""",
            """    private func endHandleGesture(_ kind: SelectionHandleKind) {
        isAdjustingSelection = false
        switch kind {
        case .imageCorner, .imageRotate:
            // 单图态本身不是"模式"，无需处理变形态标志。
            cropBase = nil
        case .imageEdge:
            // 保持裁剪态，等待用户点“完成裁剪”；下次手势会重新采集基准。
            cropBase = nil
        case .groupCorner, .groupRotate:
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            groupBaseTransforms = [:]
            // 注意：这里**不清除** isGroupTransforming —— 变形态是"模式"，
            // 退出只能由用户动作触发（点选区内保持并弹菜单 / 点选区外退出 / 点"完成变形"）。
            // 此前在每次缩放/旋转结束时清除，导致"做一次操作就掉出变形态"。
        }"""
        ),
    ],
)

# B) 覆盖层：变形态/裁剪态不自动弹菜单，但应能被动弹出；containsSelection 覆盖单图/裁剪
patch(
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        (
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
    }""",
            """    /// 各形态的可用动作。
    /// 裁剪/变形是**模式级**动作，除了自身动作外也提供对象级动作，
    /// 但它们**进入时不会自动弹菜单**（见 autoPresentsMenu），只有用户点按选区内部才弹
    /// —— 这样既不会在进入模式时遮挡手柄，又能满足"点框内弹出编辑菜单"的交互约定。
    private func menuActions(for mode: Mode) -> [SelectionAction] {
        switch mode {
        case .none:
            return []
        case .composite:
            return [.copy, .cut, .delete, .transform]
        case .compositeTransform:
            return [.copy, .cut, .delete, .finishTransform]
        case .cropping:
            return [.finishCrop, .cancelCrop]
        case .image:
            return [.copy, .crop, .replace, .bringToFront, .sendToBack, .delete]
        }
    }

    /// 进入该形态时是否**自动**弹菜单。
    /// 变形/裁剪属模式级操作，进入即弹会压住手柄（历史 bug），故不自动弹。
    private var autoPresentsMenu: Bool {
        switch mode {
        case .compositeTransform, .cropping: return false
        default: return true
        }
    }""",
        ),
        (
            """    /// 该点是否落在当前选区（复合选区包围盒）内部。
    /// 用于：选区内部的点击不取消选中（取消选中只发生在点选区之外时）。
    func containsSelection(_ point: CGPoint) -> Bool {
        guard let rect = compositeRect else { return false }
        return rect.insetBy(dx: -8, dy: -8).contains(point)
    }""",
            """    /// 该点是否落在当前选区内部（复合框 / 单图框 / 裁剪框）。
    /// 用于：选区内点击保持选中与模式（取消选中只发生在点选区之外时）。
    func containsSelection(_ point: CGPoint) -> Bool {
        let rect: CGRect?
        switch mode {
        case .none:
            rect = nil
        case .composite(let box), .compositeTransform(let box):
            rect = box
        case .image(let quad), .cropping(let quad):
            let box = CanvasGeometry.boundingBox(quad)
            rect = box.isNull ? nil : box
        }
        guard let rect else { return false }
        return rect.insetBy(dx: -8, dy: -8).contains(point)
    }"""
        ),
        (
            """    /// 重新弹出菜单（用户再次点按选区时使用）。
    func presentMenu() {
        guard !menuActions.isEmpty else { return }
        lastPresentedTag = -1
        syncEditMenu(force: true)
    }""",
            """    /// 用户主动唤出菜单（点按选区内部时调用）。
    /// 与「进入形态时自动弹」分离：变形/裁剪态进入不自动弹，但这里一定会弹。
    func presentMenu() {
        guard !menuActions.isEmpty, let anchor = menuAnchorPoint() else { return }
        lastPresentedTag = mode.shapeTag
        menuGeneration &+= 1
        let generation = menuGeneration
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor)
        editMenu.dismissMenu()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.menuGeneration == generation else { return }
            self.editMenu.presentEditMenu(with: configuration)
        }
    }"""
        ),
        (
            """    private func syncEditMenu(force: Bool) {
        guard !menuActions.isEmpty, let anchor = menuAnchorPoint() else {
            dismissMenu()
            return
        }
        let tag = mode.shapeTag""",
            """    private func syncEditMenu(force: Bool) {
        guard !menuActions.isEmpty, autoPresentsMenu, let anchor = menuAnchorPoint() else {
            dismissMenu()
            return
        }
        let tag = mode.shapeTag"""
        ),
    ],
)

# C) 容器点击分发：变形态 / 裁剪态下点框内 → 保持模式 + 弹菜单（不改选对象）
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainerView.swift",
    [
        (
            """        // 2) 点在贴图上：无论当前处于套索态还是变形态，都应能选中该贴图。
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
        }""",
            """        // 2) 点在贴图上 → 选中该贴图。
        //    - 变形态下**不改选对象**：用户约定"点框内保持变形态并弹菜单"；
        //    - 裁剪态下同样不改选，避免误触退出裁剪；
        //    - 套索态（非变形态）下触摸会被内部拖动区/套索层接管，贴图自身手势收不到事件，
        //      因此由容器代劳选中并弹菜单。
        if !isGroupTransforming, croppingImageID == nil {
            for entity in imageViews.reversed() where !entity.isHidden && entity.alpha > 0.01 {
                if entity.bounds.contains(entity.convert(point, from: self)) {
                    selectImage(id: entity.itemID, additive: false)
                    selectionOverlay.presentMenu()
                    return
                }
            }
        }

        // 3) 点在选区内（非手柄）：保持选中与当前模式，并弹出编辑菜单
        if selectionOverlay.containsSelection(point) {
            selectionOverlay.presentMenu()
            return
        }"""
        ),
    ],
)

print("done")
