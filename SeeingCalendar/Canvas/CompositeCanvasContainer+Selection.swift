import PencilKit
import UIKit

/// 统一选区：状态机、跨图层变换、剪贴板与图层顺序。
extension CompositeCanvasContainerView: SelectionOverlayDelegate {
    enum CropHandle {
        case corner(Int)   // 0 TL · 1 TR · 2 BR · 3 BL
        case edge(Int)     // 0 上 · 1 右 · 2 下 · 3 左
    }

    // MARK: - 选区构建

    var effectiveImageID: UUID? {
        selectedImageIDs.first ?? croppingImageID
    }

    var isCropping: Bool { croppingImageID != nil }

    func selectImage(id: UUID, additive: Bool) {
        // 锁定贴图不可选中（命中测试已跳过，这里是兜底）。
        guard let target = entity(for: id), !target.isLocked else { return }
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
    }

    func select(strokeIndices: [Int], imageIDs: [UUID]) {
        commitSelection(notify: false)
        let drawing = canvasView.drawing
        let strokes = strokeIndices
            .filter { $0 >= 0 && $0 < drawing.strokes.count }
            .map { drawing.strokes[$0] }

        selectedStrokes = strokes
        selectedImageIDs = imageIDs
        // 需求：套索选中**含笔迹**的对象（含"笔迹+贴图"混合）即默认进入变形态，
        // 保证缩放/旋转后仍留在变形态，连续编辑不被打断。
        // 纯贴图选择不进入变形态：单张 → 贴图编辑态；多张 → 复合态（可再点"变形"进入）。
        isGroupTransforming = !strokes.isEmpty
        croppingImageID = nil

        if !strokes.isEmpty {
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
    }

    /// 结束选区：浮动笔迹合并回画布，贴图留位，清空手柄与菜单。
    func commitSelection(notify: Bool = true) {
        if !selectedStrokes.isEmpty {
            var drawing = canvasView.drawing
            drawing.strokes.append(contentsOf: selectedStrokes)
            selectedStrokes = []
            setDrawing(drawing)
        }
        removeFloatingPreview()
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
    }

    func clearSelection() {
        commitSelection(notify: true)
    }

    /// 仅丢弃选区状态（页面切换 / 撤销重做时使用，不把浮动笔迹合并回画布）。
    func discardSelection() {
        selectedStrokes = []
        selectedImageIDs = []
        isGroupTransforming = false
        isAdjustingSelection = false
        croppingImageID = nil
        cropBase = nil
        gestureBaseTransform = nil
        groupAccumulatedDelta = nil
        groupBaseTransforms = [:]
        removeFloatingPreview()
        releaseElevatedSelection()
        selectionKind = .none
        selectionOverlay.update(mode: .none)
    }

    /// 选区包围盒。
    ///
    /// 关键：拖动过程中被选中的**笔迹**只是浮层预览被施加了变换，模型数据要等手指离开才烘焙，
    /// 因此这里必须把「进行中的变换」也计入，否则选区框会停在原地、直到手势结束才"跳"过去
    /// （表现为：移动时只有物体动、选区不跟随；结束后才追上来）。
    func selectionBounds() -> CGRect {
        var result = CGRect.null
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            let box = CanvasGeometry.boundingBox(entity.worldQuad)
            result = result.isNull ? box : result.union(box)
        }
        if !selectedStrokes.isEmpty {
            var box = strokesBounds(selectedStrokes)
            if let delta = groupAccumulatedDelta, !box.isNull {
                box = box.applying(delta)   // 视觉上的当前位置
            }
            if !box.isNull { result = result.isNull ? box : result.union(box) }
        }
        return result.isNull ? .zero : result
    }

