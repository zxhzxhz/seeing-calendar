import PencilKit
import UIKit

/// 复合画布容器（Layer 0~6 的宿主）。
/// 核心职责：① 层级装配；② 触碰第一纳秒的贴图命中截流；③ 历史栈；④ 选区状态机入口。
@MainActor
final class CompositeCanvasContainerView: UIView {
    static let canvasSize = CGSize(width: 1400, height: 1400)

    let paperView = PaperBackgroundView()
    /// 笔迹之下的贴图层。
    let imageContainerView = UIView()
    let canvasView = PKCanvasView()
    /// 笔迹之上的贴图层（“置顶”后进入此层）。
    let imageFrontContainerView = UIView()
    /// 浮动选区内容（被取出的笔迹位图预览）。
    let selectionContentContainer = UIView()
    /// 选中贴图的**临时置顶**容器：保证选中态永远压在最上层，取消选中后归位。
    let selectionTopContainerView = UIView()
    let selectionOverlay = SelectionOverlayView()

    var onContentChange: (() -> Void)?
    var onSelectionChange: ((CanvasSelectionKind) -> Void)?
    var onHistoryChange: ((Bool, Bool) -> Void)?
    var onRequestImageReplace: ((UUID) -> Void)?

    var imageViews: [ImageEntityView] = []

    // 历史栈
    private var history: [CanvasSnapshot] = []
    private var redoStack: [CanvasSnapshot] = []
    private let historyLimit = 30
    private var isProgrammatic = false
    private var isToolSessionActive = false

    // 选区状态
    var selectedImageIDs: [UUID] = []
    var selectedStrokes: [PKStroke] = []
    var selectionKind: CanvasSelectionKind = .none
    var isGroupTransforming = false
    /// 任何「正在拖拽选区」的状态（手柄 / 贴图位移 / 整体变换）——
    /// 期间只做几何更新，绝不重建手柄，也绝不重弹菜单。
    var isAdjustingSelection = false
    var croppingImageID: UUID?
    var floatingPreview: UIImageView?
    var gestureBaseTransform: CGAffineTransform?
    var gestureBasePoint: CGPoint = .zero
    var clipboard: CanvasClipboard?
    var cropBase: (crop: CGRect, transform: CGAffineTransform, natural: CGSize)?
    var groupBaseBounds: CGRect = .null
    var groupBaseTransforms: [UUID: CGAffineTransform] = [:]
    var groupAccumulatedDelta: CGAffineTransform?

    /// 是否允许在画布上落笔（取消全部工具后即为「导航态」：只平移缩放）。
    var isDrawingEnabled: Bool = true {
        didSet {
            guard oldValue != isDrawingEnabled else { return }
            updateInteractionPolicy()
        }
    }

    var isFingerDrawingEnabled: Bool = false {
        didSet {
            guard oldValue != isFingerDrawingEnabled else { return }
            updateDrawingPolicy()
        }
    }

