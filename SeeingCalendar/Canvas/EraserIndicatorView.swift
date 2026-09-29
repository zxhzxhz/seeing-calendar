import UIKit

/// 橡皮有效范围指示：透明空心圆 + 实线圆周。
/// 圆半径取画布世界坐标下的橡皮半径（= 橡皮设置宽度的一半），线宽按 `contentScale` 反向缩放，
/// 因此屏幕上永远是 1.5pt 实线，而圆圈大小真实反映作用范围。
@MainActor
final class EraserIndicatorView: UIView {
    private let circle = CAShapeLayer()
    private var touchPoint: CGPoint?

    var eraserWidth: CGFloat = 24 {
        didSet { refresh() }
    }

    var contentScale: CGFloat = 1 {
        didSet { refresh() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        circle.fillColor = UIColor.clear.cgColor
        circle.strokeColor = UIColor.label.withAlphaComponent(0.85).cgColor
        circle.lineWidth = 1.5
        circle.lineDashPattern = nil
        layer.addSublayer(circle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(point: CGPoint?) {
        touchPoint = point
        refresh()
    }

    private func refresh() {
        guard let touchPoint else {
            circle.path = nil
            return
        }
        let radius = max(6, eraserWidth / 2)
        let rect = CGRect(x: touchPoint.x - radius,
                          y: touchPoint.y - radius,
                          width: radius * 2,
                          height: radius * 2)
        circle.path = UIBezierPath(ovalIn: rect).cgPath
        circle.lineWidth = 1.5 * max(0.05, contentScale)
    }
}