    private func overlayMode() -> SelectionOverlayView.Mode {
        switch selectionKind {
        case .none:
            return .none
        case .composite:
            return .composite(selectionBounds())
        case .compositeTransform:
            return .compositeTransform(selectionBounds())
        case .image(let id):
            let ent = entity(for: id)
            let canEdit = ent?.payload != nil
            return .image(quad: ent?.worldQuad ?? [], canEdit: canEdit)
        case .cropping(let id):
            return .cropping(quad: entity(for: id)?.worldQuad ?? [])
        }
    }

    func refreshSelectionOverlay() {
        let mode = overlayMode()
        if isAdjustingSelection {
            // 拖拽（手柄 / 贴图位移 / 整体变换）过程中只更新几何：
            // 既不重建手柄（会打断进行中的手势），也不重弹菜单（避免每帧弹窗的 CPU 尖峰）。
            selectionOverlay.updateGeometry(mode)
        } else if selectionOverlay.mode != mode {
            selectionOverlay.update(mode: mode)
        } else {
            selectionOverlay.refreshLayout()
        }
    }

    // MARK: - 浮动笔迹预览

    func strokesBounds(_ strokes: [PKStroke]) -> CGRect {
        var result = CGRect.null
        for stroke in strokes {
            let box = stroke.renderBounds
            result = result.isNull ? box : result.union(box)
        }
        return result
    }

    func showFloatingPreview() {
        removeFloatingPreview()
        guard !selectedStrokes.isEmpty else { return }
        let box = strokesBounds(selectedStrokes)
        guard !box.isNull, box.width > 0 || box.height > 0 else { return }
        let image = PKDrawing(strokes: selectedStrokes).image(from: box, scale: 2)
        let view = UIImageView(image: image)
        view.frame = box
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        selectionContentContainer.addSubview(view)
        floatingPreview = view
    }

    func removeFloatingPreview() {
        floatingPreview?.removeFromSuperview()
        floatingPreview = nil
    }

    // MARK: - 笔迹几何变换

    /// 把 delta（世界坐标）烧进浮动笔迹，并同步缩放笔迹线宽。
    func bakeStrokes(delta: CGAffineTransform) {
        guard !selectedStrokes.isEmpty else { return }
        selectedStrokes = transformStrokes(selectedStrokes, by: delta)
        showFloatingPreview()
    }

    /// 变换笔迹：**只把 delta 合成到 `stroke.transform`，绝不重建 path**。
    ///
    /// 为什么必须是这种写法（真机 bug + 官方语义双重确认）：
    ///  · 范围擦除（`PKEraserTool.EraserType.bitmap`）不会删除 path 上的点，
    ///    而是给笔迹加上 **mask** 来裁剪渲染 —— WWDC20：
    ///    "Masked strokes are typically created when the pixel eraser is used to erase only a portion
    ///     of a stroke … Masks can have holes. Or they can cut a stroke into multiple pieces."
    ///  · `mask` 是 **pretransform** 空间的（官方文档：The pretransform mask used to clip the
    ///    rendering of the stroke），与 path 同处笔迹局部坐标系。
    ///  ⇒ 若把变换烘焙进 path 控制点却沿用旧 mask，裁剪区就停留在旧位置，
    ///    与新的几何错位 —— 现象正是「被擦断的线在变形/移动/旋转后消失或只剩一小截」。
    ///  · 改为合成 `transform` 后，path 与 mask 作为同一个局部空间被整体变换，天然保持一致；
    ///    而且 `renderBounds` 的文档明确 transform 作用于**渲染结果**（含线宽），
    ///    因此整体缩放时笔迹宽度会按比例自然缩放，无需再手工乘 size。
    ///  · 附带收益：O(1)（不再逐点重建）、零保真损失（PencilKit 的点是"有损压缩存储"，重建会掉精度）。
    func transformStrokes(_ strokes: [PKStroke], by delta: CGAffineTransform) -> [PKStroke] {
        strokes.map { stroke in
            PKStroke(ink: stroke.ink,
                     path: stroke.path,
                     transform: stroke.transform.concatenating(delta),
                     mask: stroke.mask)
        }
    }

