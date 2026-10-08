import SwiftUI
import UIKit

extension UIColor {
    /// 解析 `#RRGGBB` / `RRGGBB` / `#AARRGGBB`。
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if hasAlpha {
            a = CGFloat((value >> 24) & 0xFF) / 255
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// 转为 `#RRGGBB` 字符串。
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X",
                          Int(round(r * 255)),
                          Int(round(g * 255)),
                          Int(round(b * 255)))
        }
        return "#000000"
    }
}

extension Color {
    init(hex: String, fallback: Color = .accentColor) {
        if let color = UIColor(hex: hex) {
            self.init(uiColor: color)
        } else {
            self = fallback
        }
    }

    func toHex() -> String {
        UIColor(self).hexString
    }
}

/// 订阅源可选配色（与手绘墨色保持足够对比度）。
enum SubscriptionPalette {
    static let colors: [String] = [
        "#3AA6A0", "#F0A93B", "#E8615A", "#7C89C9", "#4C9AFF", "#B06AB3", "#5FA8DC", "#2F4858"
    ]

    static func color(at index: Int) -> String {
        colors[abs(index) % colors.count]
    }

    /// 稳定取色：同一订阅源永远得到同一颜色。
    static func stableColor(for uuid: UUID) -> String {
        let hash = uuid.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7FFFFFFF }
        return color(at: hash)
    }
}
