#!/usr/bin/env python3
"""Round-3 patch: navigation mode (deselect all tools) + editor model/toolbar."""
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
    "SeeingCalendar/Canvas/CanvasHostView.swift",
    [
        (
            """    // MARK: - 工具

    func setTool(_ tool: PKTool) {
        canvas.canvasView.tool = tool
    }""",
            """    // MARK: - 工具

    func setTool(_ tool: PKTool) {
        canvas.canvasView.tool = tool
    }

    /// 导航态（取消全部工具 / 笔画）：禁止落笔，单指即可平移，双指缩放。
    func setNavigationMode(_ enabled: Bool) {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = enabled ? 1 : 2
        canvas.isDrawingEnabled = !enabled
    }""",
        )
    ],
)

patch(
    "SeeingCalendar/Views/EditorModel.swift",
    [
        (
            """    var activeTool: CanvasTool = .pen {
        didSet { toolNeedsApply = true }
    }""",
            """    /// nil = 导航态（未选中任何工具，只平移缩放）。
    var activeTool: CanvasTool? = .pen {
        didSet { toolNeedsApply = true }
    }""",
        ),
        (
            """    private func applyTool(on host: CanvasHostView) {
        let color = UIColor(hex: penColorHex) ?? .label
        switch activeTool {""",
            """    private func applyTool(on host: CanvasHostView) {
        let color = UIColor(hex: penColorHex) ?? .label
        guard let activeTool else {
            host.setNavigationMode(true)
            return
        }
        host.setNavigationMode(false)
        switch activeTool {""",
        ),
        (
            """    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥。
    func select(tool: CanvasTool) {
        activeTool = tool
        if isLassoActive {
            isLassoActive = false
        }
    }""",
            """    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥；再次点按当前工具即取消它（进入导航态）。
    func select(tool: CanvasTool) {
        if isLassoActive {
            isLassoActive = false
        }
        activeTool = (activeTool == tool) ? nil : tool
        toolNeedsApply = true
    }

    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { activeTool == nil }""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/DayEditorView.swift",
    [
        (
            """            if model.isLassoActive {
                Text("套索")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }""",
            """            if model.isLassoActive {
                Text("套索")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else if model.isNavigating {
                Text("导航")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }""",
        ),
        (
            """                .accessibilityLabel(tool.title)
            }

            Button {
                isColorPickerPresented.toggle()""",
            """                .accessibilityLabel(tool.title + "（再次点按可取消）")
            }

            Button {
                isColorPickerPresented.toggle()""",
        ),
    ],
)

print("done")
