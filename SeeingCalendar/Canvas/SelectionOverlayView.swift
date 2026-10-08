import UIKit

@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction)
    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragHandle kind: SelectionHandleKind,
                          to point: CGPoint,
                          state: UIGestureRecognizer.State)
    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint])
    /// 变形态下拖动选区内部：整体平移。
    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragInterior point: CGPoint,
                          state: UIGestureRecognizer.State)
}

/// 顶层统一选区交互层：虚线框 / 8 向手柄 / 旋转锚点 / **自绘浮动编辑菜单** / 自定义套索捕获 / 内部拖动。
///
/// 手势路由（v1.0.5 修正，三处真机问题都出在这一层）：
/// 1. 手柄与内部拖动区是**两个不同的视图**，手柄在其之上 —— 触摸手柄不会被内部拖动"覆盖"；
/// 2. `hitTest` 先让子视图（手柄/菜单/内部区）出手，**即使处于套索模式**，最后才由覆盖层自己接管套索；
/// 3. 套索模式下，从已有选区内部开始的触摸不产生新套索。
@MainActor
final class SelectionOverlayView: UIView {
    enum Mode: Equatable {
        case none
        case composite(CGRect)
        case image(quad: [CGPoint], canEdit: Bool = false)
        case compositeTransform(CGRect)
        case cropping(quad: [CGPoint])

        /// 同一形态内的几何变化（拖拽中）只重排不重建，避免打断进行中的手势。
        var shapeTag: Int {
            switch self {
            case .none: return 0
            case .composite: return 1
            case .image: return 2
            case .compositeTransform: return 3
            case .cropping: return 4
            }
        }

        var isSingleImage: Bool {
            if case .image = self { return true }
            return false
        }
    }

    weak var delegate: SelectionOverlayDelegate?

    var contentScale: CGFloat = 1 {
        didSet { refreshLayout() }
    }

    var isLassoActive: Bool = false {
        didSet {
            if !isLassoActive {
                lassoPoints.removeAll()
                lassoLayer.path = nil
                isCapturingLasso = false
            }
        }
    }

    /// 手指是否可参与套索（= 编辑器里的「手指书写」开关）。
    /// 关闭时仅 Apple Pencil 能画套索；手指的触摸由覆盖层接收但**不产生套索**，
    /// 从而不阻断容器自身的点选/取消选中逻辑。
    var allowsFingerLasso: Bool = true

    private(set) var mode: Mode = .none
    private let marqueeLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    /// 变换基准点标记（缩放/旋转的不动点 = 选区正中心）。
    private let pivotLayer = CAShapeLayer()
    private var handleViews: [SelectionHandleView] = []
    private var lassoPoints: [CGPoint] = []
    private var isCapturingLasso = false
    /// 自绘浮动菜单（替代系统编辑菜单，见 `SelectionMenuView` 顶部注释）。
    private var menuView: SelectionMenuView?
    private var menuActions: [SelectionAction] = []

    /// 菜单与选区之间的**净间距**（屏幕 pt）。产品要求：不得压住控制点。
    /// 下方只需让开边缘/角落手柄（高 10~16pt，向下不超出选区外）。
    static let menuGap: CGFloat = 32
    /// 上方还要额外让开**旋转锚点** —— 它悬在选区上缘外 34pt（基准偏移）、自身高 28pt，
    /// 实际伸到 48pt；故上方的间距必须比下方大，否则菜单会压在旋转控制点上。
    static let menuGapAbove: CGFloat = 52
    /// 上下都放不下时，菜单落在选区**内部**、距上边缘的距离（屏幕 pt）。
    static let menuInnerInset: CGFloat = 10

    /// 内部拖动区：独立子视图，保证它的手势不会"盖住"其上的手柄。
    private let interiorView = SelectionInteriorView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        marqueeLayer.strokeColor = UIColor.systemBlue.cgColor
        marqueeLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        marqueeLayer.lineWidth = 1.5
        marqueeLayer.lineDashPattern = [6, 4]
        layer.addSublayer(marqueeLayer)

        lassoLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineJoin = .round
        layer.addSublayer(lassoLayer)

