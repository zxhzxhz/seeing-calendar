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

/// 顶层统一选区交互层：虚线框 / 8 向手柄 / 旋转锚点 / 浮动菜单 / 自定义套索捕获。
/// 所有视觉元素均按 `contentScale = 1/zoomScale` 反向缩放，保证屏幕上的尺寸恒定。
@MainActor
final class SelectionOverlayView: UIView {
    enum Mode: Equatable {
        case none
        case composite(CGRect)
        case image(quad: [CGPoint])
        case compositeTransform(CGRect)
        case cropping(quad: [CGPoint])
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
            // 套索模式需要独占触摸
            isUserInteractionEnabled = true
        }
    }

    private(set) var mode: Mode = .none
    private let marqueeLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    private var handleViews: [SelectionHandleView] = []
    private var menuView: SelectionMenuView?
    private var lassoPoints: [CGPoint] = []

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

    // MARK: - 状态更新

    func update(mode: Mode) {
        self.mode = mode
        handleViews.forEach { $0.removeFromSuperview() }
        handleViews = []
        menuView?.removeFromSuperview()
        menuView = nil

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
            let actions = menuActions(for: mode)
            if !actions.isEmpty {
                let menu = SelectionMenuView(actions: actions)
                menu.onSelect = { [weak self] action in
                    guard let self else { return }
                    self.delegate?.selectionOverlay(self, didSelect: action)
                }
                addSubview(menu)
                menuView = menu
            }
        }
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

        for handle in handleViews {
            guard let position = handleLayout()[handle.kind] else { continue }
            handle.transform = .identity
            handle.bounds = CGRect(origin: .zero, size: handle.baseSize)
            handle.center = position
            handle.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        if let menu = menuView, let anchor = anchorPoint(scale: scale) {
            menu.transform = .identity
            menu.center = anchor
            menu.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    // MARK: - 布局计算

    private func baseSize(for kind: SelectionHandleKind) -> CGSize {
        switch kind {
        case .imageCorner, .groupCorner: return CGSize(width: 15, height: 15)
        case .imageEdge: return CGSize(width: 18, height: 9)
        case .imageRotate, .groupRotate: return CGSize(width: 26, height: 26)
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

    private func anchorPoint(scale: CGFloat) -> CGPoint? {
        switch mode {
        case .none:
            return nil
        case .composite(let rect), .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.minY - (menuView?.bounds.height ?? 40) / 2 * scale - 14 * scale)
        case .image(let quad), .cropping(let quad):
            guard let top = quad.min(by: { $0.y < $1.y }) else { return nil }
            return CGPoint(x: top.x, y: top.y - (menuView?.bounds.height ?? 40) / 2 * scale - 16 * scale)
        }
    }

    private func menuActions(for mode: Mode) -> [SelectionMenuAction] {
        switch mode {
        case .none:
            return []
        case .composite:
            return [SelectionMenuAction(action: .copy, title: "复制"),
                    SelectionMenuAction(action: .cut, title: "剪切"),
                    SelectionMenuAction(action: .delete, title: "删除"),
                    SelectionMenuAction(action: .transform, title: "缩放变形")]
        case .compositeTransform:
            return [SelectionMenuAction(action: .finishTransform, title: "完成变形")]
        case .image:
            return [SelectionMenuAction(action: .copy, title: "拷贝"),
                    SelectionMenuAction(action: .crop, title: "裁剪"),
                    SelectionMenuAction(action: .replace, title: "替换"),
                    SelectionMenuAction(action: .bringToFront, title: "置顶"),
                    SelectionMenuAction(action: .sendToBack, title: "置底"),
                    SelectionMenuAction(action: .delete, title: "删除")]
        case .cropping:
            return [SelectionMenuAction(action: .finishCrop, title: "完成裁剪"),
                    SelectionMenuAction(action: .cancelCrop, title: "取消")]
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
        if path.count >= 3 {
            delegate?.selectionOverlay(self, didCompleteLasso: path)
        }
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
