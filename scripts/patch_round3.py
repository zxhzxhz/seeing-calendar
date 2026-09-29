#!/usr/bin/env python3
"""Round-3 patch: selection state machine (elevate on select, no rebuild while dragging)."""
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
    "SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift",
    [
        # 选中：临时高亮置顶
        (
            """    func selectImage(id: UUID, additive: Bool) {
        guard entity(for: id) != nil else { return }
        commitSelection(notify: false)
        if additive, selectedImageIDs.contains(id) {
            selectedImageIDs.removeAll { $0 == id }
        } else {
            selectedImageIDs = [id]
        }
        selectedStrokes = []
        isGroupTransforming = false
        croppingImageID = nil
        notifySelection()
    }""",
            """    func selectImage(id: UUID, additive: Bool) {
        guard entity(for: id) != nil else { return }
        commitSelection(notify: false)
        if additive, selectedImageIDs.contains(id) {
            selectedImageIDs.removeAll { $0 == id }
        } else {
            selectedImageIDs = [id]
        }
        selectedStrokes = []
        isGroupTransforming = false
        croppingImageID = nil
        elevateSelection()
        notifySelection()
    }""",
        ),
        (
            """        if !strokes.isEmpty {
            var mutable = drawing
            for index in strokeIndices.sorted(by: >) where index >= 0 && index < mutable.strokes.count {
                mutable.strokes.remove(at: index)
            }
            setDrawing(mutable)
            showFloatingPreview()
        }
        notifySelection()
    }""",
            """        if !strokes.isEmpty {
            var mutable = drawing
            for index in strokeIndices.sorted(by: >) where index >= 0 && index < mutable.strokes.count {
                mutable.strokes.remove(at: index)
            }
            setDrawing(mutable)
            showFloatingPreview()
        }
        // 选中态临时置顶：贴图浮到笔迹之上，取消选中后自动归位。
        elevateSelection()
        notifySelection()
    }""",
        ),
        # 取消选中：归位 + 撤高亮
        (
            """        removeFloatingPreview()
        selectedImageIDs = []
        isGroupTransforming = false
        croppingImageID = nil
        gestureBaseTransform = nil
        if notify {
            notifySelection()
        } else {
            selectionKind = .none
            selectionOverlay.update(mode: .none)
        }
    }""",
            """        removeFloatingPreview()
        releaseElevatedSelection()
        selectedImageIDs = []
        isGroupTransforming = false
        croppingImageID = nil
        gestureBaseTransform = nil
        if notify {
            notifySelection()
        } else {
            selectionKind = .none
            selectionOverlay.update(mode: .none)
        }
    }""",
        ),
        (
            """    func discardSelection() {
        selectedStrokes = []
        selectedImageIDs = []
        isGroupTransforming = false
        isHandleDragging = false""",
            """    func discardSelection() {
        selectedStrokes = []
        selectedImageIDs = []
        isGroupTransforming = false
        isAdjustingSelection = false""",
        ),
        (
            """        groupBaseTransforms = [:]
        removeFloatingPreview()
        selectionKind = .none
        selectionOverlay.update(mode: .none)
    }""",
            """        groupBaseTransforms = [:]
        removeFloatingPreview()
        releaseElevatedSelection()
        selectionKind = .none
        selectionOverlay.update(mode: .none)
    }""",
        ),
        # 拖拽期只更新几何
        (
            """    func refreshSelectionOverlay() {
        let mode = overlayMode()
        if isHandleDragging {
            // 拖拽过程中只更新几何，绝不重建手柄 —— 否则进行中的手势会被立即打断。
            selectionOverlay.updateGeometry(mode)
        } else if selectionOverlay.mode != mode {""",
            """    func refreshSelectionOverlay() {
        let mode = overlayMode()
        if isAdjustingSelection {
            // 拖拽（手柄 / 贴图位移 / 整体变换）过程中只更新几何：
            // 既不重建手柄（会打断进行中的手势），也不重弹菜单（避免每帧弹窗的 CPU 尖峰）。
            selectionOverlay.updateGeometry(mode)
        } else if selectionOverlay.mode != mode {""",
        ),
        (
            """        switch state {
        case .began:
            isHandleDragging = true
            beginHandleGesture(kind, point: point)""",
            """        switch state {
        case .began:
            isAdjustingSelection = true
            selectionOverlay.dismissMenu()
            beginHandleGesture(kind, point: point)""",
        ),
        (
            """    private func endHandleGesture(_ kind: SelectionHandleKind) {
        isHandleDragging = false""",
            """    private func endHandleGesture(_ kind: SelectionHandleKind) {
        isAdjustingSelection = false""",
        ),
    ],
)

print("done")
