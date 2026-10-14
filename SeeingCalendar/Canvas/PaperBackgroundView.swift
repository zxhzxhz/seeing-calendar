import UIKit

/// 画布纸张底色预设（含柔和护眼纸张色选项，如低饱和度米白/复古和纸色 `#FBF9F5`）。
enum CanvasPaperStyle: String, CaseIterable, Identifiable {
    case pureWhite
    case warmWashi
    case warmParchment
    case eyeCareGreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pureWhite: return "纯白画纸（#FFFFFF）"
        case .warmWashi: return "复古和纸 · 护眼米白（#FBF9F5）"
        case .warmParchment: return "暖调羊皮（#F5EFE6）"
        case .eyeCareGreen: return "护眼豆绿（#F2F7F2）"
        }
    }

    var shortTitle: String {
        switch self {
        case .pureWhite: return "纯白画纸"
        case .warmWashi: return "复古和纸"
        case .warmParchment: return "暖调羊皮"
        case .eyeCareGreen: return "护眼豆绿"
        }
    }

    var hex: String {
        switch self {
        case .pureWhite: return "#FFFFFF"
        case .warmWashi: return "#FBF9F5"
        case .warmParchment: return "#F5EFE6"
        case .eyeCareGreen: return "#F2F7F2"
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .pureWhite:
            return .white
        case .warmWashi:
            return UIColor(red: 251.0 / 255.0, green: 249.0 / 255.0, blue: 245.0 / 255.0, alpha: 1.0)
        case .warmParchment:
            return UIColor(red: 245.0 / 255.0, green: 239.0 / 255.0, blue: 230.0 / 255.0, alpha: 1.0)
        case .eyeCareGreen:
            return UIColor(red: 242.0 / 255.0, green: 247.0 / 255.0, blue: 242.0 / 255.0, alpha: 1.0)
        }
    }

    var gridColor: UIColor {
        switch self {
        case .pureWhite:
            return UIColor(white: 0.90, alpha: 1.0)
        case .warmWashi:
            return UIColor(red: 0.89, green: 0.87, blue: 0.84, alpha: 1.0)
        case .warmParchment:
            return UIColor(red: 0.86, green: 0.83, blue: 0.78, alpha: 1.0)
        case .eyeCareGreen:
            return UIColor(red: 0.84, green: 0.88, blue: 0.84, alpha: 1.0)
        }
    }

    var borderColor: UIColor {
        switch self {
        case .pureWhite:
            return UIColor(white: 0.78, alpha: 1.0)
        case .warmWashi:
            return UIColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 1.0)
        case .warmParchment:
            return UIColor(red: 0.75, green: 0.72, blue: 0.67, alpha: 1.0)
        case .eyeCareGreen:
            return UIColor(red: 0.73, green: 0.77, blue: 0.73, alpha: 1.0)
        }
    }
}

/// 画布纸面：恒定 1:1 边界 + 网格参考线（纯 drawRect，UIKit 自动缓存位图）。
final class PaperBackgroundView: UIView {
    private let gridSpacing: CGFloat = 100

    var paperStyle: CanvasPaperStyle = .pureWhite {
        didSet {
            guard oldValue != paperStyle else { return }
            backgroundColor = paperStyle.backgroundColor
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = paperStyle.backgroundColor
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        paperStyle.backgroundColor.setFill()
        context.fill(rect)

        let gridColor = paperStyle.gridColor.cgColor
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

        context.setStrokeColor(paperStyle.borderColor.cgColor)
        context.setLineWidth(1)
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }
}
