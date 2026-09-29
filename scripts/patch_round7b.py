#!/usr/bin/env python3
"""Round-7 patch B: 裁剪/变形改为底部工具条动作 + 交互期禁用隐式动画。"""
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


# EditorModel：动作转发
patch(
    "SeeingCalendar/Views/EditorModel.swift",
    [
        (
            """    func zoomToFit() {
        canvasHost?.zoomToFit(animated: true)
    }""",
            """    func zoomToFit() {
        canvasHost?.zoomToFit(animated: true)
    }

    /// 选区动作统一入口（浮动菜单与底部工具条共用）。
    func performSelectionAction(_ action: SelectionAction) {
        canvasHost?.canvas.perform(action)
    }"""
        ),
    ],
)

# 交互期禁用隐式动画：layer.contentsRect / bounds 默认带 0.25s 隐式动画，
# 拖拽时会造成视觉滞后（裁剪尤其明显）。
patch(
    "SeeingCalendar/Canvas/ImageEntityView.swift",
    [
        (
            """    /// 将模型矩阵投影到 UIKit 视图（center + 线性变换，二者组合等价于 worldTransform）。
    func applyWorldTransform() {
        let size = visibleSize
        bounds = CGRect(origin: .zero, size: size)
        center = worldTransform.applied(to: CGPoint(x: size.width / 2, y: size.height / 2))
        transform = worldTransform.linearPart
        layer.contentsRect = cropRect
    }""",
            """    /// 将模型矩阵投影到 UIKit 视图（center + 线性变换，二者组合等价于 worldTransform）。
    func applyWorldTransform() {
        // 交互期禁用隐式动画：bounds / position / contentsRect 都带默认 0.25s 隐式动画，
        // 拖拽时会让图元明显滞后于手指（裁剪时尤其像"卡住"）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = visibleSize
        bounds = CGRect(origin: .zero, size: size)
        center = worldTransform.applied(to: CGPoint(x: size.width / 2, y: size.height / 2))
        transform = worldTransform.linearPart
        layer.contentsRect = cropRect
        CATransaction.commit()
    }"""
        ),
        (
            """    /// 选中态临时高亮（不改变任何几何，纯视觉提示）。
    func setHighlighted(_ highlighted: Bool) {
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = highlighted ? 0.55 : 0
        layer.shadowRadius = highlighted ? 10 : 0
        layer.shadowOffset = .zero
    }""",
            """    /// 选中态临时高亮（不改变任何几何，纯视觉提示）。
    func setHighlighted(_ highlighted: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = highlighted ? 0.55 : 0
        layer.shadowRadius = highlighted ? 10 : 0
        layer.shadowOffset = .zero
        CATransaction.commit()
    }"""
        ),
    ],
)

# DayEditorView：底部工具条模式级动作
patch(
    "SeeingCalendar/Views/DayEditorView.swift",
    [
        (
            """    private func toolBar(model: EditorModel) -> some View {
        HStack(spacing: 14) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)""",
            """    private func toolBar(model: EditorModel) -> some View {
        HStack(spacing: 14) {
            // 模式级动作（裁剪 / 变形）放在底部工具条：不遮挡任何手柄。
            contextualActions(model: model)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)"""
        ),
        (
            """    private func penSettings(model: EditorModel) -> some View {""",
            """    @ViewBuilder
    private func contextualActions(model: EditorModel) -> some View {
        switch model.selectionKind {
        case .cropping:
            Button("取消") { model.performSelectionAction(.cancelCrop) }
                .font(.system(size: 13))
            Button("完成裁剪") { model.performSelectionAction(.finishCrop) }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Divider().frame(height: 22)
        case .compositeTransform:
            Button("完成变形") { model.performSelectionAction(.finishTransform) }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Divider().frame(height: 22)
        default:
            EmptyView()
        }
    }

    private func penSettings(model: EditorModel) -> some View {"""
        ),
    ],
)

print("done")
