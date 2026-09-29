import UIKit

struct SelectionMenuAction {
    let action: SelectionAction
    let title: String
}

/// 虚线框上方的轻量浮动操作栏（手动布局：与反缩放 transform 不冲突）。
@MainActor
final class SelectionMenuView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private var buttons: [UIButton] = []
    private var actionList: [SelectionAction] = []

    var onSelect: ((SelectionAction) -> Void)?

    private let padding: CGFloat = 5
    private let buttonHeight: CGFloat = 30

    init(actions: [SelectionMenuAction]) {
        super.init(frame: .zero)
        isUserInteractionEnabled = true

        blur.layer.cornerRadius = 15
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        var fontAttributes = AttributeContainer()
        fontAttributes.font = UIFont.systemFont(ofSize: 13, weight: .medium)

        var width = padding
        for item in actions {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.attributedTitle = AttributedString(item.title, attributes: fontAttributes)
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            config.baseForegroundColor = .label
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in
                self?.onSelect?(item.action)
            }, for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
            actionList.append(item.action)
            let buttonWidth = max(38, button.intrinsicContentSize.width)
            button.bounds = CGRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
            width += buttonWidth
        }
        width += padding
        bounds = CGRect(x: 0, y: 0, width: ceil(width), height: buttonHeight + padding * 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        var x = padding
        for button in buttons {
            let width = button.bounds.width
            button.frame = CGRect(x: x, y: padding, width: width, height: buttonHeight)
            x += width
        }
    }
}