        pivotLayer.strokeColor = UIColor.systemBlue.cgColor
        pivotLayer.fillColor = UIColor.clear.cgColor
        pivotLayer.lineWidth = 1.5
        layer.addSublayer(pivotLayer)

        addSubview(interiorView)
        interiorView.addGestureRecognizer(interiorPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 命中判定

    /// 覆盖层自身是否愿意接收该点（子视图由 hitTest 处理）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitsInteractiveElement(point) { return true }
        // 其余区域仅在套索模式下由覆盖层接管（用于绘制新套索）。
        return isLassoActive
    }

    /// 关键：先让子视图出手（手柄 / 菜单 / 内部拖动区），**即使处于套索模式**；
    /// 都未命中时才由覆盖层自己接管套索。否则套索模式下手柄永远点不到。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 手柄的 44pt 判定区在小图上会互相重叠，此时必须按「离哪个手柄中心最近」来裁决。
        // 关键：手柄必须**立即胜出**，不能被下层的内部拖动区接管
        // （此前先收集手柄再继续扫描，底层 interiorView 会把触摸抢走 → 表现为「只有右下角手柄有作用」）。
        var nearestHandle: (view: SelectionHandleView, distance: CGFloat)?
        for subview in subviews.reversed() where !subview.isHidden && subview.alpha > 0.01 {
            let local = convert(point, to: subview)
            guard subview.point(inside: local, with: event) else { continue }
            if let handle = subview as? SelectionHandleView {
                let distance = hypot(local.x - handle.bounds.midX, local.y - handle.bounds.midY)
                if nearestHandle == nil || distance < nearestHandle!.distance {
                    nearestHandle = (handle, distance)
                }
                continue
            }
            if let nearestHandle { return nearestHandle.view }
            if let hit = subview.hitTest(local, with: event) { return hit }
        }
        if let nearestHandle { return nearestHandle.view }
        return isLassoActive ? self : nil
    }

    /// 该点是否落在当前选区内部（复合框 / 单图框 / 裁剪框）。
    /// 用于：选区内点击保持选中与模式（取消选中只发生在点选区之外时）。
    func containsSelection(_ point: CGPoint) -> Bool {
        let rect: CGRect?
        switch mode {
        case .none:
            rect = nil
        case .composite(let box), .compositeTransform(let box):
            rect = box
        case .image(let quad, _), .cropping(let quad):
            let box = CanvasGeometry.boundingBox(quad)
            rect = box.isNull ? nil : box
        }
        guard let rect else { return false }
        return rect.insetBy(dx: -8, dy: -8).contains(point)
    }

    /// 命中测试：仅判定「手柄 / 菜单 / 内部拖动区」等真实交互元素。
    /// 供容器判断「这次点击是否应取消选区」。
    func hitsInteractiveElement(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }

    /// 只判定手柄/菜单（**不含**内部拖动区）：用于区分「点在手柄上」与「点在选区内」。
    func hitsHandleOrMenu(_ point: CGPoint) -> Bool {
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 && subview !== interiorView {
            if subview.point(inside: convert(point, to: subview), with: nil) { return true }
        }
        return false
    }

    /// 用户主动唤出菜单（点按选区内部/贴图时调用）。
    /// **立即呈现**：自绘菜单不需要等系统菜单退场动画，因此没有任何延时。
    func presentMenu() {
        presentMenuNow()
    }

    // MARK: - 外部查询与控制

    /// 主动收起菜单。
    ///
    /// 只淡出并隐藏，**不销毁视图** —— 视图留着，下一次弹出就能复用同一批按钮
    /// （`SelectionMenuView.configure` 在动作集不变时不重建），
    /// 于是"再点一下图片"是真正的零布局开销，不会闪一下。
    func dismissMenu(animated: Bool = true) {
        guard let menu = menuView, !menu.isHidden else { return }
        if animated {
            UIView.animate(withDuration: 0.12) {
                menu.alpha = 0
            } completion: { _ in
                // 若期间又被重新弹出（alpha 被改回 1），不隐藏。
                if menu.alpha < 0.01 { menu.isHidden = true }
            }
        } else {
            menu.alpha = 0
            menu.isHidden = true
        }
    }

    // MARK: - 状态更新

    /// 形态或菜单集合发生变化：重建手柄与菜单。
    func update(mode: Mode) {
        self.mode = mode
        handleViews.forEach { $0.removeFromSuperview() }
        handleViews = []
        menuActions = menuActions(for: mode)

        switch mode {
        case .none:
            marqueeLayer.path = nil
            marqueeLayer.isHidden = true
        default:
            marqueeLayer.isHidden = false
            for (kind, _) in handleLayout() {
                let handle = SelectionHandleView(kind: kind, baseSize: baseSize(for: kind))
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                handle.addGestureRecognizer(pan)
                addSubview(handle)          // 手柄始终位于 interiorView 之上
                handleViews.append(handle)
            }
        }
        refreshLayout()
        // 形态切换时立即重建并呈现：自绘菜单无需等待系统菜单退场，真正做到"即时弹出"。
        if autoPresentsMenu, !menuActions.isEmpty {
            presentMenuNow()
        } else {
            dismissMenu()
        }
    }

    /// 仅几何变化（拖拽过程中）：不重建手柄，只重排 —— 否则进行中的手势会被立刻打断。
    func updateGeometry(_ mode: Mode) {
        guard mode.shapeTag == self.mode.shapeTag else {
            update(mode: mode)
            return
        }
        self.mode = mode
        refreshLayout()
    }

    func refreshLayout() {
        let scale = max(0.05, contentScale)
        marqueeLayer.lineWidth = 1.5 * scale
        marqueeLayer.lineDashPattern = [NSNumber(value: Double(6 * scale)), NSNumber(value: Double(4 * scale))]

        switch mode {
        case .none:
            marqueeLayer.path = nil
        case .composite(let rect), .compositeTransform(let rect):
            marqueeLayer.path = UIBezierPath(rect: rect).cgPath
        case .image(let quad, _), .cropping(let quad):
            marqueeLayer.path = CanvasGeometry.path(points: quad)
        }

        updatePivotLayer(scale: scale)

        let layout = handleLayout()
        for handle in handleViews {
            guard let position = layout[handle.kind] else { continue }
            handle.transform = .identity
            handle.bounds = CGRect(origin: .zero, size: handle.baseSize)
            handle.center = position
            handle.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        // 内部拖动区：仅「变形态」激活（其余状态不许直接拖动选中对象）。
        interiorView.isActive = isInteriorDraggable
        interiorView.region = compositeRect ?? .null

        // 几何变化（拖拽/缩放中）只让菜单跟随重排，不重建、不重弹。
        repositionMenu()
    }

    /// 基准点：单选/复合变形都以包围盒中心为不动点，这里把它画出来（圆 + 十字）。
    private func updatePivotLayer(scale: CGFloat) {
        guard let center = pivotPoint() else {
            pivotLayer.path = nil
            return
        }
        let radius = 7 * scale
        let arm = 11 * scale
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        pivotLayer.path = path
        pivotLayer.lineWidth = 1.5 * scale
    }

    /// 变换不动点。单图与复合选区的缩放/旋转都以它为中心。
    func pivotPoint() -> CGPoint? {
        switch mode {
        case .none, .composite:
            return nil
        case .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.midY)
        case .cropping(let quad):
            guard quad.count == 4 else { return nil }
            let box = CanvasGeometry.boundingBox(quad)
            return CGPoint(x: box.midX, y: box.midY)
        case .image(let quad, _):
            guard quad.count == 4 else { return nil }
            let box = CanvasGeometry.boundingBox(quad)
            return CGPoint(x: box.midX, y: box.midY)
        }
    }

    // MARK: - 内部拖动（仅变形态）

    private lazy var interiorPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleInteriorPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        return pan
    }()

    @objc private func handleInteriorPan(_ gesture: UIPanGestureRecognizer) {
        guard isInteriorDraggable else { return }
        delegate?.selectionOverlay(self, didDragInterior: gesture.location(in: self), state: gesture.state)
    }

    /// 只有「变形」态才允许拖动选区内部整体平移。
    var isInteriorDraggable: Bool {
        if case .compositeTransform = mode { return true }
        return false
    }

    /// 复合选区的世界包围盒。
    private var compositeRect: CGRect? {
        switch mode {
        case .composite(let rect), .compositeTransform(let rect): return rect
        default: return nil
        }
    }

    // MARK: - 浮动菜单（自绘，取代系统编辑菜单）

    /// 当前选区的世界坐标包围盒。
    private func selectionBounds() -> CGRect? {
        let box: CGRect
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            box = rect
        case .image(let quad, _), .cropping(let quad):
            box = CanvasGeometry.boundingBox(quad)
        }
        return box.isNull ? nil : box
    }

    /// 覆盖层坐标下的「可见画布区域」。
    /// 菜单的上下空间判定必须基于**视口**而不是 1400×1400 的整张画布。
    private func visibleViewport() -> CGRect? {
        guard let container = superview,
              let scroll = container.superview as? UIScrollView else { return nil }
        return scroll.convert(scroll.bounds, to: self)
    }

    /// 立即呈现菜单（无任何延时）。
    private func presentMenuNow() {
        guard !menuActions.isEmpty, let selection = selectionBounds() else {
            dismissMenu()
            return
        }

        let menu: SelectionMenuView
        if let existing = menuView {
            menu = existing
        } else {
            let created = SelectionMenuView()
            created.onSelect = { [weak self] action in
                guard let self else { return }
                // 先收菜单再执行动作：否则动作里重建的选区会与旧菜单同屏共存。
                self.dismissMenu(animated: false)
                self.delegate?.selectionOverlay(self, didSelect: action)
            }
            menuView = created
            menu = created
        }
        if menu.superview !== self {
            addSubview(menu)
        } else {
            bringSubviewToFront(menu)   // 手柄可能在本轮被重建到菜单之上
        }
        menu.isHidden = false

        menu.configure(actions: menuActions, singleImage: mode.isSingleImage)
        placeMenu(menu, selection: selection)

        if menu.alpha < 0.01 {
            // 首次出现：极短的入场动画，视觉上等同即时弹出。
            menu.alpha = 0
            UIView.animate(withDuration: 0.09) { menu.alpha = 1 }
        } else {
            menu.alpha = 1
        }
    }

    /// 几何变化时让菜单跟随选区重排。
    private func repositionMenu() {
        guard let menu = menuView, !menu.isHidden else { return }
        guard !menuActions.isEmpty, let selection = selectionBounds() else {
            dismissMenu()
            return
        }
        placeMenu(menu, selection: selection)
    }

    private func placeMenu(_ menu: SelectionMenuView, selection: CGRect) {
        let viewport = visibleViewport() ?? bounds
        let size = SelectionMenuView.designedSize(actionCount: menuActions.count)
        let scale = max(0.05, contentScale)
        menu.transform = .identity
        menu.bounds = CGRect(origin: .zero, size: size)
        menu.center = menuCenter(for: selection, viewport: viewport, size: size, scale: scale)
        menu.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// 菜单中心点（覆盖层坐标）。落点规则满足产品要求：
    /// 1. 优先在选区**下方**，与选区保持 `menuGap` 的净间距（不压任何控制手柄）；
    /// 2. 下方放不下（选区贴近视口底部）→ 改放**上方**；
    /// 3. 上方也放不下（贴图很大、上下都没空间）→ 落在选区**内部靠近顶部**处。
    ///
    /// 横向以选区中心对齐，并夹紧在视口内保证完整可见。
    /// 关键：所有阈值都先在**世界坐标**里算、且视口取的是"画布在屏幕上的可见区域"，
    /// 而不是 1400×1400 的整张画布 —— 否则缩小视图时贴图永远"下方有空间"。
    private func menuCenter(for selection: CGRect, viewport: CGRect, size: CGSize, scale: CGFloat) -> CGPoint {
        let worldWidth = size.width * scale
        let worldHeight = size.height * scale
        let halfWidth = worldWidth / 2
        let halfHeight = worldHeight / 2
        let gapBelow = Self.menuGap * scale
        let gapAbove = Self.menuGapAbove * scale
        let edge = 4 * scale

        var centerX = selection.midX
        if viewport.width > worldWidth {
            centerX = min(max(centerX, viewport.minX + halfWidth + edge),
                          viewport.maxX - halfWidth - edge)
        } else {
            centerX = viewport.midX
        }

        if viewport.maxY - selection.maxY >= worldHeight + gapBelow {
            return CGPoint(x: centerX, y: selection.maxY + gapBelow + halfHeight)
        }
        if selection.minY - viewport.minY >= worldHeight + gapAbove {
            return CGPoint(x: centerX, y: selection.minY - gapAbove - halfHeight)
        }
        return CGPoint(x: centerX, y: selection.minY + Self.menuInnerInset * scale + halfHeight)
    }

    // MARK: - 布局计算

    private func baseSize(for kind: SelectionHandleKind) -> CGSize {
        switch kind {
        case .imageCorner, .groupCorner: return CGSize(width: 16, height: 16)
        case .imageEdge: return CGSize(width: 20, height: 10)
        case .imageRotate, .groupRotate: return CGSize(width: 28, height: 28)
        }
    }

    private func handleLayout() -> [SelectionHandleKind: CGPoint] {
        var result: [SelectionHandleKind: CGPoint] = [:]
        let scale = max(0.05, contentScale)

        switch mode {
        case .none, .composite:
            return result
        case .compositeTransform(let rect):
            let corners = CanvasGeometry.corners(of: rect)
            let edges = [CanvasGeometry.midpoint(corners[0], corners[1]),
                         CanvasGeometry.midpoint(corners[1], corners[2]),
                         CanvasGeometry.midpoint(corners[2], corners[3]),
                         CanvasGeometry.midpoint(corners[3], corners[0])]
            for index in 0..<4 {
                result[.groupCorner(index)] = corners[index]
                result[.groupCorner(index + 4)] = edges[index]
            }
            result[.groupRotate] = CGPoint(x: rect.midX, y: rect.minY - 34 * scale)
        case .image(let quad, _), .cropping(let quad):
            guard quad.count == 4 else { return result }
            let edges = [CanvasGeometry.midpoint(quad[0], quad[1]),
                         CanvasGeometry.midpoint(quad[1], quad[2]),
                         CanvasGeometry.midpoint(quad[2], quad[3]),
                         CanvasGeometry.midpoint(quad[3], quad[0])]
            for index in 0..<4 {
                result[.imageCorner(index)] = quad[index]
                result[.imageEdge(index)] = edges[index]
            }
            if case .image = mode {
                result[.imageRotate] = rotationAnchor(quad: quad, offset: 34 * scale)
            }
        }
        return result
    }

    private func rotationAnchor(quad: [CGPoint], offset: CGFloat) -> CGPoint {
        let top = CanvasGeometry.midpoint(quad[0], quad[1])
        let bottom = CanvasGeometry.midpoint(quad[2], quad[3])
        let dx = top.x - bottom.x
        let dy = top.y - bottom.y
        let length = max(0.0001, hypot(dx, dy))
        return CGPoint(x: top.x + dx / length * offset, y: top.y + dy / length * offset)
    }

    /// 各形态的可用动作。
    /// 裁剪/变形是**模式级**动作，除了自身动作外也提供对象级动作，
    /// 但它们**进入时不会自动弹菜单**（见 autoPresentsMenu），只有用户点按选区内部才弹
    /// —— 这样既不会在进入模式时遮挡手柄，又能满足"点框内弹出编辑菜单"的交互约定。
    private func menuActions(for mode: Mode) -> [SelectionAction] {
        switch mode {
        case .none:
            return []
        case .composite:
            return [.copy, .cut, .delete, .transform]
        case .compositeTransform:
            return [.copy, .cut, .delete, .finishTransform]
        case .cropping:
            return [.finishCrop, .cancelCrop]
        case .image(_, let canEdit):
            if canEdit {
                return [.edit, .copy, .bringToFront, .sendToBack, .lock, .delete]
            } else {
                return [.copy, .crop, .replace, .bringToFront, .sendToBack, .lock, .delete]
            }
        }
    }

    /// 进入该形态时是否**自动**弹菜单。
    /// 变形/裁剪属模式级操作，进入即弹会压住手柄（历史 bug），故不自动弹。
    private var autoPresentsMenu: Bool {
        switch mode {
        case .compositeTransform, .cropping: return false
        default: return true
        }
    }

    // MARK: - 手柄拖拽

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? SelectionHandleView else { return }
        let point = gesture.location(in: self)
        delegate?.selectionOverlay(self, didDragHandle: handle.kind, to: point, state: gesture.state)
    }

    // MARK: - 自定义套索捕获

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isLassoActive, let touch = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }

        // 触摸类型必须在这里判定：`UITouch.type` 在 touchesBegan 是可靠的，
        // 而 `UIEvent.allTouches` 在 hitTest 阶段不可靠。
        guard touch.type == .pencil || allowsFingerLasso else {
            isCapturingLasso = false
            lassoPoints.removeAll()
            lassoLayer.path = nil
            return
        }

        let location = touch.location(in: self)

        // 已有选区时，从选区内部开始的触摸**不产生新套索**
        // （否则拖动/按压选中对象会立刻画出一个新选区，手一松就把原选择替换掉）。
        if let rect = compositeRect, rect.insetBy(dx: -8, dy: -8).contains(location) {
            isCapturingLasso = false
            lassoPoints.removeAll()
            lassoLayer.path = nil
            return
        }

        isCapturingLasso = true
        lassoPoints = [location]
        updateLassoLayer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isLassoActive, isCapturingLasso, let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        lassoPoints.append(touch.location(in: self))
        updateLassoLayer()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isLassoActive else {
            super.touchesEnded(touches, with: event)
            return
        }
        guard isCapturingLasso else {
            isCapturingLasso = false
            return
        }
        isCapturingLasso = false
        let path = lassoPoints
        lassoPoints = []
        lassoLayer.path = nil
        // 只有真正的套索才上报。退化套索（点一下）不上报：
        // 否则它会与容器的点按手势（点贴图 → 选中并弹菜单 / 点空白 → 取消选中）产生竞态，
        // 出现"点选贴图被随后的取消选中吃掉"的现象。
        if path.count >= 3 {
            delegate?.selectionOverlay(self, didCompleteLasso: path)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isCapturingLasso = false
        lassoPoints = []
        lassoLayer.path = nil
        super.touchesCancelled(touches, with: event)
    }

    private func updateLassoLayer() {
        lassoLayer.lineWidth = 1.5 * max(0.05, contentScale)
        lassoLayer.path = CanvasGeometry.path(points: lassoPoints)
    }
}

