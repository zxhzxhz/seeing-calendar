import UIKit

/// 画布纸面：恒定 1:1 边界 + 网格参考线（纯 drawRect，UIKit 自动缓存位图）。
final class PaperBackgroundView: UIView {
    private let gridSpacing: CGFloat = 100

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.white.setFill()
        context.fill(rect)

        let gridColor = UIColor(white: 0.90, alpha: 1).cgColor
        context.setStrokeColor(gridColor)
        context.setLineWidth(1)

        var x: CGFloat = 0
        while x <= bounds.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            x += gridSpacing
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            y += gridSpacing
        }
        context.strokePath()

        context.setStrokeColor(UIColor(white: 0.78, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }
}
