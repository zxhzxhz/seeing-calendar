import SwiftUI
import UIKit

/// 添加/编辑文本弹窗（看齐 iOS 备忘录文本框功能）
struct AddTextSheet: View {
    let initialConfig: TextItemConfig?
    let onCommit: (Data, TextItemConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var fontSize: CGFloat
    @State private var textColorHex: String
    @State private var isBold: Bool
    @State private var isItalic: Bool
    @State private var isUnderline: Bool
    @State private var isStrikethrough: Bool
    @State private var fontDesign: FontDesign
    @State private var alignment: TextAlignmentOption
    @State private var cardBackground: TextCardStyle

    init(initialConfig: TextItemConfig? = nil, onCommit: @escaping (Data, TextItemConfig) -> Void) {
        self.initialConfig = initialConfig
        self.onCommit = onCommit

        let txt = initialConfig?.text ?? "输入文本..."
        let size = initialConfig?.fontSize ?? 28
        let color = initialConfig?.textColorHex ?? "#000000"
        let bold = initialConfig?.isBold ?? false
        let italic = initialConfig?.isItalic ?? false
        let underline = initialConfig?.isUnderline ?? false
        let strike = initialConfig?.isStrikethrough ?? false
        let design = FontDesign(rawValue: initialConfig?.fontDesignRaw ?? "") ?? .default
        let align = TextAlignmentOption(rawValue: initialConfig?.alignmentRaw ?? 0) ?? .left
        let card = TextCardStyle(rawValue: initialConfig?.cardBackgroundRaw ?? "") ?? .transparent

        _text = State(initialValue: txt)
        _fontSize = State(initialValue: size)
        _textColorHex = State(initialValue: color)
        _isBold = State(initialValue: bold)
        _isItalic = State(initialValue: italic)
        _isUnderline = State(initialValue: underline)
        _isStrikethrough = State(initialValue: strike)
        _fontDesign = State(initialValue: design)
        _alignment = State(initialValue: align)
        _cardBackground = State(initialValue: card)
    }

    enum FontDesign: String, CaseIterable, Identifiable {
        case `default` = "标准"
        case serif = "衬线"
        case rounded = "圆角"
        case monospaced = "等宽"
        case kaiti = "楷体"

        var id: String { rawValue }

        func uiFont(size: CGFloat, isBold: Bool, isItalic: Bool) -> UIFont {
            if self == .kaiti {
                if let kaitiFont = UIFont(name: "STKaiti", size: size) {
                    return kaitiFont
                }
            }

            var weight: UIFont.Weight = isBold ? .bold : .regular
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(descriptorDesign) else {
                return base
            }

            var traits: UIFontDescriptor.SymbolicTraits = []
            if isBold { traits.insert(.traitBold) }
            if isItalic { traits.insert(.traitItalic) }

            if let transformed = descriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: transformed, size: size)
            }
            return UIFont(descriptor: descriptor, size: size)
        }

