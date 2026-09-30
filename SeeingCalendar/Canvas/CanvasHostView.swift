import PencilKit
import UIKit

/// 画布宿主：外层统一缩放/平移（两层共享同一世界坐标系，几何永不错位）。
@MainActor
final class CanvasHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    let canvas: CompositeCanvasContainerView

    /// (当前缩放, 适配置缩放) —— 供 SwiftUI 层驱动“最大化 / 缩小”按钮状态。
    var onZoomChange: ((CGFloat, CGFloat) -> Void)?

    /// 在「画纸之外」（缩小时暴露的四周留白）向下拖动释放时回调，用于返回主页面。
    /// 系统交互式消失手势已在编辑器层永久禁用（它无法按区域开关），
    /// 因此这里自实现区域化下拉：只有留白处起手才接管，画纸内绝不抢手势。
    var onRequestDismiss: (() -> Void)?

    private var pullDownEngaged = false

    private lazy var pullDown: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePullDown(_:)))
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()

    @objc private func handlePullDown(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .ended:
            guard pullDownEngaged else { return }
            pullDownEngaged = false
            let translation = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self)
            if translation.y > 90 || velocity.y > 700 {
                onRequestDismiss?()
            }
        case .cancelled, .failed:
            pullDownEngaged = false
        default:
            break
        }
    }

    /// 该点是否落在画纸（可绘画区域）内。
    func isInsidePaper(_ point: CGPoint) -> Bool {
        canvas.bounds.contains(canvas.convert(point, from: self))
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

        addGestureRecognizer(pullDown)
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

    /// 下拉返回只在「画纸之外」起手、且以向下为主时才开始识别。
    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard gestureRecognizer === pullDown,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            guard !isInsidePaper(pan.location(in: self)) else { return false }
            let velocity = pan.velocity(in: self)
            guard velocity.y > abs(velocity.x) else { return false }
            pullDownEngaged = true
            return true
        }
    }

    /// 导航态（取消全部工具 / 笔画）：禁止落笔，单指即可平移，双指缩放。
    func setNavigationMode(_ enabled: Bool) {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = enabled ? 1 : 2
        canvas.isDrawingEnabled = !enabled
    }
}
