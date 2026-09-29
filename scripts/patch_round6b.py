#!/usr/bin/env python3
"""Round-6 patch B: 容器接入触摸轨迹与橡皮指示圈；选区覆盖层：手柄判定补正 + 内部拖动平移 + 菜单间距。"""
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
    "SeeingCalendar/Canvas/CompositeCanvasContainerView.swift",
    [
        (
            """    let canvasView = PKCanvasView()""",
            """    let canvasView = TrackingCanvasView()"""
        ),
        (
            """    let selectionTopContainerView = UIView()
    let selectionOverlay = SelectionOverlayView()""",
            """    let selectionTopContainerView = UIView()
    let eraserIndicator = EraserIndicatorView()
    let selectionOverlay = SelectionOverlayView()""",
        ),
        (
            """        imageFrontContainerView.backgroundColor = .clear
        addSubview(imageFrontContainerView)""",
            """        imageFrontContainerView.backgroundColor = .clear
        addSubview(imageFrontContainerView)

        addSubview(eraserIndicator)
        canvasView.onTouchPoint = { [weak self] point in
            guard let self else { return }
            // 仅在橡皮激活时显示有效范围圈；其余工具下彻底隐藏。
            self.eraserIndicator.isHidden = !self.isEraserActive
            self.eraserIndicator.update(point: self.isEraserActive ? point : nil)
        }""",
        ),
        (
            """    var overlayScale: CGFloat = 1 {
        didSet { selectionOverlay.contentScale = overlayScale }
    }""",
            """    var overlayScale: CGFloat = 1 {
        didSet {
            selectionOverlay.contentScale = overlayScale
            eraserIndicator.contentScale = overlayScale
        }
    }

    /// 橡皮是否处于激活状态（决定是否显示有效范围圈）。
    var isEraserActive: Bool = false {
        didSet {
            eraserIndicator.isHidden = !isEraserActive
            if !isEraserActive { eraserIndicator.update(point: nil) }
        }
    }

    /// 橡皮有效范围（画布世界坐标下的直径，与 PKEraserTool.width 保持一致）。
    var eraserWidth: CGFloat = 24 {
        didSet { eraserIndicator.eraserWidth = eraserWidth }
    }""",
        ),
        (
            """        imageFrontContainerView.frame = CGRect(origin: .zero, size: size)
        selectionContentContainer.frame = CGRect(origin: .zero, size: size)""",
            """        imageFrontContainerView.frame = CGRect(origin: .zero, size: size)
        eraserIndicator.frame = CGRect(origin: .zero, size: size)
        selectionContentContainer.frame = CGRect(origin: .zero, size: size)"""
        ),
        (
            """        // 落在选区手柄 / 原生菜单上：不参与“点空白取消选择”
        if selectionOverlay.hitsInteractiveElement(point) { return }""",
            """        // 刚从原生菜单点选动作后的一小段时间内忽略画布点击：
        // 菜单退场时可能把触摸透传下来，否则会立刻把刚建立的选择清掉（表现为“变形点了没反应”）。
        if Date() < menuActionGuardUntil { return }

        // 落在选区手柄 / 原生菜单上：不参与“点空白取消选择”
        if selectionOverlay.hitsInteractiveElement(point) { return }""",
        ),
        (
            """    private var isProgrammatic = false
    private var isToolSessionActive = false""",
            """    private var isProgrammatic = false
    private var isToolSessionActive = false
    /// 原生菜单动作后的点击保护窗口。
    var menuActionGuardUntil: Date = .distantPast"""
        ),
    ],
)

patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        # 菜单动作：登记保护窗口
        (
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        switch action {""",
            """    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        // 原生菜单退场可能把触摸透传到画布，这里登记 0.35s 保护窗口，
        // 避免刚建立的选择状态被「点空白取消选中」立刻清掉。
        menuActionGuardUntil = Date().addingTimeInterval(0.35)
        switch action {"""
        ),
        # 内部拖动平移：整套复用 group delta 机制
        (
            """    // MARK: - 套索

    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint]) {""",
            """    // MARK: - 选区内部拖动（整体平移）

    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragInterior point: CGPoint,
                          state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            isAdjustingSelection = true
            selectionOverlay.dismissMenu()
            groupBaseBounds = selectionBounds()
            groupBaseTransforms = imageViews.reduce(into: [:]) { partial, view in
                if selectedImageIDs.contains(view.itemID) { partial[view.itemID] = view.worldTransform }
            }
            gestureBasePoint = point
            pushHistory()
        case .changed:
            let delta = CGPoint(x: point.x - gestureBasePoint.x, y: point.y - gestureBasePoint.y)
            applyGroupDelta(CGAffineTransform.worldTranslation(delta))
        case .ended, .cancelled, .failed:
            isAdjustingSelection = false
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            groupBaseTransforms = [:]
            notifySelection()
            onContentChange?()
        default:
            break
        }
    }

    // MARK: - 套索

    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint]) {"""
        ),
    ],
)

print("done")
