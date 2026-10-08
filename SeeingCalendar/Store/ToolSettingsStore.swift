import Foundation

/// 工具栏偏好（墨色 / 笔宽 / 橡皮模式 / 橡皮大小）的持久化归宿。
///
/// 第一性原理：这些值是**操作者的习惯**，而不是某一天的数据 ——
/// 所以不该进 SwiftData（会跟着备份 / 恢复漂移，且读取要等 `ModelContext` 就绪），
/// 也不该留在视图 `@State`（视图一销毁就丢）。唯一合适的归宿是 `UserDefaults`：
/// 进程级、随时可读、启动第一帧就可用。
///
/// 墨色按「笔」分槽存放：钢笔 / 马克笔 / 铅笔是三种不同的书写介质，选色意图本就独立；
/// 共用一个槽位会在切笔时互相污染（例如给马克笔挑了荧光黄，回到钢笔也变成荧光黄）。
struct ToolSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 键

    private enum Key {
        static let penWidth = "editorTool.penWidth"
        static let eraserMode = "editorTool.eraserMode"
        static let eraserWidth = "editorTool.eraserWidth"

        static func penColor(_ tool: CanvasTool) -> String {
            "editorTool.penColor.\(tool.rawValue)"
        }

        static func penWidth(_ tool: CanvasTool) -> String {
            "editorTool.penWidth.\(tool.rawValue)"
        }

        static func penOpacity(_ tool: CanvasTool) -> String {
            "editorTool.penOpacity.\(tool.rawValue)"
        }
    }

    // MARK: - 墨色（每支笔独立）

    /// 读取指定笔的墨色；没存过或格式非法返回 nil，由调用方用默认色兜底。
    func penColor(for tool: CanvasTool) -> String? {
        guard tool != .eraser else { return nil }
        guard let hex = defaults.string(forKey: Key.penColor(tool)) else { return nil }
        return Self.normalizedHex(hex)
    }

    func setPenColor(_ hex: String, for tool: CanvasTool) {
        guard tool != .eraser, let normalized = Self.normalizedHex(hex) else { return }
        defaults.set(normalized, forKey: Key.penColor(tool))
    }

    // MARK: - 墨水不透明度（每支笔独立，0.05...1.0）

    let penOpacityRange: ClosedRange<Double> = 0.05...1.0

    func penOpacity(for tool: CanvasTool) -> Double? {
        guard tool != .eraser else { return nil }
        return clampedDouble(forKey: Key.penOpacity(tool), in: penOpacityRange)
    }

    func setPenOpacity(_ opacity: Double, for tool: CanvasTool) {
        guard tool != .eraser, penOpacityRange.contains(opacity) else { return }
        defaults.set(opacity, forKey: Key.penOpacity(tool))
    }

    // MARK: - 笔宽（每支笔独立存储与读取）

    /// 只接受落在 UI 滑块量程内的值 —— 越界值（旧版本残留 / 手工改写）一律当作未存过。
    let penWidthRange: ClosedRange<Double> = 1...28

    func penWidth(for tool: CanvasTool) -> Double? {
        guard tool != .eraser else { return nil }
        return clampedDouble(forKey: Key.penWidth(tool), in: penWidthRange)
            ?? clampedDouble(forKey: Key.penWidth, in: penWidthRange)
    }

    func setPenWidth(_ width: Double, for tool: CanvasTool) {
        guard tool != .eraser, penWidthRange.contains(width) else { return }
        defaults.set(width, forKey: Key.penWidth(tool))
    }

    var penWidth: Double? {
        get { clampedDouble(forKey: Key.penWidth, in: penWidthRange) }
        nonmutating set {
            guard let value = newValue, penWidthRange.contains(value) else { return }
            defaults.set(value, forKey: Key.penWidth)
        }
    }

    // MARK: - 橡皮

    let eraserWidthRange: ClosedRange<Double> = 8...160

    /// 橡皮模式（整体擦除 / 范围擦除）。
    var eraserMode: EraserMode? {
        get {
            guard let raw = defaults.string(forKey: Key.eraserMode) else { return nil }
            return EraserMode(rawValue: raw)
        }
        nonmutating set {
            guard let mode = newValue else { return }
            defaults.set(mode.rawValue, forKey: Key.eraserMode)
        }
    }

    var eraserWidth: Double? {
        get { clampedDouble(forKey: Key.eraserWidth, in: eraserWidthRange) }
        nonmutating set {
            guard let value = newValue, eraserWidthRange.contains(value) else { return }
            defaults.set(value, forKey: Key.eraserWidth)
        }
    }

    // MARK: - 工具

    private func clampedDouble(forKey key: String, in range: ClosedRange<Double>) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return range.contains(value) ? value : nil
    }

    /// 归一化成 `UIColor(hex:)` 认可的写法（`#` + 大写 6/8 位十六进制），
    /// 保证与 `SubscriptionPalette.colors` 的字面量能直接做 `==` 比较。
    static func normalizedHex(_ hex: String) -> String? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, UInt64(text, radix: 16) != nil else { return nil }
        return "#" + text
    }
}
