import UIKit

/// 选区浮动菜单（自绘，替代 `UIEditMenuInteraction` 的系统编辑菜单）。
///
/// 为什么不用系统编辑菜单（对应产品要求的五点）：
/// 1. 尺寸不可控 —— 7 个动作纵向排列近 200pt 高；本视图是**一行紧凑图标**，高度仅 56pt；
/// 2. iOS 18 的系统编辑菜单自带指向箭头，且没有任何 API 可以关掉；
/// 3. 系统只能接收「源点」而无法接收「边」，会把菜单**居中**在锚点上 ——
///    高菜单的上半部分因此直接盖住选区下缘的控制点（真机反馈的"菜单挡住控制点"根因）；
/// 4. 无法精确控制与选区之间的净间距，也无法指定「上方 / 下方 / 内部」的落点；
/// 5. `presentEditMenu` 必须先 `dismissMenu` 再延时重弹，做不到"点一下就出来"。
/// 自绘之后以上五点全部变成显式可控的布局参数（见 `SelectionOverlayView.menuCenter`）。
@MainActor
final class SelectionMenuView: UIView {
    /// 以下尺寸均为**屏幕 pt**（外层按 1/zoom 反向缩放，故视觉尺寸与缩放无关）。
    static let itemWidth: CGFloat = 50
    static let itemHeight: CGFloat = 46
    static let padding: CGFloat = 5
    static let cornerRadius: CGFloat = 12

    static func designedSize(actionCount: Int) -> CGSize {
        let count = max(1, actionCount)
        return CGSize(width: CGFloat(count) * itemWidth + padding * 2,
                      height: itemHeight + padding * 2)
    }

    var onSelect: ((SelectionAction) -> Void)?

    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let row = UIStackView()
    private var configuredActions: [SelectionAction] = []
    private var configuredSingleImage: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = Self.cornerRadius
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        addSubview(backdrop)

        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        backdrop.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: Self.padding),
            row.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor, constant: -Self.padding),
            row.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: Self.padding),
            row.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor, constant: -Self.padding)
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }

    /// 按动作集装配按钮。同一动作集重复调用不会重建，避免"再点一次图片"时按钮闪一下。
    func configure(actions: [SelectionAction], singleImage: Bool) {
        guard configuredActions != actions || configuredSingleImage != singleImage else { return }
        configuredActions = actions
        configuredSingleImage = singleImage
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            row.addArrangedSubview(makeButton(for: action, singleImage: singleImage))
        }
    }

    private func makeButton(for action: SelectionAction, singleImage: Bool) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: action.symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        config.title = action.shortTitle(singleImage: singleImage)
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 1, bottom: 4, trailing: 1)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .clear
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 10, weight: .medium)
            return outgoing
        }
        let button = UIButton(configuration: config,
                              primaryAction: UIAction { [weak self] _ in
                                  self?.onSelect?(action)
                              })
        // 视觉上是 2 字短标题，无障碍/长按提示仍给出完整语义。
        button.accessibilityLabel = action.title(singleImage: singleImage)
        return button
    }
}
