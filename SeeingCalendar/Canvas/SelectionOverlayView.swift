import UIKit

@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    func selectionOverlay(_ overlay: SelectionOverlayView, didSelect action: SelectionAction)
    func selectionOverlay(_ overlay: SelectionOverlayView,
                          didDragHandle kind: SelectionHandleKind,
                          to point: CGPoint,
                          state: UIGestureRecognizer.State)
    func selectionOverlay(_ overlay: SelectionOverlayView, didCompleteLasso points: [CGPoint])
}

/// 顶层统一选区交互层：虚线框 / 8 向手柄 / 旋转锚点 / **iOS 原生编辑菜单** / 自定义套索捕获。
/// 所有视觉元素按 `contentScale = 1/zoomScale` 反向缩放，保证屏幕上的尺寸恒定。
@MainActor
final class SelectionOverlayView: UIView {
    enum Mode: Equatable {
        case none
        case composite(CGRect)
        case image(quad: [CGPoint])
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
            }
            isUserInteractionEnabled = true
        }
    }

    private(set) var mode: Mode = .none
    private let marqueeLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    private var handleViews: [SelectionHandleView] = []
    private var lassoPoints: [CGPoint] = []
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var menuActions: [SelectionAction] = []
    private var lastPresentedTag: Int = -1
    /// 呈现代次：同一帧内多次触发时只允许最后一次真正弹出，避免重复弹菜单。
    private var menuGeneration: Int = 0

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

        addInteraction(editMenu)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 命中判定

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isLassoActive { return true }
        for subview in subviews where !subview.isHidden && subview.alpha > 0.01 {
            if subview.point(inside: convert(point, to: subview), with: event) { return true }
        }
        return false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isLassoActive { return self }
        return super.hitTest(point, with: event)
    }

    // MARK: - 外部查询与控制

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
                addSubview(handle)
                handleViews.append(handle)
            }
        }
        refreshLayout()
        syncEditMenu(force: true)
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
        case .image(let quad), .cropping(let quad):
            marqueeLayer.path = CanvasGeometry.path(points: quad)
        }

        let layout = handleLayout()
        for handle in handleViews {
            guard let position = layout[handle.kind] else { continue }
            handle.transform = .identity
            handle.bounds = CGRect(origin: .zero, size: handle.baseSize)
            handle.center = position
            handle.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        syncEditMenu(force: false)
    }

    // MARK: - iOS 原生菜单

    private func syncEditMenu(force: Bool) {
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
        case .image(let quad), .cropping(let quad):
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

    private func menuActions(for mode: Mode) -> [SelectionAction] {
        switch mode {
        case .none:
            return []
        case .composite:
            return [.copy, .cut, .delete, .transform]
        case .compositeTransform:
            return [.finishTransform]
        case .image:
            return [.copy, .crop, .replace, .bringToFront, .sendToBack, .delete]
        case .cropping:
            return [.finishCrop, .cancelCrop]
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
        lassoPoints = [touch.location(in: self)]
        updateLassoLayer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isLassoActive, let touch = touches.first else {
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
        let path = lassoPoints
        lassoPoints = []
        lassoLayer.path = nil
        // 点一下（退化套索）也要上报：仲裁器会给出空结果，容器据此取消选中。
        delegate?.selectionOverlay(self, didCompleteLasso: path)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lassoPoints = []
        lassoLayer.path = nil
        super.touchesCancelled(touches, with: event)
    }

    private func updateLassoLayer() {
        lassoLayer.lineWidth = 1.5 * max(0.05, contentScale)
        lassoLayer.path = CanvasGeometry.path(points: lassoPoints)
    }
}

// MARK: - 原生菜单数据源

extension SelectionOverlayView: UIEditMenuInteractionDelegate {
    nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                         menuFor configuration: UIEditMenuConfiguration,
                                         suggestedActions: [UIMenuElement]) -> UIMenu? {
        // UIKit 保证在主线程回调，这里显式声明隔离域以满足 Swift 6 严格并发。
        MainActor.assumeIsolated {
            guard !menuActions.isEmpty else { return nil }
            let single = mode.isSingleImage
            let children = menuActions.map { action -> UIAction in
                UIAction(title: action.title(singleImage: single),
                         image: UIImage(systemName: action.symbol)) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.selectionOverlay(self, didSelect: action)
                }
            }
            return UIMenu(title: "", children: children)
        }
    }

    nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                         targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        MainActor.assumeIsolated {
            guard let anchor = menuAnchorPoint() else { return .zero }
            let size = 14 * max(0.05, contentScale)
            return CGRect(x: anchor.x - size / 2, y: anchor.y - size / 2, width: size, height: size)
        }
    }
}

/// 单个控制手柄：白色实心 + 蓝色描边 + 可选图形。
@MainActor
final class SelectionHandleView: UIView {
    let kind: SelectionHandleKind
    let baseSize: CGSize

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