    var isLassoActive: Bool = false {
        didSet {
            guard oldValue != isLassoActive else { return }
            selectionOverlay.isLassoActive = isLassoActive
            updateInteractionPolicy()
            if isLassoActive, !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
                // 套索与笔墨互斥：进入套索即退出选区编辑态。
                // 延后一拍执行，避免在 SwiftUI 更新回合内回调可观察状态。
                Task { @MainActor [weak self] in
                    guard let self, self.isLassoActive else { return }
                    self.commitSelection(notify: true)
                }
            }
        }
    }

    var overlayScale: CGFloat = 1 {
        didSet { selectionOverlay.contentScale = overlayScale }
    }

    // MARK: - 生命周期

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .white

        addSubview(paperView)
        imageContainerView.backgroundColor = .clear
        addSubview(imageContainerView)

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .pencilOnly
        canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
        canvasView.contentSize = Self.canvasSize
        addSubview(canvasView)

        imageFrontContainerView.backgroundColor = .clear
        addSubview(imageFrontContainerView)

        selectionContentContainer.backgroundColor = .clear
        selectionContentContainer.isUserInteractionEnabled = false
        addSubview(selectionContentContainer)

        selectionTopContainerView.backgroundColor = .clear
        addSubview(selectionTopContainerView)

        selectionOverlay.delegate = self
        addSubview(selectionOverlay)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleContainerTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        paperView.frame = CGRect(origin: .zero, size: size)
        imageContainerView.frame = CGRect(origin: .zero, size: size)
        canvasView.frame = CGRect(origin: .zero, size: size)
        imageFrontContainerView.frame = CGRect(origin: .zero, size: size)
        selectionContentContainer.frame = CGRect(origin: .zero, size: size)
        selectionTopContainerView.frame = CGRect(origin: .zero, size: size)
        selectionOverlay.frame = CGRect(origin: .zero, size: size)
    }

    private func updateDrawingPolicy() {
        canvasView.drawingPolicy = isFingerDrawingEnabled ? .anyInput : .pencilOnly
    }

    private func updateInteractionPolicy() {
        canvasView.isUserInteractionEnabled = isDrawingEnabled && !isLassoActive
    }

    // MARK: - 触控仲裁（spec 3.1 核心）

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }

        // 1. 选区覆盖层优先（手柄 / 套索捕获）
        let overlayPoint = convert(point, to: selectionOverlay)
        if selectionOverlay.point(inside: overlayPoint, with: event),
           let hit = selectionOverlay.hitTest(overlayPoint, with: event) {
            return hit
        }

        // 2. 贴图命中：临时置顶层 → 前置层 → 后置层，逆序遍历保证顶层优先；
        //    命中即短路 PKCanvasView 的绘制手势，从底座杜绝“选中贴图同时画出污点”。
        for container in [selectionTopContainerView, imageFrontContainerView, imageContainerView] {
            for subview in container.subviews.reversed() {
                guard let entity = subview as? ImageEntityView, !entity.isHidden, entity.alpha > 0.01 else { continue }
                let local = entity.convert(point, from: self)
                if entity.bounds.contains(local) {
                    return entity
                }
            }
        }

        // 3. 空白区域交给 PencilKit（是否响应取决于 drawingPolicy / 是否处于导航态）
        guard canvasView.isUserInteractionEnabled else { return nil }
        return canvasView.hitTest(convert(point, to: canvasView), with: event)
    }

    @objc private func handleContainerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)

        // 落在选区手柄 / 原生菜单上：不参与“点空白取消选择”
        if selectionOverlay.hitsInteractiveElement(point) { return }

        // 落在贴图上：交给贴图自身的点选逻辑
        for entity in imageViews.reversed() where !entity.isHidden && entity.alpha > 0.01 {
            if entity.bounds.contains(entity.convert(point, from: self)) { return }
        }
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            clearSelection()
        }
    }

    // MARK: - 内容装载

    func load(drawing: PKDrawing, items: [CanvasImageItem], resetHistory: Bool = true) {
        // 切换页面：直接丢弃浮动选区，绝不把上一页的笔迹并入本页。
        discardSelection()
        setDrawing(drawing)
        rebuildImageViews(items)
        if resetHistory {
            history.removeAll()
            redoStack.removeAll()
            notifyHistory()
        }
        notifySelection()
    }

    /// 快照必须包含“浮动选区中的笔迹”，否则撤销/重做会丢内容。
    func snapshot() -> CanvasSnapshot {
        var drawing = canvasView.drawing
        if !selectedStrokes.isEmpty {
            drawing.strokes.append(contentsOf: selectedStrokes)
        }
        return CanvasSnapshot(drawing: drawing, items: currentItems())
    }

    func currentItems() -> [CanvasImageItem] {
        imageViews.map(\.canvasItem).sorted { $0.zIndex < $1.zIndex }
    }

    func setDrawing(_ drawing: PKDrawing) {
        isProgrammatic = true
        canvasView.drawing = drawing
        isProgrammatic = false
    }

    func rebuildImageViews(_ items: [CanvasImageItem]) {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []

        let sorted = items.sorted { $0.zIndex < $1.zIndex }
        let back = sorted.filter { !$0.isInFront }
        let front = sorted.filter(\.isInFront)

        for (index, item) in back.enumerated() {
            var normalized = item
            normalized.zIndex = index
            let entity = makeEntity(normalized)
            imageContainerView.addSubview(entity)
            imageViews.append(entity)
        }
        for (index, item) in front.enumerated() {
            var normalized = item
            normalized.zIndex = CanvasLayers.frontBase + index
            let entity = makeEntity(normalized)
            imageFrontContainerView.addSubview(entity)
            imageViews.append(entity)
        }
    }

    func makeEntity(_ item: CanvasImageItem) -> ImageEntityView {
        let entity = ImageEntityView(item: item)
        entity.onSelect = { [weak self] view in
            self?.selectImage(id: view.itemID, additive: false)
        }
        entity.onBeginMove = { [weak self] view in
            guard let self else { return }
            // 拖拽期间不重建手柄、不弹菜单：先收起菜单，手指脱离后再弹。
            self.isAdjustingSelection = true
            self.selectionOverlay.dismissMenu()
            self.pushHistory()
            _ = view
        }
        entity.onTransformChanged = { [weak self] _ in
            guard let self else { return }
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }
        entity.onEndMove = { [weak self] _ in
            guard let self else { return }
            self.isAdjustingSelection = false
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }
        return entity
    }

    /// 按图层归属放置视图；`elevated` 表示临时置顶（选中态）。
    func place(_ entity: ImageEntityView, elevated: Bool = false) {
        let wasElevated = entity.superview === selectionTopContainerView
        entity.removeFromSuperview()
        if elevated {
            selectionTopContainerView.addSubview(entity)
        } else if entity.zIndex >= CanvasLayers.frontBase {
            imageFrontContainerView.addSubview(entity)
        } else {
            imageContainerView.addSubview(entity)
        }
        if !imageViews.contains(where: { $0.itemID == entity.itemID }) {
            imageViews.append(entity)
        }
        if wasElevated != elevated {
            selectionTopContainerView.isUserInteractionEnabled = true
        }
    }

    /// 取消选中：把所有临时置顶的贴图归位并撤掉高亮。
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
    }

    // MARK: - 历史

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 压入历史：快照已自包含浮动笔迹，因此无需打断当前选区。
    func pushHistory() {
        history.append(snapshot())
        if history.count > historyLimit { history.removeFirst() }
        redoStack.removeAll()
        notifyHistory()
    }

    func undo() {
        // 先把浮动选区落回画布，保证快照语义完整（否则撤销会丢失被选中的笔迹）。
        commitSelection(notify: false)
        guard let previous = history.popLast() else {
            notifyHistory()
            return
        }
        redoStack.append(snapshot())
        apply(previous)
        notifyHistory()
    }

    func redo() {
        commitSelection(notify: false)
        guard let next = redoStack.popLast() else {
            notifyHistory()
            return
        }
        history.append(snapshot())
        apply(next)
        notifyHistory()
    }

    private func apply(_ snapshot: CanvasSnapshot) {
        discardSelection()
        setDrawing(snapshot.drawing)
        rebuildImageViews(snapshot.items)
        notifySelection()
        onContentChange?()
    }

    private func notifyHistory() {
        onHistoryChange?(canUndo, canRedo)
    }

    func notifySelection() {
        let kind: CanvasSelectionKind
        if let croppingImageID {
            kind = .cropping(croppingImageID)
        } else if isGroupTransforming, !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            kind = .compositeTransform
        } else if selectedImageIDs.count == 1, selectedStrokes.isEmpty {
            kind = .image(selectedImageIDs[0])
        } else if selectedImageIDs.isEmpty, selectedStrokes.isEmpty {
            kind = .none
        } else {
            kind = .composite
        }
        selectionKind = kind
        onSelectionChange?(kind)
        refreshSelectionOverlay()
    }

    // MARK: - 贴图 API

    @discardableResult
    func addImage(_ image: UIImage, fileName: String, offset: CGPoint = .zero) -> UUID {
        pushHistory()
        let natural = CGSize(width: max(1, image.size.width * image.scale),
                             height: max(1, image.size.height * image.scale))
        let transform = Self.entranceTransform(naturalSize: natural, offset: offset)
        let nextZ = nextZIndex(inFront: false)
        let item = CanvasImageItem(id: UUID(),
                                   fileName: fileName,
                                   image: image,
                                   worldTransform: transform,
                                   cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   naturalSize: natural,
                                   zIndex: nextZ)
        let entity = makeEntity(item)
        place(entity)
        selectImage(id: item.id, additive: false)
        onContentChange?()
        return item.id
    }

    /// 智能入场缩放：不超画布则 1:1 居中；超出则按 Aspect Fit 落入 90% 安全区。
    static func entranceTransform(naturalSize: CGSize, offset: CGPoint = .zero) -> CGAffineTransform {
        let canvas = canvasSize
        var scale: CGFloat = 1
        if naturalSize.width > canvas.width || naturalSize.height > canvas.height {
            let safeWidth = canvas.width * 0.9
            let safeHeight = canvas.height * 0.9
            scale = min(safeWidth / naturalSize.width, safeHeight / naturalSize.height)
        }
        let size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        let origin = CGPoint(x: (canvas.width - size.width) / 2 + offset.x,
                             y: (canvas.height - size.height) / 2 + offset.y)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
    }

    func entity(for id: UUID) -> ImageEntityView? {
        imageViews.first { $0.itemID == id }
    }

    /// 删除全部内容（清空当前页）。
    func clearAll() {
        pushHistory()
        commitSelection(notify: false)
        setDrawing(PKDrawing())
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
        notifySelection()
        onContentChange?()
    }

    func replaceImage(id: UUID, image: UIImage, fileName: String) {
        guard let entity = entity(for: id) else { return }
        pushHistory()
        let natural = CGSize(width: max(1, image.size.width * image.scale),
                             height: max(1, image.size.height * image.scale))
        // 保持画面中心与可见尺寸，替换为原图比例的等价变换
        let currentCenter = entity.worldCenter
        let currentSize = entity.visibleSize
        let scale = min(currentSize.width / natural.width, currentSize.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        let rotation = entity.worldTransform.rotationAngle
        let cosinus = cos(rotation)
        let sinus = sin(rotation)
        let transform = CGAffineTransform(a: scale * cosinus, b: scale * sinus,
                                          c: -scale * sinus, d: scale * cosinus,
                                          tx: currentCenter.x - (scale * cosinus * size.width / 2 - scale * sinus * size.height / 2),
                                          ty: currentCenter.y - (scale * sinus * size.width / 2 + scale * cosinus * size.height / 2))
        let item = CanvasImageItem(id: entity.itemID,
                                   fileName: fileName,
                                   image: image,
                                   worldTransform: transform,
                                   cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   naturalSize: natural,
                                   zIndex: entity.zIndex)
        entity.removeFromSuperview()
        imageViews.removeAll { $0.itemID == id }
        let replacement = makeEntity(item)
        place(replacement)
        selectImage(id: id, additive: false)
        onContentChange?()
    }
}

// MARK: - PKCanvasViewDelegate

extension CompositeCanvasContainerView: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard !isToolSessionActive else { return }
        isToolSessionActive = true
        // 落笔即视为退出选区编辑态（等价于“点按空白处取消选中”）。
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            commitSelection(notify: true)
        }
        pushHistory()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isToolSessionActive = false
        onContentChange?()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isProgrammatic else { return }
        // 画布内容一旦变化，说明用户在用笔/橡皮 —— 等价于“点按空白处”，选区随即失效。
        // 该路径不依赖手势共存仲裁，因此“手指书写开启”时同样可靠。
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            commitSelection(notify: true)
        }
        onContentChange?()
    }
}
