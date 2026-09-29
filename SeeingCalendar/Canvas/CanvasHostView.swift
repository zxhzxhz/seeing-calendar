import PencilKit
import UIKit

/// 画布宿主：外层统一缩放/平移（两层共享同一世界坐标系，几何永不错位）。
@MainActor
final class CanvasHostView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let canvas: CompositeCanvasContainerView

    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?

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
}
