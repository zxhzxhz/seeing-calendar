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
    private(set) var isLocked: Bool
    var payload: CanvasItemPayload?

    var onSelect: ((ImageEntityView) -> Void)?
    var onBeginMove: ((ImageEntityView) -> Void)?
    var onTransformChanged: ((ImageEntityView) -> Void)?
    var onEndMove: ((ImageEntityView) -> Void)?

    private var sourceImage: UIImage
    private var gestureBase: CGAffineTransform?
    private var gestureStartPoint: CGPoint?

    /// 是否正在被拖动。拖拽期间严禁重挂载（removeFromSuperview 会取消进行中的手势）。
    private(set) var isMoving = false

    /// 起始死区（屏幕点）：吃掉误触与触摸抖动，退出死区时重新锚定，因此不会产生跳变。
    private static let dragDeadZone: CGFloat = 3
    /// 亚像素更新阈值（世界点）：手指几乎静止时不做无意义重排；始终以基点为参考，不会丢位移。
    private static let dragEpsilon: CGFloat = 0.5
    private var hasLeftDeadZone = false
    private var gestureStartWindow: CGPoint = .zero

    init(item: CanvasImageItem) {
        self.itemID = item.id
        self.fileName = item.fileName
        self.worldTransform = item.worldTransform
        self.cropRect = item.cropRect
        self.naturalSize = item.naturalSize
        self.zIndex = item.zIndex
        self.isLocked = item.isLocked
        self.payload = item.payload
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
                        zIndex: zIndex,
                        isLocked: isLocked,
                        payload: payload)
    }

    func updateContent(image: UIImage, naturalSize: CGSize, payload: CanvasItemPayload?) {
        self.sourceImage = image
        self.naturalSize = naturalSize
        self.payload = payload
        self.image = image
        applyWorldTransform()
    }

    /// 将模型矩阵投影到 UIKit 视图（center + 线性变换，二者组合等价于 worldTransform）。
    func applyWorldTransform() {
        // 交互期禁用隐式动画：bounds / position / contentsRect 都带默认 0.25s 隐式动画，
        // 拖拽时会让图元明显滞后于手指（裁剪时尤其像"卡住"）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = visibleSize
        bounds = CGRect(origin: .zero, size: size)
        center = worldTransform.applied(to: CGPoint(x: size.width / 2, y: size.height / 2))
        transform = worldTransform.linearPart
        layer.contentsRect = cropRect
        CATransaction.commit()
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

    /// 锁定态只改变交互语义（不可选中 / 不可拖动），**不再画任何角标**。
    ///
    /// 旧实现会在右上角叠一枚小锁 `UIImageView`。它对用户的骚扰大于信息量：
    /// 贴图一旦锁定，那枚锁会一直压在画面上（也就是用户的画作上），
    /// 而「哪些贴图锁了」这件事在菜单里本来就看得到：贴图菜单里有「锁定贴图」，
    /// 编辑器菜单里有「解锁全部贴图（N）」（N 为 0 时置灰）。
    func setLocked(_ locked: Bool) {
        isLocked = locked
        // 锁定即退出选中态：高亮环留在锁定贴图上会让人以为它还是可操作的。
        if locked { setHighlighted(false) }
    }

    /// 选中态临时高亮（不改变任何几何，纯视觉提示）。
    func setHighlighted(_ highlighted: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = highlighted ? 0.55 : 0
        layer.shadowRadius = highlighted ? 10 : 0
        layer.shadowOffset = .zero
        CATransaction.commit()
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
            // 基点模型：首触点为锚，之后一律「当前点 − 基点」求位移，不做增量累加（避免误差累积）。
            gestureStartPoint = gesture.location(in: superview)
            gestureStartWindow = gesture.location(in: window ?? superview ?? self)
            hasLeftDeadZone = false
            onSelect?(self)
            onBeginMove?(self)
        case .changed:
            guard let base = gestureBase, let parent = superview, var start = gestureStartPoint else { return }
            let current = gesture.location(in: parent)

            // 去抖 ①：起始死区。在手势刚成立时忽略极小位移，避免误触/抖动；
            //          退出死区时把基点重锚到当前位置 —— 因此死区不会造成任何跳变。
            if !hasLeftDeadZone {
                let reference = window ?? parent
                let windowPoint = gesture.location(in: reference)
                let travel = hypot(windowPoint.x - gestureStartWindow.x, windowPoint.y - gestureStartWindow.y)
                guard travel >= Self.dragDeadZone else { return }
                hasLeftDeadZone = true
                gestureStartPoint = current
                start = current
            }

            // 位移 = 当前点 − 基点，两个点都取自**画布世界坐标系**：
            // 因此天然免受画布 zoomScale、图元自身缩放/旋转的影响（比值恒为 1）。
            let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)

            // 去抖 ②：亚像素过滤。手指近乎静止时不触发重排；
            //          因为位移始终相对基点计算，所以不会像增量式实现那样丢失位移。
            guard abs(delta.x) > Self.dragEpsilon || abs(delta.y) > Self.dragEpsilon else { return }

            worldTransform = base.applyingWorldDelta(.worldTranslation(delta))
            applyWorldTransform()
            onTransformChanged?(self)
        case .ended, .cancelled, .failed:
            // 先复位再回调：容器会在 onEndMove 里补做延迟的“置顶重挂载”。
            isMoving = false
            gestureBase = nil
            gestureStartPoint = nil
            hasLeftDeadZone = false
            onEndMove?(self)
        default:
            break
        }
    }

    // MARK: - 自定义贴纸导出与特征指纹

    /// 按照图元当前的裁剪、缩放与旋转，渲染出透明贴纸图片
    func renderStickerImage() -> UIImage? {
        guard let cgImage = sourceImage.cgImage else { return sourceImage }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let cropPixelRect = CGRect(
            x: cropRect.origin.x * imgW,
            y: cropRect.origin.y * imgH,
            width: cropRect.size.width * imgW,
            height: cropRect.size.height * imgH
        ).integral

        let croppedCG = cgImage.cropping(to: cropPixelRect) ?? cgImage
        let croppedImage = UIImage(cgImage: croppedCG, scale: sourceImage.scale, orientation: sourceImage.imageOrientation)

        let angle = atan2(worldTransform.b, worldTransform.a)
        let sx = hypot(worldTransform.a, worldTransform.c)
        let sy = hypot(worldTransform.b, worldTransform.d)
        let targetW = max(16, visibleSize.width * sx)
        let targetH = max(16, visibleSize.height * sy)

        let rotatedBounds = CGRect(origin: .zero, size: CGSize(width: targetW, height: targetH))
            .applying(CGAffineTransform(rotationAngle: angle))
        let renderSize = CGSize(width: max(16, ceil(rotatedBounds.width)), height: max(16, ceil(rotatedBounds.height)))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.translateBy(x: renderSize.width / 2, y: renderSize.height / 2)
            cgCtx.rotate(by: angle)
            croppedImage.draw(in: CGRect(x: -targetW / 2, y: -targetH / 2, width: targetW, height: targetH))
        }
    }

    /// 特征指纹：由图元 ID、尺寸、裁剪、旋转及内容特征共同决定；
    /// 尺寸、裁剪、旋转或文字内容发生改变时指纹会变化，再次添加将成为新贴纸。
    var stickerFingerprint: String {
        let sx = hypot(worldTransform.a, worldTransform.c)
        let sy = hypot(worldTransform.b, worldTransform.d)
        let targetW = max(16, visibleSize.width * sx)
        let targetH = max(16, visibleSize.height * sy)
        let angleDeg = Int(round((atan2(worldTransform.b, worldTransform.a) * 180 / .pi)))
        let w = Int(round(targetW))
        let h = Int(round(targetH))
        let cropStr = "\(Int(cropRect.origin.x * 1000))_\(Int(cropRect.origin.y * 1000))_\(Int(cropRect.size.width * 1000))_\(Int(cropRect.size.height * 1000))"
        var contentSig = ""
        if let payload {
            switch payload {
            case .text(let config):
                contentSig = "text:\(config.text):\(config.fontSize):\(config.textColorHex):\(config.isBold):\(config.isItalic)"
            case .shape(let config):
                contentSig = "shape:\(config.shapeKindRaw):\(config.strokeColorHex):\(config.strokeWidth):\(config.fillColorHex)"
            }
        }
        return "\(itemID.uuidString):\(w)x\(h):\(cropStr):\(angleDeg):\(contentSig)"
    }
}
