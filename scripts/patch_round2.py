#!/usr/bin/env python3
"""Round-2 patch: month grid sizing helpers, page repo zIndex, host zoom toggle, editor model."""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def patch(rel: str, pairs: list[tuple[str, str]]) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"MISS in {rel}: {old[:80]!r}")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("patched", rel)


patch(
    "SeeingCalendar/Views/MonthGridView.swift",
    [
        (
            """    @State private var thumbnails: [String: UIImage] = [:]
    @State private var loadedToken: ThumbToken?

    private let spacing: CGFloat = 6
    private let weekdayHeaderHeight: CGFloat = 22

    private var gridDates: [Date] { CalendarUtils.gridDates(forMonthContaining: month) }

    private var cellWidth: CGFloat {
        let byWidth = (availableSize.width - spacing * 6) / 7
        let byHeight = (availableSize.height - spacing * 5 - weekdayHeaderHeight) / 6
        return max(28, floor(min(byWidth, byHeight)))
    }""",
            """    @State private var thumbnails: [String: UIImage] = [:]

    static let spacing: CGFloat = 6
    static let weekdayHeaderHeight: CGFloat = 22
    static let minimumCellWidth: CGFloat = 28

    private let spacing = MonthGridView.spacing
    private let weekdayHeaderHeight = MonthGridView.weekdayHeaderHeight

    private var gridDates: [Date] { CalendarUtils.gridDates(forMonthContaining: month) }

    /// 单格 1:1 边长：取「横向可用宽」与「纵向可用高」的较小者。
    static func cellWidth(availableSize: CGSize) -> CGFloat {
        let byWidth = (availableSize.width - spacing * 6) / 7
        let byHeight = (availableSize.height - spacing * 5 - weekdayHeaderHeight) / 6
        return max(minimumCellWidth, floor(min(byWidth, byHeight)))
    }

    /// 整块月历（含星期表头）的高度。
    static func gridHeight(cellWidth: CGFloat) -> CGFloat {
        cellWidth * 6 + spacing * 5 + weekdayHeaderHeight
    }

    private var cellWidth: CGFloat {
        MonthGridView.cellWidth(availableSize: availableSize)
    }""",
        )
    ],
)

patch(
    "SeeingCalendar/Store/PageRepository.swift",
    [
        (
            """    /// 全量对账：新增 / 更新 / 删除，保证数据库与画布一致。
    func saveImageItems(_ items: [CanvasImageItem], for page: DrawingPage) {
        var existing: [UUID: ImageRecord] = [:]
        for record in page.images { existing[record.uuid] = record }

        for (index, item) in items.enumerated() {""",
            """    /// 全量对账：新增 / 更新 / 删除，保证数据库与画布一致。
    /// `zIndex` 直接沿用画布给出的全局序号（含「笔迹之上」的前置层区间）。
    func saveImageItems(_ items: [CanvasImageItem], for page: DrawingPage) {
        var existing: [UUID: ImageRecord] = [:]
        for record in page.images { existing[record.uuid] = record }

        for item in items.sorted(by: { $0.zIndex < $1.zIndex }) {""",
        ),
        (
            """                record.naturalHeight = Double(item.naturalSize.height)
                record.zIndex = index""",
            """                record.naturalHeight = Double(item.naturalSize.height)
                record.zIndex = item.zIndex""",
        ),
        (
            """                                         naturalSize: item.naturalSize,
                                         zIndex: index)""",
            """                                         naturalSize: item.naturalSize,
                                         zIndex: item.zIndex)""",
        ),
    ],
)

patch(
    "SeeingCalendar/Canvas/CanvasHostView.swift",
    [
        (
            """    let scrollView = UIScrollView()
    let canvas: CompositeCanvasContainerView

    private var didPerformInitialFit = false""",
            """    let scrollView = UIScrollView()
    let canvas: CompositeCanvasContainerView

    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?

    private var didPerformInitialFit = false""",
        ),
        (
            """    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
    }""",
            """    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    /// 恰好看清整张 1:1 画布的缩放。
    var fitScale: CGFloat {
        guard canvas.bounds.width > 0, canvas.bounds.height > 0,
              bounds.width > 1, bounds.height > 1 else { return 1 }
        return min(bounds.width / canvas.bounds.width, bounds.height / canvas.bounds.height)
    }

    var isExpanded: Bool {
        scrollView.zoomScale > fitScale * 1.05
    }

    func notifyZoom() {
        onZoomChange?(scrollView.zoomScale, fitScale)
    }

    /// 「最大化 / 缩小」：在“适应整页”与“放大到 100%”之间切换，点击必有可见反馈。
    func toggleExpanded(animated: Bool = true) {
        let fit = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, fitScale))
        if scrollView.zoomScale > fit * 1.05 {
            scrollView.setZoomScale(fit, animated: animated)
        } else {
            let target = min(scrollView.maximumZoomScale, max(fit * 1.02, 1.0))
            scrollView.setZoomScale(target, animated: animated)
        }
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }""",
        ),
        (
            """        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
    }

    func zoomIn""",
            """        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    func zoomIn""",
        ),
        (
            """    func zoomIn(animated: Bool = true) {
        let target = min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
    }

    func zoomOut(animated: Bool = true) {
        let target = max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
    }""",
            """    func zoomIn(animated: Bool = true) {
        let target = min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    func zoomOut(animated: Bool = true) {
        let target = max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/EditorModel.swift",
    [
        (
            """    var hasClipboard = false
    var isReplacingImage = false""",
            """    var hasClipboard = false
    var isCanvasExpanded = false
    var isReplacingImage = false""",
        ),
        (
            """        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.isLassoActive = isLassoActive
        toolNeedsApply = true""",
            """        host.onZoomChange = { [weak self] scale, fit in
            guard let self else { return }
            let expanded = fit > 0 && scale > fit * 1.05
            if self.isCanvasExpanded != expanded {
                self.isCanvasExpanded = expanded
            }
        }
        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.isLassoActive = isLassoActive
        toolNeedsApply = true""",
        ),
        (
            """    func zoomToFit() {
        canvasHost?.zoomToFit(animated: true)
    }""",
            """    func zoomToFit() {
        canvasHost?.zoomToFit(animated: true)
    }

    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥。
    func select(tool: CanvasTool) {
        activeTool = tool
        if isLassoActive {
            isLassoActive = false
        }
    }

    /// 套索 —— 与笔墨工具互斥。
    func toggleLasso() {
        isLassoActive.toggle()
    }

    /// 「最大化 / 缩小」画布视口。
    func toggleCanvasZoom() {
        canvasHost?.toggleExpanded(animated: true)
    }""",
        ),
    ],
)

print("done")