    // MARK: - 手势：手柄拖拽

    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragHandle kind: SelectionHandleKind,
                          to point: CGPoint,
                          state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            isAdjustingSelection = true
            // 同样不在拖拽开始时收起菜单：会中断进行中的触摸（见 onBeginMove 注释）。
            beginHandleGesture(kind, point: point)
        case .changed:
            updateHandleGesture(kind, point: point)
        case .ended, .cancelled, .failed:
            endHandleGesture(kind)
        default:
            break
        }
    }

    private func beginHandleGesture(_ kind: SelectionHandleKind, point: CGPoint) {
        gestureBasePoint = point

        switch kind {
        case .imageCorner, .imageEdge, .imageRotate:
            guard let id = effectiveImageID, let entity = entity(for: id) else { return }
            gestureBaseTransform = entity.worldTransform
            if case .imageEdge = kind {
                // 边手柄 = 直接进入裁剪
                croppingImageID = id
                cropBase = (entity.cropRect, entity.worldTransform, entity.naturalSize)
            } else if isCropping {
                cropBase = (entity.cropRect, entity.worldTransform, entity.naturalSize)
            } else {
                cropBase = nil
            }

        case .groupCorner, .groupRotate:
            gestureBaseTransform = .identity
            groupBaseBounds = selectionBounds()
            groupBaseTransforms = imageViews.reduce(into: [:]) { partial, view in
                if selectedImageIDs.contains(view.itemID) { partial[view.itemID] = view.worldTransform }
            }
        }
        // 变换前的状态必须先入栈，保证缩放/旋转/裁剪可撤销。
        pushHistory()
    }

    private func updateHandleGesture(_ kind: SelectionHandleKind, point: CGPoint) {
        switch kind {
        case .imageCorner(let index):
            if isCropping {
                applyCrop(.corner(index), point: point)
            } else {
                applyImageCornerScale(index: index, point: point)
            }
        case .imageEdge(let index):
            applyCrop(.edge(index), point: point)
        case .imageRotate:
            applyImageRotation(point: point)
        case .groupCorner(let index):
            applyGroupScale(index: index, point: point)
        case .groupRotate:
            applyGroupRotation(point: point)
        }
    }

    private func endHandleGesture(_ kind: SelectionHandleKind) {
        isAdjustingSelection = false
        switch kind {
        case .imageCorner, .imageRotate:
            // 单图态本身不是"模式"，无需处理变形态标志。
            cropBase = nil
        case .imageEdge:
            // 保持裁剪态，等待用户点“完成裁剪”；下次手势会重新采集基准。
            cropBase = nil
        case .groupCorner, .groupRotate:
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            groupBaseTransforms = [:]
            // 注意：这里**不清除** isGroupTransforming —— 变形态是"模式"，
            // 退出只能由用户动作触发（点选区内保持并弹菜单 / 点选区外退出 / 点"完成变形"）。
            // 此前在每次缩放/旋转结束时清除，导致"做一次操作就掉出变形态"。
        }
        gestureBaseTransform = nil
        notifySelection()
        onContentChange?()
    }

    // MARK: - 单图变换

    /// 单图四角缩放：**以图元（= 选区）正中心为不动点**等比缩放，与整体变形保持一致。
    /// 缩放比例取手指位移在「中心 → 手柄」轴上的投影比（与整体变形的算法同源）。
    private func applyImageCornerScale(index: Int, point: CGPoint) {
        guard let id = effectiveImageID,
              let entity = entity(for: id),
              let base = gestureBaseTransform else { return }
        let baseInverse = base.inverted()
        let size = entity.visibleSize
        let centerLocal = CGPoint(x: size.width / 2, y: size.height / 2)
        let localCorners = [CGPoint(x: 0, y: 0),
                            CGPoint(x: size.width, y: 0),
                            CGPoint(x: size.width, y: size.height),
                            CGPoint(x: 0, y: size.height)]
        guard index >= 0, index < localCorners.count else { return }
        let cornerLocal = localCorners[index]
        let pointLocal = point.applying(baseInverse)

        let axis = CGPoint(x: cornerLocal.x - centerLocal.x, y: cornerLocal.y - centerLocal.y)
        let lengthSquared = axis.x * axis.x + axis.y * axis.y
        guard lengthSquared > 1 else { return }
        let delta = CGPoint(x: pointLocal.x - centerLocal.x, y: pointLocal.y - centerLocal.y)
        let ratio = (delta.x * axis.x + delta.y * axis.y) / lengthSquared
        let uniform = max(0.05, ratio)

        // 局部坐标系缩放，不动点取局部中心（映射到世界即图元中心）。
        let localDelta = CGAffineTransform.worldScale(anchor: centerLocal, sx: uniform, sy: uniform)
        entity.update(transform: base.applyingLocalDelta(localDelta))
        refreshSelectionOverlay()
    }

    private func applyImageRotation(point: CGPoint) {
        guard let id = effectiveImageID,
              let entity = entity(for: id),
              let base = gestureBaseTransform else { return }
        let center = base.applied(to: CGPoint(x: entity.visibleSize.width / 2, y: entity.visibleSize.height / 2))
        let startAngle = atan2(gestureBasePoint.y - center.y, gestureBasePoint.x - center.x)
        let currentAngle = atan2(point.y - center.y, point.x - center.x)
        let baseRotation = base.rotationAngle
        let raw = baseRotation + (currentAngle - startAngle)
        let snapped = CanvasGeometry.snappedAngle(raw)
        if snapped.snapped, abs(snapped.angle - raw) > 0.0001 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        // 旋转定义在**世界**坐标系（绕世界中心）→ 先 base 后 delta。
        let delta = CGAffineTransform.worldRotation(center: center, angle: snapped.angle - baseRotation)
        entity.update(transform: base.applyingWorldDelta(delta))
        refreshSelectionOverlay()
    }

    // MARK: - 无损裁剪（视窗）拖拽

    private func applyCrop(_ handle: CropHandle, point: CGPoint) {
        guard let id = effectiveImageID, let entity = entity(for: id) else { return }
        let base = cropBase ?? (entity.cropRect, entity.worldTransform, entity.naturalSize)
        let baseInverse = base.transform.inverted()
        let pointLocal = point.applying(baseInverse)
        // 当前图层局部空间 → 原图像像素空间
        let offsetX = base.natural.width * base.crop.origin.x
        let offsetY = base.natural.height * base.crop.origin.y
        let original = CGPoint(x: pointLocal.x + offsetX, y: pointLocal.y + offsetY)

        var minX = base.crop.minX * base.natural.width
        var minY = base.crop.minY * base.natural.height
        var maxX = base.crop.maxX * base.natural.width
        var maxY = base.crop.maxY * base.natural.height
        let minimumSize: CGFloat = 28

        switch handle {
        case .corner(let index):
            switch index {
            case 0:
                minX = min(max(0, original.x), maxX - minimumSize)
                minY = min(max(0, original.y), maxY - minimumSize)
            case 1:
                maxX = max(min(base.natural.width, original.x), minX + minimumSize)
                minY = min(max(0, original.y), maxY - minimumSize)
            case 2:
                maxX = max(min(base.natural.width, original.x), minX + minimumSize)
                maxY = max(min(base.natural.height, original.y), minY + minimumSize)
            default:
                minX = min(max(0, original.x), maxX - minimumSize)
                maxY = max(min(base.natural.height, original.y), minY + minimumSize)
            }
        case .edge(let index):
            switch index {
            case 0: minY = min(max(0, original.y), maxY - minimumSize)
            case 1: maxX = max(min(base.natural.width, original.x), minX + minimumSize)
            case 2: maxY = max(min(base.natural.height, original.y), minY + minimumSize)
            default: minX = min(max(0, original.x), maxX - minimumSize)
            }
        }

        let newCrop = CGRect(x: minX / base.natural.width,
                             y: minY / base.natural.height,
                             width: max(0.02, (maxX - minX) / base.natural.width),
                             height: max(0.02, (maxY - minY) / base.natural.height))
        // 保持可见内容就地不动：先平移回原图坐标系，再套用基准矩阵。
        // 裁剪平移发生在**原图局部**坐标系（新视窗原点相对基准视窗的偏移）→ 先 delta 后 base。
        let translation = CGAffineTransform(translationX: base.natural.width * (newCrop.origin.x - base.crop.origin.x),
                                            y: base.natural.height * (newCrop.origin.y - base.crop.origin.y))
        entity.update(cropRect: newCrop, worldTransform: base.transform.applyingLocalDelta(translation))
        // 只标记"正在裁剪"，**不改 selectionKind**：
        // 在 .image 态拖边手柄时会隐式进入裁剪，若此刻就把形态切成 .cropping，
        // 覆盖层会因 shapeTag 变化而重建手柄 → 正在拖拽的手势被移除视图打断
        // （这正是"第一次只能移动一点就停住，第二次及以后正常"的根因）。
        // 形态切换统一推迟到 endHandleGesture → notifySelection()，即手指脱离之后。
        croppingImageID = id
        refreshSelectionOverlay()
    }

    // MARK: - 复合选区整体变换

    /// 手柄在世界坐标下的原始位置（以给定矩形为准，与覆盖层的排布规则保持一致）。
    private func groupHandlePoint(_ index: Int, in rect: CGRect) -> CGPoint {
        let corners = CanvasGeometry.corners(of: rect)
        if index < 4 { return corners[index] }
        let edges = [CanvasGeometry.midpoint(corners[0], corners[1]),
                     CanvasGeometry.midpoint(corners[1], corners[2]),
                     CanvasGeometry.midpoint(corners[2], corners[3]),
                     CanvasGeometry.midpoint(corners[3], corners[0])]
        let edgeIndex = min(max(index - 4, 0), edges.count - 1)
        return edges[edgeIndex]
    }

    /// 整体缩放：**以套索确定的整体选中区域中心为不动点**，等比缩放，
    /// 手柄只决定缩放比例（把手指位移投影到「中心 → 手柄」这条轴上），行为与贴图缩放一致。
    private func applyGroupScale(index: Int, point: CGPoint) {
        let base = groupBaseBounds
        guard !base.isNull else { return }
        let center = CGPoint(x: base.midX, y: base.midY)
        let origin = groupHandlePoint(index, in: base)
        let axis = CGPoint(x: origin.x - center.x, y: origin.y - center.y)
        let lengthSquared = axis.x * axis.x + axis.y * axis.y
        guard lengthSquared > 1 else { return }

        let delta = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let ratio = (delta.x * axis.x + delta.y * axis.y) / lengthSquared
        let uniform = max(0.05, ratio)

        applyGroupDelta(CGAffineTransform.worldScale(anchor: center, sx: uniform, sy: uniform))
    }

    private func applyGroupRotation(point: CGPoint) {
        let base = groupBaseBounds
        guard !base.isNull else { return }
        let center = CGPoint(x: base.midX, y: base.midY)
        let startAngle = atan2(gestureBasePoint.y - center.y, gestureBasePoint.x - center.x)
        let currentAngle = atan2(point.y - center.y, point.x - center.x)
        let snapped = CanvasGeometry.snappedAngle(currentAngle - startAngle)
        applyGroupDelta(CGAffineTransform.worldRotation(center: center, angle: snapped.angle))
    }

    private func applyGroupDelta(_ delta: CGAffineTransform) {
        groupAccumulatedDelta = delta
        isGroupTransforming = true
        for (id, base) in groupBaseTransforms {
            // 整体变换是世界坐标系的 delta（组锚点不动）→ 先 base 后 delta。
            entity(for: id)?.update(transform: base.applyingWorldDelta(delta))
        }
        if let preview = floatingPreview {
            // UIView.transform 绕自身中心施加，需共轭校正才能等价于世界 delta，
            // 否则“浮动笔迹预览”会与最终落盘的笔迹错位。
            preview.transform = delta.viewConjugate(aboutCenter: preview.center)
        }
        refreshSelectionOverlay()
    }

    // MARK: - 选区内部拖动（整体平移）

    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragInterior point: CGPoint,
                          state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            isAdjustingSelection = true
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

    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint]) {
        let snapshots = imageViews.map {
            UnifiedLassoArbitrator.ImageSnapshot(id: $0.itemID, quad: $0.worldQuad, isLocked: $0.isLocked)
        }
        let result = UnifiedLassoArbitrator.evaluate(lasso: points, drawing: canvasView.drawing, images: snapshots)
        guard !result.strokeIndices.isEmpty || !result.imageIDs.isEmpty else {
            clearSelection()
            return
        }
        select(strokeIndices: result.strokeIndices, imageIDs: result.imageIDs)
    }

    // MARK: - 菜单动作

    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        perform(action)
    }

    /// 选区动作总入口：浮动菜单与编辑器底部工具条共用同一条实现。
    func perform(_ action: SelectionAction) {
        // 原生菜单退场可能把触摸透传到画布，这里登记 0.35s 保护窗口，
        // 避免刚建立的选择状态被「点空白取消选中」立刻清掉。
        menuActionGuardUntil = Date().addingTimeInterval(0.35)
        switch action {
        case .edit:
            guard let id = selectedImageIDs.first, let entity = entity(for: id), let payload = entity.payload else { return }
            onRequestItemEdit?(id, payload)
        case .copy:
            copySelectionToClipboard()
        case .cut:
            copySelectionToClipboard()
            deleteSelection()
        case .delete:
            deleteSelection()
        case .transform:
            isGroupTransforming = true
            notifySelection()
        case .finishTransform:
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            isGroupTransforming = false
            notifySelection()
            onContentChange?()
        case .crop:
            guard let id = selectedImageIDs.first, let entity = entity(for: id) else { return }
            croppingImageID = id
            cropBase = (entity.cropRect, entity.worldTransform, entity.naturalSize)
            notifySelection()
        case .finishCrop:
            croppingImageID = nil
            cropBase = nil
            notifySelection()
            onContentChange?()
        case .cancelCrop:
            if let base = cropBase, let id = croppingImageID, let entity = entity(for: id) {
                entity.update(cropRect: base.crop, worldTransform: base.transform)
            }
            croppingImageID = nil
            cropBase = nil
            notifySelection()
        case .replace:
            guard let id = selectedImageIDs.first else { return }
            onRequestImageReplace?(id)
        case .bringToFront:
            bringSelectionToFront()
        case .sendToBack:
            sendSelectionToBack()
        case .lock:
            lockSelectedImages()
        case .unlock:
            unlockAllImages()
        }
    }

    // MARK: - 剪贴板

    func copySelectionToClipboard() {
        let items = selectedImageIDs.compactMap { entity(for: $0)?.canvasItem }
        clipboard = CanvasClipboard(strokes: selectedStrokes, items: items)
    }

    func deleteSelection() {
        guard !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty else { return }
        pushHistory()
        for id in selectedImageIDs {
            entity(for: id)?.removeFromSuperview()
            imageViews.removeAll { $0.itemID == id }
        }
        selectedStrokes = []
        removeFloatingPreview()
        selectedImageIDs = []
        notifySelection()
        onContentChange?()
    }

    func pasteClipboard() {
        guard let clipboard, !clipboard.strokes.isEmpty || !clipboard.items.isEmpty else { return }
        pushHistory()
        let offset = CGPoint(x: 48, y: 48)
        let delta = CGAffineTransform.worldTranslation(offset)

        let strokes = transformStrokes(clipboard.strokes, by: delta)
        if !strokes.isEmpty {
            var drawing = canvasView.drawing
            drawing.strokes.append(contentsOf: strokes)
            setDrawing(drawing)
        }

        var newIDs: [UUID] = []
        for item in clipboard.items {
            let ext = AppPaths.fileExtension(of: URL(fileURLWithPath: item.fileName))
            let newFileName = AppPaths.newFileName(extension: ext)
            let srcURL = AppPaths.assetURL(item.fileName)
            let dstURL = AppPaths.assetURL(newFileName)
            try? FileManager.default.copyItem(at: srcURL, to: dstURL)
            if item.payload != nil {
                CanvasPayloadStore.duplicatePayload(from: item.fileName, to: newFileName)
            }
            let copy = CanvasImageItem(id: UUID(),
                                       fileName: newFileName,
                                       image: item.image,
                                       worldTransform: delta.concatenating(item.worldTransform),
                                       cropRect: item.cropRect,
                                       naturalSize: item.naturalSize,
                                       zIndex: nextZIndex(inFront: item.isInFront),
                                       payload: item.payload)
            let entity = makeEntity(copy)
            place(entity)
            newIDs.append(copy.id)
        }
        selectedImageIDs = newIDs
        selectedStrokes = []
        notifySelection()
        onContentChange?()
    }

    var hasClipboardContent: Bool {
        guard let clipboard else { return false }
        return !clipboard.strokes.isEmpty || !clipboard.items.isEmpty
    }

    // MARK: - 图层顺序（含"置于笔迹之上"）

    func bringSelectionToFront() {
        guard let id = selectedImageIDs.first, let entity = entity(for: id) else { return }
        pushHistory()
        entity.zIndex = nextZIndex(inFront: true)
        place(entity)
        normalizeZOrder()
        notifySelection()
        onContentChange?()
    }

    func sendSelectionToBack() {
        guard let id = selectedImageIDs.first, let entity = entity(for: id) else { return }
        pushHistory()
        let minBack = imageViews.filter { !$0.canvasItem.isInFront }.map(\.zIndex).min() ?? 0
        entity.zIndex = minBack - 1
        place(entity)
        normalizeZOrder()
        notifySelection()
        onContentChange?()
    }

    /// 同一图层内的下一个 zIndex。
    func nextZIndex(inFront: Bool) -> Int {
        if inFront {
            let maxFront = imageViews.filter(\.canvasItem.isInFront).map(\.zIndex).max()
            return max(maxFront.map { $0 + 1 } ?? CanvasLayers.frontBase, CanvasLayers.frontBase)
        }
        let maxBack = imageViews.filter { !$0.canvasItem.isInFront }.map(\.zIndex).max() ?? -1
        return maxBack + 1
    }

    /// 归一化：后层 0..n、前层 frontBase..frontBase+m，并按序重排子视图堆叠。
    func normalizeZOrder() {
        // 临时置顶（选中态）的实体不参与归位，否则选中态会被拽回下层。
        let back = imageViews
            .filter { !$0.canvasItem.isInFront && $0.superview !== selectionTopContainerView }
            .sorted { $0.zIndex < $1.zIndex }
        let front = imageViews
            .filter { $0.canvasItem.isInFront && $0.superview !== selectionTopContainerView }
            .sorted { $0.zIndex < $1.zIndex }
        for (index, entity) in back.enumerated() {
            entity.zIndex = index
            imageContainerView.addSubview(entity)
        }
        for (index, entity) in front.enumerated() {
            entity.zIndex = CanvasLayers.frontBase + index
            imageFrontContainerView.addSubview(entity)
        }
    }
}
