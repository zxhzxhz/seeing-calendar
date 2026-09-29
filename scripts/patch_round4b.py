#!/usr/bin/env python3
"""Round-4 fix (part 2): container elevation deferral + normalizeZOrder guard."""
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
            """        entity.onEndMove = { [weak self] _ in
            guard let self else { return }
            self.isAdjustingSelection = false
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }""",
            """        entity.onEndMove = { [weak self] _ in
            guard let self else { return }
            self.isAdjustingSelection = false
            // 手指脱离后才把选中贴图重挂载到顶层容器（拖拽中重挂载会取消手势）。
            self.elevateSelection()
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }""",
        ),
        (
            """    /// 取消选中：把所有临时置顶的贴图归位并撤掉高亮。
    func releaseElevatedSelection() {
        for entity in imageViews {
            if entity.superview === selectionTopContainerView {
                place(entity, elevated: false)
            }
            entity.setHighlighted(false)
        }
    }

    /// 选中：临时高亮置顶。
    func elevateSelection() {
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            place(entity, elevated: true)
            entity.setHighlighted(true)
        }
    }""",
            """    /// 取消选中：把所有临时置顶的贴图归位并撤掉高亮。
    func releaseElevatedSelection() {
        for entity in imageViews {
            if entity.superview === selectionTopContainerView, !entity.isMoving {
                place(entity, elevated: false)
            }
            entity.setHighlighted(false)
        }
    }

    /// 选中：临时高亮置顶。
    /// 注意：正在被拖动的实体只做高亮，重挂载推迟到 `onEndMove` ——
    /// `removeFromSuperview` 会立即取消该视图进行中的 pan 手势，导致“选中后无法移动”。
    func elevateSelection() {
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            entity.setHighlighted(true)
            guard !entity.isMoving else { continue }
            place(entity, elevated: true)
        }
    }""",
        ),
    ],
)

patch(
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        (
            """    func normalizeZOrder() {
        let back = imageViews.filter { !$0.canvasItem.isInFront }.sorted { $0.zIndex < $1.zIndex }
        let front = imageViews.filter(\\.canvasItem.isInFront).sorted { $0.zIndex < $1.zIndex }""",
            """    func normalizeZOrder() {
        // 临时置顶（选中态）的实体不参与归位，否则选中态会被拽回下层。
        let back = imageViews
            .filter { !$0.canvasItem.isInFront && $0.superview !== selectionTopContainerView }
            .sorted { $0.zIndex < $1.zIndex }
        let front = imageViews
            .filter { $0.canvasItem.isInFront && $0.superview !== selectionTopContainerView }
            .sorted { $0.zIndex < $1.zIndex }""",
        ),
    ],
)

print("done")
