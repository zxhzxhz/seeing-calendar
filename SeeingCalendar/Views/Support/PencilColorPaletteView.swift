import SwiftUI
import UIKit

/// 笔画颜色调节器（看齐 iOS 备忘录 PencilKit 规范）：
/// 固定前 5 个预设槽位：黑、蓝、绿、黄、红；
/// 最后一个槽位为系统 ColorPicker（自定义选色）。
struct PencilColorPaletteView: View {
    let selectedHex: String
    let onSelectColor: (String) -> Void

    /// 固定预设 5 色（黑、蓝、绿、黄、红）
    static let presetColors: [(name: String, hex: String)] = [
        ("黑", "#000000"),
        ("蓝", "#007AFF"),
        ("绿", "#34C759"),
        ("黄", "#FFCC00"),
        ("红", "#FF3B30"),
    ]

    @State private var customColor: Color = .purple

    private var isCustomColorSelected: Bool {
        !Self.presetColors.contains { $0.hex.caseInsensitiveCompare(selectedHex) == .orderedSame }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 1~5 槽位：固定预设颜色
            ForEach(Self.presetColors, id: \.hex) { item in
                let isSelected = item.hex.caseInsensitiveCompare(selectedHex) == .orderedSame
                Button {
                    onSelectColor(item.hex)
                } label: {
                    Circle()
                        .fill(Color(hex: item.hex))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                        )
                        .scaleEffect(isSelected ? 1.12 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("预设墨色: \(item.name)")
            }

            // 第 6 槽位：ColorPicker（自定义颜色轮盘）
            colorPickerSlot
        }
        .onAppear {
            if let uiColor = UIColor(hex: selectedHex) {
                customColor = Color(uiColor: uiColor)
            }
        }
    }

    @ViewBuilder
    private var colorPickerSlot: some View {
        let isSelected = isCustomColorSelected
        ColorPicker(selection: Binding(
            get: {
                if let uiColor = UIColor(hex: selectedHex) {
                    return Color(uiColor: uiColor)
                }
                return customColor
            },
            set: { newColor in
                customColor = newColor
                let hex = newColor.toHex()
                onSelectColor(hex)
            }
        ), supportsOpacity: false) {
            EmptyView()
        }
        .labelsHidden()
        .frame(width: 26, height: 26)
        .overlay(
            Group {
                if isSelected {
                    Circle()
                        .fill(Color(hex: selectedHex))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 2.5))
                        .scaleEffect(1.12)
                } else {
                    // 未选中自定义色时显示彩虹渐变轮盘图标
                    Circle()
                        .fill(
                            AngularGradient(gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                                            center: .center)
                        )
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                }
            }
            .allowsHitTesting(false)
        )
        .accessibilityLabel("自定义颜色拾取器")
    }
}
