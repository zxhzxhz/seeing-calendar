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
    }

    func select(strokeIndices: [Int], imageIDs: [UUID]) {
        commitSelection(notify: false)
        let drawing = canvasView.drawing
        let strokes = strokeIndices
            .filter { $0 >= 0 && $0 < drawing.strokes.count }
            .map { drawing.strokes[$0] }

        selectedStrokes = strokes
        selectedImageIDs = imageIDs
        isGroupTransforming = false
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

    func selectionBounds() -> CGRect {
        var result = CGRect.null
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            let box = CanvasGeometry.boundingBox(entity.worldQuad)
            result = result.isNull ? box : result.union(box)
        }
        if !selectedStrokes.isEmpty {
            let box = strokesBounds(selectedStrokes)
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
            return .image(quad: entity(for: id)?.worldQuad ?? [])
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

    func transformStrokes(_ strokes: [PKStroke], by delta: CGAffineTransform) -> [PKStroke] {
        let uniform = max(0.01, sqrt(abs(delta.a * delta.d - delta.b * delta.c)))
        return strokes.compactMap { stroke in
            let count = stroke.path.count
            guard count > 0 else { return nil }
            var points: [PKStrokePoint] = []
            points.reserveCapacity(count)
            for index in 0..<count {
                let point = stroke.path[index]
                let location = point.location.applying(stroke.transform).applying(delta)
                points.append(PKStrokePoint(location: location,
                                            timeOffset: point.timeOffset,
                                            size: CGSize(width: point.size.width * uniform,
                                                         height: point.size.height * uniform),
                                            opacity: point.opacity,
                                            force: point.force,
                                            azimuth: point.azimuth,
                                            altitude: point.altitude))
            }
            return PKStroke(ink: stroke.ink,
                            path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                            transform: .identity,
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
            selectionOverlay.dismissMenu()
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
            isGroupTransforming = false
            cropBase = nil
        case .imageEdge:
            // 保持裁剪态，等待用户点“完成裁剪”；下次手势会重新采集基准。
            cropBase = nil
        case .groupCorner, .groupRotate:
            if let delta = groupAccumulatedDelta, delta != .identity {
                bakeStrokes(delta: delta)
            }
            groupAccumulatedDelta = nil
            isGroupTransforming = false
            groupBaseTransforms = [:]
        }
        gestureBaseTransform = nil
        notifySelection()
        onContentChange?()
    }

    // MARK: - 单图变换

    private func applyImageCornerScale(index: Int, point: CGPoint) {
        guard let id = effectiveImageID,
              let entity = entity(for: id),
              let base = gestureBaseTransform else { return }
        let baseInverse = base.inverted()
        let size = entity.visibleSize
        let localCorners = [CGPoint(x: 0, y: 0),
                            CGPoint(x: size.width, y: 0),
                            CGPoint(x: size.width, y: size.height),
                            CGPoint(x: 0, y: size.height)]
        guard index >= 0, index < localCorners.count else { return }
        let anchorLocal = localCorners[(index + 2) % 4]
        let cornerLocal = localCorners[index]
        let pointLocal = point.applying(baseInverse)

        let vectorX = cornerLocal.x - anchorLocal.x
        let vectorY = cornerLocal.y - anchorLocal.y
        let hasX = abs(vectorX) > 1
        let hasY = abs(vectorY) > 1
        var scaleX: CGFloat = hasX ? max(0.05, (pointLocal.x - anchorLocal.x) / vectorX) : 1
        var scaleY: CGFloat = hasY ? max(0.05, (pointLocal.y - anchorLocal.y) / vectorY) : 1
        // 四角手柄强制等比（spec：拖拽四角圆点默认锁定宽高比）
        if hasX && hasY {
            let uniform = abs(vectorX) >= abs(vectorY) ? scaleX : scaleY
            scaleX = uniform
            scaleY = uniform
        } else if hasX {
            scaleY = scaleX
        } else {
            scaleX = scaleY
        }

        // 缩放定义在图元**局部**坐标系、锚点为局部角点：
        // 正确写法是「局部 delta → 再 base」，实测可保证锚点不动且被拖角精确跟随手指。
        let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: scaleX, sy: scaleY)
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
        croppingImageID = id
        selectionKind = .cropping(id)
        refreshSelectionOverlay()
    }

    // MARK: - 复合选区整体变换

    private func applyGroupScale(index: Int, point: CGPoint) {
        let base = groupBaseBounds
        guard !base.isNull else { return }
        let corners = CanvasGeometry.corners(of: base)
        var anchor: CGPoint
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1

        if index < 4 {
            anchor = corners[(index + 2) % 4]
            let corner = corners[index]
            let vectorX = corner.x - anchor.x
            let vectorY = corner.y - anchor.y
            let hasX = abs(vectorX) > 1
            let hasY = abs(vectorY) > 1
            let candidateX = hasX ? max(0.05, (point.x - anchor.x) / vectorX) : 1
            let candidateY = hasY ? max(0.05, (point.y - anchor.y) / vectorY) : 1
            let uniform = abs(vectorX) >= abs(vectorY) ? candidateX : candidateY
            scaleX = uniform
            scaleY = uniform
        } else {
            switch index {
            case 4:
                anchor = CanvasGeometry.midpoint(corners[3], corners[2])
                scaleY = max(0.05, (anchor.y - point.y) / max(1, base.height))
            case 5:
                anchor = CanvasGeometry.midpoint(corners[0], corners[3])
                scaleX = max(0.05, (point.x - anchor.x) / max(1, base.width))
            case 6:
                anchor = CanvasGeometry.midpoint(corners[0], corners[1])
                scaleY = max(0.05, (point.y - anchor.y) / max(1, base.height))
            default:
                anchor = CanvasGeometry.midpoint(corners[1], corners[2])
                scaleX = max(0.05, (anchor.x - point.x) / max(1, base.width))
            }
        }

        applyGroupDelta(CGAffineTransform.worldScale(anchor: anchor, sx: scaleX, sy: scaleY))
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

    // MARK: - 套索

    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint]) {
        let snapshots = imageViews.map { UnifiedLassoArbitrator.ImageSnapshot(id: $0.itemID, quad: $0.worldQuad) }
        let result = UnifiedLassoArbitrator.evaluate(lasso: points, drawing: canvasView.drawing, images: snapshots)
        guard !result.strokeIndices.isEmpty || !result.imageIDs.isEmpty else {
            clearSelection()
            return
        }
        select(strokeIndices: result.strokeIndices, imageIDs: result.imageIDs)
    }

    // MARK: - 菜单动作

    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction) {
        switch action {
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
            let copy = CanvasImageItem(id: UUID(),
                                       fileName: item.fileName,
                                       image: item.image,
                                       worldTransform: delta.concatenating(item.worldTransform),
                                       cropRect: item.cropRect,
                                       naturalSize: item.naturalSize,
                                       zIndex: nextZIndex(inFront: item.isInFront))
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
