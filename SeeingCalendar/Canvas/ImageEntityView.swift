import UIKit

/// 画布内的贴图实体：自带矩阵变换、无损裁剪视窗与单指位移手势。
/// 一旦手指落在它身上，`CompositeCanvasContainerView.hitTest` 就会把触摸截流到这里，
/// `PKCanvasView` 永远收不到 `touchesBegan` —— 从底座杜绝“选中贴图同时画出污点”。
@MainActor
final class ImageEntityView: UIImageView {
    let itemID: UUID
    var fileName: String
    var worldTransform: CGAffineTransform
    var cropRect: CGRect
    var naturalSize: CGSize
    var zIndex: Int

    var onSelect: ((ImageEntityView) -> Void)?
    var onBeginMove: ((ImageEntityView) -> Void)?
    var onTransformChanged: ((ImageEntityView) -> Void)?
    var onEndMove: ((ImageEntityView) -> Void)?

    private let sourceImage: UIImage
    private var gestureBase: CGAffineTransform?
    private var gestureStartPoint: CGPoint?

    /// 是否正在被拖动。拖拽期间严禁重挂载（removeFromSuperview 会取消进行中的手势）。
    private(set) var isMoving = false

    init(item: CanvasImageItem) {
        self.itemID = item.id
        self.fileName = item.fileName
        self.worldTransform = item.worldTransform
        self.cropRect = item.cropRect
        self.naturalSize = item.naturalSize
        self.zIndex = item.zIndex
        self.sourceImage = item.image
        super.init(frame: .zero)

        image = item.image
        contentMode = .scaleToFill
        isUserInteractionEnabled = true
        clipsToBounds = true
        layer.contentsRect = item.cropRect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.allowsEdgeAntialiasing = true
        applyWorldTransform()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 几何

    var visibleSize: CGSize {
        CGSize(width: max(1, naturalSize.width * cropRect.width),
               height: max(1, naturalSize.height * cropRect.height))
    }

    var canvasItem: CanvasImageItem {
        CanvasImageItem(id: itemID,
                        fileName: fileName,
                        image: sourceImage,
                        worldTransform: worldTransform,
                        cropRect: cropRect,
                        naturalSize: naturalSize,
                        zIndex: zIndex)
    }

    /// 将模型矩阵投影到 UIKit 视图（center + 线性变换，二者组合等价于 worldTransform）。
    func applyWorldTransform() {
        let size = visibleSize
        bounds = CGRect(origin: .zero, size: size)
        center = worldTransform.applied(to: CGPoint(x: size.width / 2, y: size.height / 2))
        transform = worldTransform.linearPart
        layer.contentsRect = cropRect
    }

    func update(cropRect: CGRect, worldTransform: CGAffineTransform) {
        self.cropRect = cropRect
        self.worldTransform = worldTransform
        applyWorldTransform()
    }

    func update(transform newTransform: CGAffineTransform) {
        worldTransform = newTransform
        applyWorldTransform()
    }

    /// 选中态临时高亮（不改变任何几何，纯视觉提示）。
    func setHighlighted(_ highlighted: Bool) {
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = highlighted ? 0.55 : 0
        layer.shadowRadius = highlighted ? 10 : 0
        layer.shadowOffset = .zero
    }

    /// 世界坐标系（父视图坐标系）中的可见四角。
    var worldQuad: [CGPoint] {
        guard let parent = superview else { return [] }
        let size = visibleSize
        let corners = [CGPoint(x: 0, y: 0),
                       CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height),
                       CGPoint(x: 0, y: size.height)]
        return corners.map { convert($0, to: parent) }
    }

    var worldCenter: CGPoint {
        worldTransform.applied(to: CGPoint(x: visibleSize.width / 2, y: visibleSize.height / 2))
    }

    /// 世界坐标系下的 4 条边中点。
    var worldEdgeMidpoints: [CGPoint] {
        let quad = worldQuad
        guard quad.count == 4 else { return [] }
        return [CanvasGeometry.midpoint(quad[0], quad[1]),
                CanvasGeometry.midpoint(quad[1], quad[2]),
                CanvasGeometry.midpoint(quad[2], quad[3]),
                CanvasGeometry.midpoint(quad[3], quad[0])]
    }

    /// 旋转手柄锚点：顶边中点沿远离中心方向外推。
    func rotationHandlePosition(offset: CGFloat) -> CGPoint {
        let quad = worldQuad
        guard quad.count == 4 else { return worldCenter }
        let top = CanvasGeometry.midpoint(quad[0], quad[1])
        let center = worldCenter
        let dx = top.x - center.x
        let dy = top.y - center.y
        let length = max(0.0001, hypot(dx, dy))
        return CGPoint(x: top.x + dx / length * offset, y: top.y + dy / length * offset)
    }

    // MARK: - 手势

    @objc private func handleTap() {
        onSelect?(self)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 必须先置位：onSelect 会触发“选中置顶”，此时若重挂载会立刻打断本手势。
            isMoving = true
            gestureBase = worldTransform
            gestureStartPoint = gesture.location(in: superview)
            onSelect?(self)
            onBeginMove?(self)
        case .changed:
            guard let base = gestureBase, let parent = superview, let start = gestureStartPoint else { return }
            // 注意：此处必须使用 location 差值而非 translation(in:)，
            // 否则在缩放过的祖先坐标系（画布 zoomScale ≠ 1）下，手指位移与贴图位移不等距。
            let current = gesture.location(in: parent)
            let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
            worldTransform = CGAffineTransform.worldTranslation(delta).concatenating(base)
            applyWorldTransform()
            onTransformChanged?(self)
        case .ended, .cancelled, .failed:
            // 先复位再回调：容器会在 onEndMove 里补做延迟的“置顶重挂载”。
            isMoving = false
            gestureBase = nil
            gestureStartPoint = nil
            onEndMove?(self)
        default:
            break
        }
    }
}
