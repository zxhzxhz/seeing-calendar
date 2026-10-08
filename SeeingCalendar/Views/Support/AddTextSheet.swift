import SwiftUI
import UIKit

/// 添加文本弹窗（看齐 iOS 备忘录文本框功能）
struct AddTextSheet: View {
    let onCommit: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = "输入文本..."
    @State private var fontSize: CGFloat = 28
    @State private var textColorHex: String = "#000000"
    @State private var isBold: Bool = false
    @State private var textDesign: FontDesign = .default
    @State private var alignment: NSTextAlignment = .left
    @State private var cardBackground: TextCardStyle = .transparent

    enum FontDesign: String, CaseIterable, Identifiable {
        case `default` = "标准"
        case serif = "衬线"
        case rounded = "圆角"
        case monospaced = "等宽"

        var id: String { rawValue }

        func uiFont(size: CGFloat, isBold: Bool) -> UIFont {
            let weight: UIFont.Weight = isBold ? .bold : .regular
            let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = systemFont.fontDescriptor.withDesign(descriptorDesign) else {
                return systemFont
            }
            return UIFont(descriptor: descriptor, size: size)
        }

        private var descriptorDesign: UIFontDescriptor.SystemDesign {
            switch self {
            case .default: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
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
                Section("预览") {
                    previewBox
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .padding(.vertical, 8)
                }

                Section("文本内容") {
                    TextField("请输入内容", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("文字样式") {
                    Picker("字体风格", selection: $textDesign) {
                        ForEach(FontDesign.allCases) { design in
                            Text(design.rawValue).tag(design)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("粗体 (Bold)", isOn: $isBold)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(fontSize)) pt").foregroundStyle(.secondary)
                        }
                        Slider(value: $fontSize, in: 16...72, step: 2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("文字颜色")
                        PencilColorPaletteView(selectedHex: textColorHex) { hex in
                            textColorHex = hex
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("背景样式") {
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
            .navigationTitle("添加文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加到画布") {
                        commitText()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var previewBox: some View {
        let trimmed = text.isEmpty ? "输入文本..." : text
        let uiColor = UIColor(hex: textColorHex) ?? .label
        ZStack {
            // 背景棋盘格 / 容器底
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))

            // 文本卡片
            Text(trimmed)
                .font(.system(size: min(fontSize, 36), weight: isBold ? .bold : .regular))
                .foregroundColor(Color(uiColor: uiColor))
                .multilineTextAlignment(.leading)
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
        }
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let font = textDesign.uiFont(size: fontSize, isBold: isBold)
        let textColor = UIColor(hex: textColorHex) ?? .black

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let padding: CGFloat = (cardBackground == .transparent) ? 8 : 20
        let maxTextWidth: CGFloat = 600

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

        if let data = image.pngData() {
            onCommit(data)
            dismiss()
        }
    }
}