/// 变形态下的选区内部拖动区。
/// 作为覆盖层的**最底层子视图**存在：手柄在其上，因此触摸手柄不会被内部拖动抢走；
/// 同时它吞掉触摸事件，避免冒泡到覆盖层的套索捕获。
@MainActor
final class SelectionInteriorView: UIView {
    var isActive: Bool = false
    var region: CGRect = .null

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isActive, !region.isNull else { return false }
        return region.insetBy(dx: -8, dy: -8).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

/// 单个控制手柄：白色实心 + 蓝色描边 + 可选图形。
/// 视觉尺寸保持精致，但命中区域按 HIG 补正到 44pt —— 解决“控制点很难点到”。
@MainActor
final class SelectionHandleView: UIView {
    /// 最小可点边长（屏幕 pt，等价于本视图 bounds 单位：手柄做了 1/zoom 反向缩放）。
    static let minimumHitSize: CGFloat = 44

    let kind: SelectionHandleKind
    let baseSize: CGSize

    /// 判定补正：视觉 16pt 的手柄拥有 44pt 的可点范围。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Self.minimumHitSize - bounds.width) / 2)
        let dy = max(0, (Self.minimumHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    init(kind: SelectionHandleKind, baseSize: CGSize) {
        self.kind = kind
        self.baseSize = baseSize
        super.init(frame: CGRect(origin: .zero, size: baseSize))
        backgroundColor = .white
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 1.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.20
        layer.shadowRadius = 2
        layer.shadowOffset = .zero

        switch kind {
        case .imageCorner, .groupCorner:
            layer.cornerRadius = baseSize.width / 2
        case .imageEdge:
            layer.cornerRadius = min(baseSize.width, baseSize.height) / 2
            backgroundColor = .systemBlue
        case .imageRotate, .groupRotate:
            layer.cornerRadius = baseSize.width / 2
            let glyph = UIImageView(image: UIImage(systemName: "arrow.clockwise"))
            glyph.tintColor = .systemBlue
            glyph.contentMode = .scaleAspectFit
            glyph.frame = bounds.insetBy(dx: 6, dy: 6)
            glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(glyph)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
