import PencilKit
import UIKit

/// 画布宿主：外层统一缩放/平移（两层共享同一世界坐标系，几何永不错位）。
@MainActor
final class CanvasHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    let canvas: CompositeCanvasContainerView

    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?

    /// 是否有触摸按在**画纸（可绘画区域）内**。
    /// 用于按区域门控「交互式下拉返回」：画纸内禁止；页条/工具栏/画布留白处放行。
    /// 只在落笔瞬间判定一次，拖拽中途不翻转（否则拖出画纸时手势会被突然放开）。
    var onPaperTouchChanged: ((Bool) -> Void)?

    private lazy var touchObserver: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchObserver(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    @objc private func handleTouchObserver(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let pointInCanvas = canvas.convert(gesture.location(in: self), from: self)
            onPaperTouchChanged?(canvas.bounds.contains(pointInCanvas))
        case .ended, .cancelled, .failed:
            onPaperTouchChanged?(false)
        default:
            break
        }
    }

    private var didPerformInitialFit = false

    override init(frame: CGRect) {
        canvas = CompositeCanvasContainerView(frame: CGRect(origin: .zero,
                                                            size: CompositeCanvasContainerView.canvasSize))
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.15
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.delaysContentTouches = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(scrollView)

        canvas.frame = CGRect(origin: .zero, size: CompositeCanvasContainerView.canvasSize)
        scrollView.addSubview(canvas)

        addGestureRecognizer(touchObserver)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        if !didPerformInitialFit {
            didPerformInitialFit = true
            zoomToFit(animated: false)
        } else {
            updateInsets()
        }
    }

    // MARK: - 缩放

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    /// 恰好看清整张 1:1 画布的缩放。
    var fitScale: CGFloat {
        guard canvas.bounds.width > 0, canvas.bounds.height > 0,
              bounds.width > 1, bounds.height > 1 else { return 1 }
        return min(bounds.width / canvas.bounds.width, bounds.height / canvas.bounds.height)
    }

    var isExpanded: Bool {
        scrollView.zoomScale > fitScale * 1.05
    }

    func notifyZoom() {
        onZoomChange?(scrollView.zoomScale, fitScale)
    }

    /// 「最大化 / 缩小」：在“适应整页”与“放大到 100%”之间切换，点击必有可见反馈。
    func toggleExpanded(animated: Bool = true) {
        let fit = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, fitScale))
        if scrollView.zoomScale > fit * 1.05 {
            scrollView.setZoomScale(fit, animated: animated)
        } else {
            let target = min(scrollView.maximumZoomScale, max(fit * 1.02, 1.0))
            scrollView.setZoomScale(target, animated: animated)
        }
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    func zoomToFit(animated: Bool = false) {
        let available = bounds.size
        guard available.width > 1, available.height > 1 else { return }
        let fit = min(available.width / canvas.bounds.width, available.height / canvas.bounds.height)
        let target = max(scrollView.minimumZoomScale, min(scrollView.maximumZoomScale, fit))
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    func zoomIn(animated: Bool = true) {
        let target = min(scrollView.maximumZoomScale, scrollView.zoomScale * 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    func zoomOut(animated: Bool = true) {
        let target = max(scrollView.minimumZoomScale, scrollView.zoomScale / 1.25)
        scrollView.setZoomScale(target, animated: animated)
        updateInsets()
        canvas.overlayScale = 1 / max(0.05, scrollView.zoomScale)
        notifyZoom()
    }

    private func updateInsets() {
        let contentSize = CGSize(width: canvas.bounds.width * scrollView.zoomScale,
                                 height: canvas.bounds.height * scrollView.zoomScale)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - 工具

    func setTool(_ tool: PKTool) {
        canvas.canvasView.tool = tool
    }

    /// 与画布内的绘制/手势共存：只观察，不抢。
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// 导航态（取消全部工具 / 笔画）：禁止落笔，单指即可平移，双指缩放。
    func setNavigationMode(_ enabled: Bool) {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = enabled ? 1 : 2
        canvas.isDrawingEnabled = !enabled
    }
}
