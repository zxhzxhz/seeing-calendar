import PencilKit
import UIKit

/// 统一选区：状态机、跨图层变换、剪贴板与图层顺序。
extension CompositeCanvasContainerView: SelectionOverlayDelegate {
    // MARK: - 选区构建

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
        croppingImageID = nil
        cropBase = nil
        gestureBaseTransform = nil
        groupAccumulatedDelta = nil
        groupBaseTransforms = [:]
        removeFloatingPreview()
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

    func refreshSelectionOverlay() {
        let mode: SelectionOverlayView.Mode
        switch selectionKind {
        case .none:
            mode = .none
        case .composite:
            mode = .composite(selectionBounds())
        case .compositeTransform:
            mode = .compositeTransform(selectionBounds())
        case .image(let id):
            mode = .image(quad: entity(for: id)?.worldQuad ?? [])
        case .cropping(let id):
            mode = .cropping(quad: entity(for: id)?.worldQuad ?? [])
        }
        if selectionOverlay.mode == mode {
            selectionOverlay.refreshLayout()
        } else {
            selectionOverlay.update(mode: mode)
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
        let uniform = max(0.01, sqrt(abs(delta.a * delta.d - delta.b * delta.c)))
        var updated: [PKStroke] = []
        updated.reserveCapacity(selectedStrokes.count)
        for stroke in selectedStrokes {
            let count = stroke.path.count
            guard count > 0 else { continue }
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
            let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
            updated.append(PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: stroke.mask))
        }
        selectedStrokes = updated
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
            guard let id = selectedImageIDs.first, let entity = entity(for: id) else { return }
            gestureBaseTransform = entity.worldTransform
            if case .imageEdge = kind {
                croppingImageID = id
                cropBase = (entity.cropRect, entity.worldTransform, entity.naturalSize)
            }
        case .groupCorner, .groupRotate:
            gestureBaseTransform = .identity
            groupBaseBounds = selectionBounds()
            groupBaseTransforms = imageViews.reduce(into: [:]) { partial, view in
                if selectedImageIDs.contains(view.itemID) { partial[view.itemID] = view.worldTransform }
            }
        }
        if case .imageCorner = kind {
            cropBase = nil
            isGroupTransforming = false
        }
        // 变换前的状态必须先入栈，保证缩放/旋转/裁剪可撤销。
        pushHistory()
    }

    private func updateHandleGesture(_ kind: SelectionHandleKind, point: CGPoint) {
        switch kind {
        case .imageCorner(let index):
            applyImageCornerScale(index: index, point: point)
        case .imageEdge(let index):
            applyCrop(edge: index, point: point)
        case .imageRotate:
            applyImageRotation(point: point)
        case .groupCorner(let index):
            applyGroupScale(index: index, point: point)
        case .groupRotate:
            applyGroupRotation(point: point)
        }
    }

    private func endHandleGesture(_ kind: SelectionHandleKind) {
        switch kind {
        case .imageCorner, .imageRotate:
            isGroupTransforming = false
        case .imageEdge:
            croppingImageID = nil
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
        guard let id = selectedImageIDs.first,
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
        // 四角手柄强制等比 (spec: 拖拽四角圆点默认锁定宽高比)
        if hasX && hasY {
            let uniform = abs(vectorX) >= abs(vectorY) ? scaleX : scaleY
            scaleX = uniform
            scaleY = uniform
        } else if hasX {
            scaleY = scaleX
        } else {
            scaleX = scaleY
        }

        let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: scaleX, sy: scaleY)
        let worldDelta = base.concatenating(localDelta).concatenating(baseInverse)
        entity.update(transform: worldDelta.concatenating(base))
        refreshSelectionOverlay()
    }

    private func applyImageRotation(point: CGPoint) {
        guard let id = selectedImageIDs.first,
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
        let delta = CGAffineTransform.worldRotation(center: center, angle: snapped.angle - baseRotation)
        entity.update(transform: delta.concatenating(base))
        refreshSelectionOverlay()
    }

    // MARK: - 无损裁剪（视窗）拖拽

    private func applyCrop(edge index: Int, point: CGPoint) {
        guard let id = croppingImageID ?? selectedImageIDs.first,
              let entity = entity(for: id),
              let base = cropBase else { return }
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
        let minimumSize: CGFloat = 24

        switch index {
        case 0: minY = min(max(0, original.y), maxY - minimumSize)
        case 1: maxX = max(min(base.natural.width, original.x), minX + minimumSize)
        case 2: maxY = max(min(base.natural.height, original.y), minY + minimumSize)
        case 3: minX = min(max(0, original.x), maxX - minimumSize)
        default: break
        }

        let newCrop = CGRect(x: minX / base.natural.width,
                             y: minY / base.natural.height,
                             width: max(0.02, (maxX - minX) / base.natural.width),
                             height: max(0.02, (maxY - minY) / base.natural.height))
        let translation = CGAffineTransform(translationX: base.natural.width * (newCrop.origin.x - base.crop.origin.x),
                                            y: base.natural.height * (newCrop.origin.y - base.crop.origin.y))
        entity.update(cropRect: newCrop, worldTransform: translation.concatenating(base.transform))
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
        let baseBounds = groupBaseBounds
        guard !baseBounds.isNull else { return }
        let center = CGPoint(x: baseBounds.midX, y: baseBounds.midY)
        let startAngle = atan2(gestureBasePoint.y - center.y, gestureBasePoint.x - center.x)
        let currentAngle = atan2(point.y - center.y, point.x - center.x)
        let snapped = CanvasGeometry.snappedAngle(currentAngle - startAngle)
        let delta = CGAffineTransform.worldRotation(center: center, angle: snapped.angle)
        applyGroupDelta(delta)
    }

    private func applyGroupDelta(_ delta: CGAffineTransform) {
        groupAccumulatedDelta = delta
        isGroupTransforming = true
        for (id, base) in groupBaseTransforms {
            entity(for: id)?.update(transform: delta.concatenating(base))
        }
        floatingPreview?.transform = delta
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
        var zIndex = (imageViews.map(\.zIndex).max() ?? -1) + 1
        for item in clipboard.items {
            let copy = CanvasImageItem(id: UUID(),
                                       fileName: item.fileName,
                                       image: item.image,
                                       worldTransform: delta.concatenating(item.worldTransform),
                                       cropRect: item.cropRect,
                                       naturalSize: item.naturalSize,
                                       zIndex: zIndex)
            zIndex += 1
            let entity = makeEntity(copy)
            imageContainerView.addSubview(entity)
            imageViews.append(entity)
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

    // MARK: - 图层顺序

    func bringSelectionToFront() {
        guard let id = selectedImageIDs.first else { return }
        pushHistory()
        if let entity = entity(for: id) {
            imageViews.removeAll { $0.itemID == id }
            imageViews.append(entity)
            imageContainerView.bringSubviewToFront(entity)
        }
        normalizeZOrder()
        notifySelection()
        onContentChange?()
    }

    func sendSelectionToBack() {
        guard let id = selectedImageIDs.first else { return }
        pushHistory()
        if let entity = entity(for: id) {
            imageViews.removeAll { $0.itemID == id }
            imageViews.insert(entity, at: 0)
            imageContainerView.sendSubviewToBack(entity)
        }
        normalizeZOrder()
        notifySelection()
        onContentChange?()
    }

    func normalizeZOrder() {
        for (index, entity) in imageViews.enumerated() {
            entity.zIndex = index
        }
    }
}
