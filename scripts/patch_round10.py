#!/usr/bin/env python3
"""Round-10 patch: 工具下发改为幂等签名式同步 + 显式即时应用；编辑器手指开关不再中途回写全局。

根因候选（两条都堵上）：
1) EditorModel 用 `didSet { toolNeedsApply = true }` 驱动工具下发，一旦该副作用未触发
   （@Observable 宏对属性观察器的处理 / SwiftUI 更新回合被打断），切换工具就不下发。
   → 改为「期望状态签名 != 已应用签名」的幂等比较，并在每次改动处**直接调用**同步。
2) 编辑器内切换手指书写会回写 RootView 的 @AppStorage，导致 RootView 重渲染、
   fullScreenCover 内容被重建，打断编辑中的 UIKit 状态。
   → 改为在编辑器关闭时一次性回写。
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
    "SeeingCalendar/Views/EditorModel.swift",
    [
        # 用签名替代标志位
        (
            """    weak var canvasHost: CanvasHostView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toolNeedsApply = true
    @ObservationIgnored private var loadedPageUUID: UUID?""",
            """    weak var canvasHost: CanvasHostView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 已下发的工具指纹：与期望指纹不一致时才重新下发。
    /// 之所以不用「设置-清除标志位」，是因为它依赖属性观察器能否触发；
    /// 幂等比较无论如何都能收敛到正确状态。
    @ObservationIgnored private var appliedToolSignature: String = ""
    @ObservationIgnored private var loadedPageUUID: UUID?"""
        ),
        # 期望指纹 + 幂等下发
        (
            """    func syncUIKitState(of host: CanvasHostView?) {
        guard let host else { return }
        if host.canvas.isFingerDrawingEnabled != isFingerDrawingEnabled {
            host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        }
        if host.canvas.isLassoActive != isLassoActive {
            host.canvas.isLassoActive = isLassoActive
        }
        if toolNeedsApply {
            toolNeedsApply = false
            applyTool(on: host)
        }
    }""",
            """    /// 期望状态指纹：工具类型 + 颜色 + 笔宽 + 橡皮模式/大小 + 套索开关。
    private var toolSignature: String {
        let tool = activeTool?.rawValue ?? "none"
        return "\\(tool)|\\(penColorHex)|\\(penWidth)|\\(eraserMode.rawValue)|\\(eraserWidth)|\\(isLassoActive)"
    }

    func syncUIKitState(of host: CanvasHostView?) {
        guard let host else { return }
        if host.canvas.isFingerDrawingEnabled != isFingerDrawingEnabled {
            host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        }
        if host.canvas.isLassoActive != isLassoActive {
            host.canvas.isLassoActive = isLassoActive
        }
        let signature = toolSignature
        if signature != appliedToolSignature {
            appliedToolSignature = signature
            applyTool(on: host)
        }
    }

    /// 立即下发（不等 SwiftUI 更新回合）。
    func applyToolImmediately() {
        syncUIKitState(of: canvasHost)
    }"""
        ),
        # attach：重置指纹并立即下发一次
        (
            """        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.isLassoActive = isLassoActive
        toolNeedsApply = true""",
            """        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.isLassoActive = isLassoActive
        appliedToolSignature = ""          // 强制首次下发
        syncUIKitState(of: host)"""
        ),
        # 工具/参数改动处即时下发
        (
            """    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥；再次点按当前工具即取消它（进入导航态）。
    func select(tool: CanvasTool) {
        if isLassoActive {
            isLassoActive = false
        }
        activeTool = (activeTool == tool) ? nil : tool
        toolNeedsApply = true
    }""",
            """    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥；再次点按当前工具即取消它（进入导航态）。
    func select(tool: CanvasTool) {
        if isLassoActive {
            isLassoActive = false
        }
        activeTool = (activeTool == tool) ? nil : tool
        applyToolImmediately()
    }

    /// 墨色
    func updatePenColor(_ hex: String) {
        penColorHex = hex
        applyToolImmediately()
    }

    /// 笔宽
    func updatePenWidth(_ width: CGFloat) {
        penWidth = width
        applyToolImmediately()
    }

    /// 橡皮模式（整体擦除 / 范围擦除）
    func updateEraserMode(_ mode: EraserMode) {
        eraserMode = mode
        applyToolImmediately()
    }

    /// 橡皮有效范围
    func updateEraserWidth(_ width: CGFloat) {
        eraserWidth = width
        applyToolImmediately()
    }"""
        ),
        # 手指书写开关：立即下发（不回写全局，由编辑器关闭时统一回写）
        (
            """    var isFingerDrawingEnabled: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }
    var isLassoActive: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }""",
            """    var isFingerDrawingEnabled: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }
    var isLassoActive: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }

    /// 打开编辑器时的全局默认手指书写值（关闭时回写，避免编辑过程中触发外层重渲染）。
    private(set) var fingerDrawingAtLaunch: Bool = false"""
        ),
        (
            """    init(day: DayRecord, workspace: Workspace, context: ModelContext) {
        self.day = day
        self.workspace = workspace
        self.repository = PageRepository(context: context)
        self.note = day.note
        self.pages = day.orderedPages
    }""",
            """    init(day: DayRecord, workspace: Workspace, context: ModelContext) {
        self.day = day
        self.workspace = workspace
        self.repository = PageRepository(context: context)
        self.note = day.note
        self.pages = day.orderedPages
        self.fingerDrawingAtLaunch = false
    }"""
        ),
    ],
)

# 编辑器：手指开关不再 onChange 回写；改为关闭时回写；滑块改用显式 setter
patch(
    "SeeingCalendar/Views/DayEditorView.swift",
    [
        (
            """            .onChange(of: model.isFingerDrawingEnabled) { _, newValue in
                onFingerDrawingChanged(newValue)
            }
            .onDisappear { model.finishEditing() }""",
            """            .onDisappear {
                model.finishEditing()
                // 编辑过程中不回写全局开关（会触发外层重渲染并打断 UIKit 状态），关闭时统一回写。
                onFingerDrawingChanged(model.isFingerDrawingEnabled)
            }"""
        ),
        (
            """            Text("墨色").font(.headline)
            HStack(spacing: 10) {
                ForEach(SubscriptionPalette.colors, id: \\.self) { hex in
                    Button {
                        model.penColorHex = hex
                    } label: {""",
            """            Text("墨色").font(.headline)
            HStack(spacing: 10) {
                ForEach(SubscriptionPalette.colors, id: \\.self) { hex in
                    Button {
                        model.updatePenColor(hex)
                    } label: {"""
        ),
        (
            """            Slider(value: Binding(get: { model.penWidth }, set: { model.penWidth = $0 }), in: 1...28, step: 1)
                .frame(width: 240)""",
            """            Slider(value: Binding(get: { model.penWidth }, set: { model.updatePenWidth($0) }), in: 1...28, step: 1)
                .frame(width: 240)"""
        ),
        (
            """                Button {
                    model.eraserMode = mode
                } label: {""",
            """                Button {
                    model.updateEraserMode(mode)
                } label: {"""
        ),
        (
            """            Slider(value: Binding(get: { model.eraserWidth }, set: { model.eraserWidth = $0 }),
                   in: 8...160,
                   step: 2)""",
            """            Slider(value: Binding(get: { model.eraserWidth }, set: { model.updateEraserWidth($0) }),
                   in: 8...160,
                   step: 2)"""
        ),
    ],
)

print("done")
