#!/usr/bin/env python3
"""Round-16: 交互式下拉返回按区域门控。

需求：仅在「可绘画区域（画布视口）」禁用下拉返回手势，其余区域（页条 / 工具栏 / 上下留白外的 chrome）仍可触发；
     例外：贴图编辑态下拖动/裁剪/缩放在画布外继续时，仍优先进行图片操作（不能被消失手势抢走）。

实现：
  1. CanvasHostView 挂「零时长长按」观察器（允许共存），上报触摸是否落在画布视口内；
  2. 容器上报选区手势是否进行中（isAdjustingSelection）；
  3. 二者合成 isCanvasInteractionActive → DayEditorView 用 .interactiveDismissDisabled 动态门控；
  4. 顺带让容器可命中画布矩形之外的区域（point(inside:) 放行），
     这样被拖到画布外的贴图依然可点选/拖动（"例外情况"才真正可达）。
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


# ── 1. CanvasHostView：上报画布视口内的触摸活动
patch(
    "SeeingCalendar/Canvas/CanvasHostView.swift",
    [
        (
            """    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?""",
            """    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?

    /// 画布视口内是否有触摸处于按下状态。
    /// 用于按区域门控「交互式下拉返回」：画布内禁止、画布外（页条/工具栏）放行。
    var onTouchActive: ((Bool) -> Void)?

    private lazy var touchObserver: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchObserver(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    @objc private func handleTouchObserver(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            onTouchActive?(true)
        case .ended, .cancelled, .failed:
            onTouchActive?(false)
        default:
            break
        }
    }"""
        ),
        (
            """        canvas.frame = CGRect(origin: .zero, size: CompositeCanvasContainerView.canvasSize)
        scrollView.addSubview(canvas)
    }""",
            """        canvas.frame = CGRect(origin: .zero, size: CompositeCanvasContainerView.canvasSize)
        scrollView.addSubview(canvas)

        addGestureRecognizer(touchObserver)
    }"""
        ),
        (
            """    /// 导航态（取消全部工具 / 笔画）：禁止落笔，单指即可平移，双指缩放。""",
            """    /// 与画布内的绘制/手势共存：只观察，不抢。
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// 导航态（取消全部工具 / 笔画）：禁止落笔，单指即可平移，双指缩放。"""
        ),
        (
            """@MainActor
final class CanvasHostView: UIView, UIScrollViewDelegate {""",
            """@MainActor
final class CanvasHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {"""
        ),
    ],
)

# ── 2. 容器：上报选区手势状态 + 允许命中画布矩形之外（被拖到画布外的贴图仍可操作）
patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainerView.swift",
    [
        (
            """    /// 任何「正在拖拽选区」的状态（手柄 / 贴图位移 / 整体变换）——
    /// 期间只做几何更新，绝不重建手柄，也绝不重弹菜单。
    var isAdjustingSelection = false""",
            """    /// 任何「正在拖拽选区」的状态（手柄 / 贴图位移 / 整体变换）——
    /// 期间只做几何更新，绝不重建手柄，也绝不重弹菜单。
    var isAdjustingSelection = false {
        didSet {
            guard oldValue != isAdjustingSelection else { return }
            onAdjustingSelectionChanged?(isAdjustingSelection)
        }
    }

    /// 选区手势状态回调：用于在图片操作期间锁住「交互式下拉返回」。
    var onAdjustingSelectionChanged: ((Bool) -> Void)?"""
        ),
        (
            """    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }""",
            """    /// 允许在画布矩形之外参与命中测试：
    /// 贴图可以被拖出 1400×1400 画布之外（视口留白处仍会绘制），
    /// 若不放行 `point(inside:)`，这些贴图就会"看得见、摸不着"，也无法保证图片操作优先于消失手势。
    /// 命中失败时返回 nil，事件照旧落到外层滚动视图（双指平移缩放不受影响）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }"""
        ),
    ],
)

# ── 3. EditorModel：合成「画布交互中」
patch(
    "SeeingCalendar/Views/EditorModel.swift",
    [
        (
            """    var hasClipboard = false
    var isCanvasExpanded = false""",
            """    var hasClipboard = false
    var isCanvasExpanded = false
    /// 画布视口内是否有触摸按下（由 CanvasHostView 上报）。
    var isCanvasTouchActive = false
    /// 是否有选区手势进行中（拖动/裁剪/缩放，由容器上报）。
    var isSelectionGestureActive = false""",
        ),
        (
            """        host.onZoomChange = { [weak self] scale, fit in""",
            """        host.onTouchActive = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                if self.isCanvasTouchActive != active {
                    self.isCanvasTouchActive = active
                }
            }
        }
        host.canvas.onAdjustingSelectionChanged = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                if self.isSelectionGestureActive != active {
                    self.isSelectionGestureActive = active
                }
            }
        }
        host.onZoomChange = { [weak self] scale, fit in"""
        ),
        (
            """    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { activeTool == nil }""",
            """    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { activeTool == nil }

    /// 画布是否正在被操作（画布视口内按下，或选区手势进行中）。
    /// 据此按区域门控「交互式下拉返回」：画布内禁止，页条/工具栏等区域放行。
    var isCanvasInteractionActive: Bool {
        isCanvasTouchActive || isSelectionGestureActive
    }"""
        ),
    ],
)

# ── 4. 呈现层：门控从「一律禁用」改为「按区域动态禁用」
patch(
    "SeeingCalendar/Views/RootView.swift",
    [
        (
            """                .navigationTransition(.zoom(sourceID: request.sourceID, in: zoomNamespace))
                // 画布是创作态：禁用交互式"下拉返回主页面"手势，
                // 否则在画布上拖动（尤其从顶部附近起手）会被系统当作消失手势。
                .interactiveDismissDisabled(true)
        }""",
            """                .navigationTransition(.zoom(sourceID: request.sourceID, in: zoomNamespace))
        }"""
        ),
    ],
)

patch(
    "SeeingCalendar/Views/DayEditorView.swift",
    [
        (
            """            .toolbar { toolbarContent(model: model) }
            .onChange(of: model.isFingerDrawingEnabled) { _, newValue in
                onFingerDrawingChanged(newValue)
            }
            .onDisappear { model.finishEditing() }""",
            """            .toolbar { toolbarContent(model: model) }
            // 交互式下拉返回：**仅在画布视口内**禁用（含图片操作进行中）。
            // 页条 / 工具栏 / 顶部导航等区域照常可下拉返回主页面。
            .interactiveDismissDisabled(model.isCanvasInteractionActive)
            .onChange(of: model.isFingerDrawingEnabled) { _, newValue in
                onFingerDrawingChanged(newValue)
            }
            .onDisappear { model.finishEditing() }"""
        ),
    ],
)

print("done")
