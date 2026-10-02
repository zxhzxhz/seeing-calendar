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

    override func layoutSubviews() {
        super.layoutSubviews()
        stripSystemEditMenuInteractions()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stripSystemEditMenuInteractions()
    }

    /// 移除 PencilKit 为画布安装的系统编辑菜单交互。
    ///
    /// 成因：PencilKit 会在画布内部视图上挂 `UIEditMenuInteraction`，
    /// 于是「在画布空白处点一下」有时会弹出系统的 **Select All / Insert Space** 菜单
    /// —— 它既与本应用自带的选区菜单重复，内容也完全无关（本应用无任何文本编辑能力）。
    /// 该交互由 PencilKit 懒加载安装，故在进入窗口 / 每次布局 / 每次落笔前都复查一遍。
    private func stripSystemEditMenuInteractions() {
        stripSystemEditMenuInteractions(in: self)
    }

    private func stripSystemEditMenuInteractions(in view: UIView) {
        for interaction in view.interactions where interaction is UIEditMenuInteraction {
            view.removeInteraction(interaction)
        }
        for subview in view.subviews {
            stripSystemEditMenuInteractions(in: subview)
        }
    }

    @objc private func handleTracker(_ gesture: UILongPressGestureRecognizer) {
        // 落笔第一瞬间清掉系统编辑菜单交互，确保抬手时不会再冒出无关菜单。
        if gesture.state == .began { stripSystemEditMenuInteractions() }
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
