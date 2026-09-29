#!/usr/bin/env python3
"""Round-3 patch: overlay (menu anchoring below, single-present guard, lasso tap deselect) + image entity."""
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
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        # 新增状态字段
        (
            """    private var menuActions: [SelectionAction] = []
    private var lastPresentedTag: Int = -1""",
            """    private var menuActions: [SelectionAction] = []
    private var lastPresentedTag: Int = -1
    /// 呈现代次：同一帧内多次触发时只允许最后一次真正弹出，避免重复弹菜单。
    private var menuGeneration: Int = 0""",
        ),
        # 公开：命中真实交互元素 / 主动收起菜单
        (
            """    // MARK: - 状态更新

    /// 形态或菜单集合发生变化：重建手柄与菜单。""",
            """    // MARK: - 外部查询与控制

    /// 命中测试：仅判定「手柄」等真实交互元素（不含覆盖全屏的套索捕获区）。
    /// 用于让“点按空白处取消选中”不被套索模式的命中判定吃掉。
    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }

    /// 主动收起菜单（开始拖拽时调用，手指脱离后再由容器重新弹出）。
    func dismissMenu() {
        guard lastPresentedTag != -1 else { return }
        lastPresentedTag = -1
        menuGeneration &+= 1
        editMenu.dismissMenu()
    }

    // MARK: - 状态更新

    /// 形态或菜单集合发生变化：重建手柄与菜单。""",
        ),
        # 菜单呈现：代次守卫 + 位置在选区下方
        (
            """    private func syncEditMenu(force: Bool) {
        guard !menuActions.isEmpty, let anchor = menuAnchorPoint() else {
            if lastPresentedTag != -1 {
                lastPresentedTag = -1
                editMenu.dismissMenu()
            }
            return
        }
        let tag = mode.shapeTag
        guard force || lastPresentedTag != tag else { return }
        lastPresentedTag = tag
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor)

        if force {
            // 形态切换（例如“裁剪”进入二级状态）时旧菜单仍在退场动画中，
            // 立即重新呈现会被系统忽略，因此先收起、再等一拍后呈现。
            editMenu.dismissMenu()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard let self, self.lastPresentedTag == tag else { return }
                self.editMenu.presentEditMenu(with: configuration)
            }
        } else {
            editMenu.presentEditMenu(with: configuration)
        }
    }

    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.minY - 12 * scale)
        case .image(let quad), .cropping(let quad):
            guard let top = quad.min(by: { $0.y < $1.y }) else { return nil }
            return CGPoint(x: top.x, y: top.y - 12 * scale)
        }
    }""",
            """    private func syncEditMenu(force: Bool) {
        guard !menuActions.isEmpty, let anchor = menuAnchorPoint() else {
            dismissMenu()
            return
        }
        let tag = mode.shapeTag
        guard force || lastPresentedTag != tag else { return }
        lastPresentedTag = tag
        menuGeneration &+= 1
        let generation = menuGeneration
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor)

        // 形态切换（例如“裁剪”进入二级状态）时旧菜单仍在退场动画中，
        // 立即重新呈现会被系统忽略，因此先收起、再等一拍由**最新一次**调度弹出。
        editMenu.dismissMenu()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(force ? 160 : 60))
            guard let self, self.menuGeneration == generation, self.lastPresentedTag == tag else { return }
            self.editMenu.presentEditMenu(with: configuration)
        }
    }

    /// 菜单锚点放在选区**下方**，避免遮挡顶部的旋转控制手柄。
    private func menuAnchorPoint() -> CGPoint? {
        let scale = max(0.05, contentScale)
        let gap = 22 * scale
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.maxY + gap)
        case .image(let quad), .cropping(let quad):
            guard let lowest = quad.max(by: { $0.y < $1.y }) else { return nil }
            return CGPoint(x: lowest.x, y: lowest.y + gap)
        }
    }""",
        ),
        # 让系统围绕锚点（而非整块选区）排布，进一步避免压住手柄
        (
            """    nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                         targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        MainActor.assumeIsolated {
            switch mode {
            case .composite(let rect), .compositeTransform(let rect):
                return rect
            case .image(let quad), .cropping(let quad):
                return CanvasGeometry.boundingBox(quad)
            case .none:
                return .zero
            }
        }
    }""",
            """    nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                         targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        MainActor.assumeIsolated {
            guard let anchor = menuAnchorPoint() else { return .zero }
            let size = 14 * max(0.05, contentScale)
            return CGRect(x: anchor.x - size / 2, y: anchor.y - size / 2, width: size, height: size)
        }
    }""",
        ),
        # 套索模式下「点一下」= 取消选中（短路径同样上报，由仲裁器得出空结果）
        (
            """        let path = lassoPoints
        lassoPoints = []
        lassoLayer.path = nil
        if path.count >= 3 {
            delegate?.selectionOverlay(self, didCompleteLasso: path)
        }
    }""",
            """        let path = lassoPoints
        lassoPoints = []
        lassoLayer.path = nil
        // 点一下（退化套索）也要上报：仲裁器会给出空结果，容器据此取消选中。
        delegate?.selectionOverlay(self, didCompleteLasso: path)
    }""",
        ),
    ],
)

patch(
    "SeeingCalendar/Canvas/ImageEntityView.swift",
    [
        (
            """    var onSelect: ((ImageEntityView) -> Void)?
    var onBeginMove: ((ImageEntityView) -> Void)?
    var onTransformChanged: ((ImageEntityView) -> Void)?""",
            """    var onSelect: ((ImageEntityView) -> Void)?
    var onBeginMove: ((ImageEntityView) -> Void)?
    var onTransformChanged: ((ImageEntityView) -> Void)?
    var onEndMove: ((ImageEntityView) -> Void)?""",
        ),
        (
            """        case .ended, .cancelled, .failed:
            gestureBase = nil
            gestureStartPoint = nil
            onTransformChanged?(self)""",
            """        case .ended, .cancelled, .failed:
            gestureBase = nil
            gestureStartPoint = nil
            onEndMove?(self)""",
        ),
        (
            """    func update(transform newTransform: CGAffineTransform) {
        worldTransform = newTransform
        applyWorldTransform()
    }""",
            """    func update(transform newTransform: CGAffineTransform) {
        worldTransform = newTransform
        applyWorldTransform()
    }

    /// 选中态临时高亮（不改变任何几何，纯视觉提示）。
    func setHighlighted(_ highlighted: Bool) {
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = highlighted ? 0.55 : 0
        layer.shadowRadius = highlighted ? 10 : 0
        layer.shadowOffset = .zero
    }""",
        ),
    ],
)

print("done")
