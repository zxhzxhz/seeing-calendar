#!/usr/bin/env python3
"""Round-6 patch D: EditorModel —— 橡皮模式/大小、页面排序。"""
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
        # 橡皮模式定义
        (
            """enum CanvasTool: String, CaseIterable, Identifiable {""",
            """/// 橡皮模式：整体擦除（整笔） / 范围擦除（擦除范围内部分笔画）。
enum EraserMode: String, CaseIterable, Identifiable {
    case wholeStroke
    case rangeErase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wholeStroke: return "整体擦除"
        case .rangeErase: return "范围擦除"
        }
    }

    var detail: String {
        switch self {
        case .wholeStroke: return "碰到即擦掉整条笔画"
        case .rangeErase: return "只擦掉橡皮范围内的那一部分"
        }
    }

    var symbol: String {
        switch self {
        case .wholeStroke: return "eraser"
        case .rangeErase: return "eraser.line.dashed"
        }
    }

    /// PencilKit 原生对应：.vector = 整笔擦除；.bitmap = 按范围像素级擦除。
    var pencilKitType: PKEraserTool.EraserType {
        switch self {
        case .wholeStroke: return .vector
        case .rangeErase: return .bitmap
        }
    }
}

enum CanvasTool: String, CaseIterable, Identifiable {"""
        ),
        # 橡皮设置状态
        (
            """    var penWidth: CGFloat = 5 {
        didSet { toolNeedsApply = true }
    }""",
            """    var penWidth: CGFloat = 5 {
        didSet { toolNeedsApply = true }
    }
    var eraserMode: EraserMode = .wholeStroke {
        didSet { toolNeedsApply = true }
    }
    /// 橡皮有效范围直径（画布世界坐标）；同时决定 PKEraserTool.width 与指示圈直径。
    var eraserWidth: CGFloat = 26 {
        didSet { toolNeedsApply = true }
    }"""
        ),
        # 应用工具：橡皮 + 指示圈状态
        (
            """        guard let activeTool else {
            host.setNavigationMode(true)
            return
        }
        host.setNavigationMode(false)""",
            """        guard let activeTool else {
            host.setNavigationMode(true)
            host.canvas.isEraserActive = false
            return
        }
        host.setNavigationMode(false)
        host.canvas.eraserWidth = eraserWidth
        host.canvas.isEraserActive = (activeTool == .eraser)"""
        ),
        (
            """        case .eraser:
            host.setTool(PKEraserTool(.vector))
        }""",
            """        case .eraser:
            // 整体擦除 = PKEraserTool(.vector)；范围擦除 = .bitmap
            host.setTool(PKEraserTool(eraserMode.pencilKitType, width: eraserWidth))
        }"""
        ),
        # 页面排序
        (
            """    // MARK: - 贴图导入""",
            """    // MARK: - 页面排序（Page 1 即月历封面）

    /// 原生 List.onMove 入口。
    func movePages(from source: IndexSet, to destination: Int) {
        save()
        var ordered = day.orderedPages
        ordered.move(fromOffsets: source, toOffset: destination)
        repository.applyPageOrder(ordered, in: day)
        reloadAfterReorder()
    }

    /// 拖放入口：把某页移动到目标位置。
    func movePage(id: UUID, toIndex index: Int) {
        var ordered = day.orderedPages
        guard let from = ordered.firstIndex(where: { $0.uuid == id }) else { return }
        let clamped = max(0, min(index, ordered.count - 1))
        guard from != clamped else { return }
        save()
        let page = ordered.remove(at: from)
        ordered.insert(page, at: min(clamped, ordered.count))
        repository.applyPageOrder(ordered, in: day)
        reloadAfterReorder()
    }

    private func reloadAfterReorder() {
        let currentUUID = currentPage?.uuid
        pages = day.orderedPages
        if let currentUUID, let index = pages.firstIndex(where: { $0.uuid == currentUUID }) {
            pageIndex = index
        } else {
            pageIndex = min(pageIndex, max(0, pages.count - 1))
        }
        loadCurrentPage()
        // 新的 Page 1 成为月历封面：立即重算它的缩略图。
        if let cover = pages.first {
            Task { await ThumbnailStore.shared.regenerate(page: cover) }
        }
    }

    // MARK: - 贴图导入"""
        ),
    ],
)

print("done")