        private var descriptorDesign: UIFontDescriptor.SystemDesign {
            switch self {
            case .default, .kaiti: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            }
        }
    }

    enum TextAlignmentOption: Int, CaseIterable, Identifiable {
        case left = 0
        case center = 1
        case right = 2
        case justified = 3

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .left: return "居左"
            case .center: return "居中"
            case .right: return "居右"
            case .justified: return "两端对齐"
            }
        }

        var icon: String {
            switch self {
            case .left: return "text.alignleft"
            case .center: return "text.aligncenter"
            case .right: return "text.alignright"
            case .justified: return "text.justify"
            }
        }

        var nsAlignment: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            case .justified: return .justified
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .left, .justified: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }
    }

    enum TextCardStyle: String, CaseIterable, Identifiable {
        case transparent = "无背景"
        case stickyYellow = "黄色便签"
        case whiteCard = "白色卡片"
        case darkCard = "深色卡片"

        var id: String { rawValue }

        var backgroundColor: UIColor? {
            switch self {
            case .transparent: return nil
            case .stickyYellow: return UIColor(red: 1.0, green: 0.96, blue: 0.72, alpha: 0.95)
            case .whiteCard: return UIColor.white.withAlphaComponent(0.95)
            case .darkCard: return UIColor(white: 0.15, alpha: 0.92)
            }
        }

        var defaultTextColor: String? {
            switch self {
            case .darkCard: return "#FFFFFF"
            default: return nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("效果预览") {
                    previewBox
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(.vertical, 8)
                }

                Section("文本内容") {
                    TextField("请输入内容", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("排版与字体") {
                    Picker("字体风格", selection: $fontDesign) {
                        ForEach(FontDesign.allCases) { design in
                            Text(design.rawValue).tag(design)
                        }
                    }
                    .pickerStyle(.segmented)

                    // 粗体 / 斜体 / 下划线 / 删除线 按钮栏
                    HStack(spacing: 8) {
                        styleToggle(title: "B", subtitle: "粗体", isOn: $isBold, font: .system(size: 15, weight: .bold))
                        styleToggle(title: "I", subtitle: "斜体", isOn: $isItalic, font: .system(size: 15).italic())
                        styleToggle(title: "U", subtitle: "下划线", isOn: $isUnderline, underline: true)
                        styleToggle(title: "S", subtitle: "删除线", isOn: $isStrikethrough, strikethrough: true)
                    }
                    .padding(.vertical, 2)

                    // 对齐方式 (左对齐 / 居中 / 居右 / 两端对齐)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对齐方式")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(TextAlignmentOption.allCases) { opt in
                                Button {
                                    alignment = opt
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: opt.icon)
                                        Text(opt.title)
                                            .font(.system(size: 12))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(alignment == opt ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(alignment == opt ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    // 字号调节
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("字号大小")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fontSize, in: 14...96, step: 2)

                        HStack(spacing: 8) {
                            presetSizeButton(title: "小 18pt", size: 18)
                            presetSizeButton(title: "中 28pt", size: 28)
                            presetSizeButton(title: "大 40pt", size: 40)
                            presetSizeButton(title: "特大 60pt", size: 60)
                        }
                        .padding(.top, 2)
                    }

                    // 文字颜色
                    VStack(alignment: .leading, spacing: 8) {
                        Text("文字颜色")
                        PencilColorPaletteView(selectedHex: textColorHex) { hex in
                            textColorHex = hex
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("背景卡片") {
                    Picker("卡片背景", selection: $cardBackground) {
                        ForEach(TextCardStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cardBackground) { _, newValue in
                        if let defaultText = newValue.defaultTextColor {
                            textColorHex = defaultText
                        } else if textColorHex == "#FFFFFF" && newValue != .darkCard {
                            textColorHex = "#000000"
                        }
                    }
                }
            }
            .navigationTitle(initialConfig == nil ? "添加文本" : "编辑文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(initialConfig == nil ? "添加到画布" : "完成更新") {
                        commitText()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func formattedToggleTitle(_ title: String, font: Font?, underline: Bool, strikethrough: Bool) -> some View {
        Text(title)
            .underline(underline)
            .strikethrough(strikethrough)
            .font(font ?? .system(size: 15))
    }

    private func styleToggle(title: String, subtitle: String, isOn: Binding<Bool>, font: Font? = nil, underline: Bool = false, strikethrough: Bool = false) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 2) {
                formattedToggleTitle(title, font: font, underline: underline, strikethrough: strikethrough)
                Text(subtitle)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func presetSizeButton(title: String, size: CGFloat) -> some View {
        Button {
            fontSize = size
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(abs(fontSize - size) < 0.1 ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(abs(fontSize - size) < 0.1 ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var previewBox: some View {
        let trimmed = text.isEmpty ? "输入文本..." : text
        let uiColor = UIColor(hex: textColorHex) ?? .label

        ZStack {
            // 背景棋盘纹理底
            CheckerboardBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12))

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)

            // 文本卡片
            Text(trimmed)
                .font(previewSwiftUIFont)
                .underline(isUnderline)
                .strikethrough(isStrikethrough)
                .foregroundColor(Color(uiColor: uiColor))
                .multilineTextAlignment(alignment.textAlignment)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Group {
                        if let bg = cardBackground.backgroundColor {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(uiColor: bg))
                                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                        }
                    }
                )
                .padding(10)
        }
    }

    private var previewSwiftUIFont: Font {
        let previewSize = min(fontSize, 36)
        let weight: Font.Weight = isBold ? .bold : .regular
        var base: Font
        switch fontDesign {
        case .default: base = .system(size: previewSize, weight: weight, design: .default)
        case .serif: base = .system(size: previewSize, weight: weight, design: .serif)
        case .rounded: base = .system(size: previewSize, weight: weight, design: .rounded)
        case .monospaced: base = .system(size: previewSize, weight: weight, design: .monospaced)
        case .kaiti:
            if let _ = UIFont(name: "STKaiti", size: previewSize) {
                base = .custom("STKaiti", size: previewSize)
            } else {
                base = .system(size: previewSize, weight: weight)
            }
        }
        return isItalic ? base.italic() : base
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let font = fontDesign.uiFont(size: fontSize, isBold: isBold, isItalic: isItalic)
        let textColor = UIColor(hex: textColorHex) ?? .black

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment.nsAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        if isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if isStrikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        let padding: CGFloat = (cardBackground == .transparent) ? 10 : 22
        let maxTextWidth: CGFloat = 650

        let bounding = (trimmed as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        let renderSize = CGSize(width: ceil(bounding.width) + padding * 2,
                                height: ceil(bounding.height) + padding * 2)

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { ctx in
            if let bg = cardBackground.backgroundColor {
                let rect = CGRect(origin: .zero, size: renderSize)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
                bg.setFill()
                path.fill()
            }
            let textRect = CGRect(x: padding, y: padding, width: ceil(bounding.width), height: ceil(bounding.height))
            (trimmed as NSString).draw(in: textRect, withAttributes: attributes)
        }

        let config = TextItemConfig(
            text: trimmed,
            fontSize: fontSize,
            textColorHex: textColorHex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderline: isUnderline,
            isStrikethrough: isStrikethrough,
            fontDesignRaw: fontDesign.rawValue,
            alignmentRaw: alignment.rawValue,
            cardBackgroundRaw: cardBackground.rawValue
        )

        if let data = image.pngData() {
            onCommit(data, config)
            dismiss()
        }
    }
}
