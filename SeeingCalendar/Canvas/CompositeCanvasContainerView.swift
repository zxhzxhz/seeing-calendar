import PencilKit
import UIKit

/// 触摸来源：用于区分 Apple Pencil 与手指（套索与橡皮指示圈都依赖它）。
enum TouchKind {
    case pencil
    case finger
    case unknown
}

/// 复合画布容器（Layer 0~6 的宿主）。
/// 核心职责：① 层级装配；② 触碰第一纳秒的贴图命中截流；③ 历史栈；④ 选区状态机入口。
@MainActor
final class CompositeCanvasContainerView: UIView {
    static let canvasSize = CGSize(width: 1400, height: 1400)

    let paperView = PaperBackgroundView()
    /// 笔迹之下的贴图层。
    let imageContainerView = UIView()
    let canvasView = TrackingCanvasView()
    /// 笔迹之上的贴图层（“置顶”后进入此层）。
    let imageFrontContainerView = UIView()
    /// 浮动选区内容（被取出的笔迹位图预览）。
    let selectionContentContainer = UIView()
    /// 选中贴图的**临时置顶**容器：保证选中态永远压在最上层，取消选中后归位。
    let selectionTopContainerView = UIView()
    let eraserIndicator = EraserIndicatorView()
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
    /// 原生菜单动作后的点击保护窗口。
    var menuActionGuardUntil: Date = .distantPast

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
        didSet {
            selectionOverlay.contentScale = overlayScale
            eraserIndicator.contentScale = overlayScale
        }
    }

    /// 橡皮是否处于激活状态（决定是否显示有效范围圈）。
    var isEraserActive: Bool = false {
        didSet {
            eraserIndicator.isHidden = !isEraserActive
            if !isEraserActive { eraserIndicator.update(point: nil) }
        }
    }

    /// 橡皮有效范围（画布世界坐标下的直径，与 PKEraserTool.width 保持一致）。
    var eraserWidth: CGFloat = 24 {
        didSet { eraserIndicator.eraserWidth = eraserWidth }
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

        addSubview(eraserIndicator)
        canvasView.onTouch = { [weak self] point, touchType in
            guard let self else { return }
            // 有效范围圈只在"这次触摸真的会擦除"时显示：
            // 橡皮激活 + （手指书写开启 或 这一下是 Apple Pencil）。
            // 手指开关关闭时用手指标橡皮既不擦除、也不该显示圆圈。
            let canErase = self.isFingerDrawingEnabled || touchType == .pencil
            let shouldShow = self.isEraserActive && canErase
            self.eraserIndicator.isHidden = !shouldShow
            self.eraserIndicator.update(point: shouldShow ? point : nil)
        }

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
        eraserIndicator.frame = CGRect(origin: .zero, size: size)
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

        let overlayPoint = convert(point, to: selectionOverlay)
        let kind = touchKind(in: event)

        // 1. 手柄 / 浮动菜单 / 变形态内部拖动区：手指与 Pencil 都可操作。
        //    （这是"手指开关关闭时手指仍可操控控制点"的实现路径。）
        if selectionOverlay.hitsInteractiveElement(overlayPoint),
           let hit = selectionOverlay.hitTest(overlayPoint, with: event) {
            return hit
        }

        // 2. Apple Pencil 在套索模式下：套索优先于贴图 —— 只有笔能画套索，
        //    笔尖落在贴图上时也应允许起手套索（套索重叠判定会把它圈进来）。
        if isLassoActive, kind == .pencil {
            return selectionOverlay
        }

        // 3. 贴图命中：临时置顶层 → 前置层 → 后置层，逆序遍历保证顶层优先；
        //    命中即短路 PKCanvasView 的绘制手势，从底座杜绝“选中贴图同时画出污点”。
        //    手指开关关闭时，手指点贴图依然进入贴图编辑态（需求 4）。
        for container in [selectionTopContainerView, imageFrontContainerView, imageContainerView] {
            for subview in container.subviews.reversed() {
                guard let entity = subview as? ImageEntityView, !entity.isHidden, entity.alpha > 0.01 else { continue }
                let local = entity.convert(point, from: self)
                if entity.bounds.contains(local) {
                    return entity
                }
            }
        }

        // 4. 手指在套索模式下：仅当"手指书写"开启时才由手指画套索；
        //    关闭时手指不画套索，落到画布层（画布在套索态不可写 → 等价于仅可平移缩放）。
        if isLassoActive, kind != .pencil, isFingerDrawingEnabled {
            return selectionOverlay
        }

        // 5. 空白区域交给 PencilKit（是否响应取决于 drawingPolicy / 是否处于导航态）
        guard canvasView.isUserInteractionEnabled else { return nil }
        return canvasView.hitTest(convert(point, to: canvasView), with: event)
    }

    /// 判定本次事件里的触摸来自 Apple Pencil 还是手指。
    /// 优先取"刚开始"的那一个触摸，避免多指场景下误判。
    private func touchKind(in event: UIEvent?) -> TouchKind {
        guard let touches = event?.allTouches, !touches.isEmpty else { return .unknown }
        let began = touches.filter { $0.phase == .began }
        let candidates = began.isEmpty ? touches : began
        if candidates.contains(where: { $0.type == .pencil }) { return .pencil }
        if candidates.contains(where: { $0.type == .direct }) { return .finger }
        return .unknown
    }

    @objc private func handleContainerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)

        // 刚从原生菜单点选动作后的一小段时间内忽略画布点击：
        // 菜单退场时可能把触摸透传下来，否则会立刻把刚建立的选择清掉（表现为“变形点了没反应”）。
        if Date() < menuActionGuardUntil { return }

        // 1) 手柄 / 浮动菜单：交给它们自己处理
        if selectionOverlay.hitsHandleOrMenu(point) { return }

        // 2) 点在贴图上 → 选中该贴图。
        //    - 变形态下**不改选对象**：用户约定"点框内保持变形态并弹菜单"；
        //    - 裁剪态下同样不改选，避免误触退出裁剪；
        //    - 套索态（非变形态）下触摸会被内部拖动区/套索层接管，贴图自身手势收不到事件，
        //      因此由容器代劳选中并弹菜单。
        if !isGroupTransforming, croppingImageID == nil {
            for entity in imageViews.reversed() where !entity.isHidden && entity.alpha > 0.01 {
                if entity.bounds.contains(entity.convert(point, from: self)) {
                    selectImage(id: entity.itemID, additive: false)
                    selectionOverlay.presentMenu()
                    return
                }
            }
        }

        // 3) 点在选区内（非手柄）：保持选中与当前模式，并弹出编辑菜单
        if selectionOverlay.containsSelection(point) {
            selectionOverlay.presentMenu()
            return
        }

        // 4) 点在选区之外：取消选中
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
            // 拖拽期间不重建手柄、不重弹菜单（由 tag/generation 守卫保证）。
            // 注意：这里**不能**调用 dismissMenu() —— 收起原生菜单会中断正在进行中的触摸，
            // 表现为「第一次拖动只走一下，第二次才正常」。
            self.isAdjustingSelection = true
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
            // 手指脱离后才把选中贴图重挂载到顶层容器（拖拽中重挂载会取消手势）。
            self.elevateSelection()
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
