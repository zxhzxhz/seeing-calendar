import PencilKit
import UIKit

/// 带触摸轨迹上报的 PKCanvasView。
/// 用途：橡皮擦有效范围指示圈需要实时触摸位置，而触摸会被 PencilKit 的内部手势消费掉，
/// 因此这里挂一个「零时长长按」识别器 + 允许手势共存，只做位置上报、绝不干扰绘制。
@MainActor
final class TrackingCanvasView: PKCanvasView {
    /// 画布坐标系（世界坐标）里的当前触点 + 触摸来源；手指/笔离开时 point 为 nil。
    var onTouch: ((CGPoint?, UITouch.TouchType) -> Void)?

    /// 最近一次落笔的来源（Pencil / 手指）。
    /// UILongPressGestureRecognizer 不暴露触摸类型，因此由 touchesBegan 记录。
    private var activeTouchType: UITouch.TouchType = .direct

    private lazy var tracker: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTracker(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(tracker)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first {
            activeTouchType = touch.type
        }
    }

    @objc private func handleTracker(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            onTouch?(gesture.location(in: self), activeTouchType)
        case .ended, .cancelled, .failed:
            onTouch?(nil, activeTouchType)
        default:
            break
        }
    }
}

extension TrackingCanvasView: UIGestureRecognizerDelegate {
    /// 与 PencilKit 内部绘制手势共存：只观察，不抢。
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
