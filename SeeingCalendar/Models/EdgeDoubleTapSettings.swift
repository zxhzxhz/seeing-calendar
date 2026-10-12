import Foundation

/// 画布边缘侧别
enum CanvasEdgeSide: String, Codable, CaseIterable {
    case left
    case right
}

/// 边缘双击动作模式
enum EdgeTapActionMode: String, CaseIterable, Identifiable, Codable {
    case switchToPrevious = "switchToPrevious"
    case switchToDesignated = "switchToDesignated"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switchToPrevious: return "切换至上一个工具"
        case .switchToDesignated: return "切换至指定工具"
        }
    }
}

/// 可供快捷切换的目标工具
enum EdgeSwitchTargetTool: String, CaseIterable, Identifiable, Codable {
    case eraser = "eraser"
    case lasso = "lasso"
    case pen = "pen"
    case monoline = "monoline"
    case marker = "marker"
    case pencil = "pencil"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eraser: return "橡皮擦"
        case .lasso: return "套索工具"
        case .pen: return "钢笔"
        case .monoline: return "自动铅笔"
        case .marker: return "马克笔"
        case .pencil: return "铅笔"
        }
    }

    var symbol: String {
        switch self {
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .pen: return "pencil.tip"
        case .monoline: return "pencil.line"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        }
    }
}

/// 单侧边缘手势配置
struct EdgeTapSideConfig: Codable, Equatable {
    var isEnabled: Bool
    var mode: EdgeTapActionMode
    var designatedTool: EdgeSwitchTargetTool

    init(isEnabled: Bool = false,
         mode: EdgeTapActionMode = .switchToPrevious,
         designatedTool: EdgeSwitchTargetTool = .eraser) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.designatedTool = designatedTool
    }
}

/// 画布边缘双击快捷切换整体设置
struct EdgeDoubleTapSettings: Codable, Equatable {
    var left: EdgeTapSideConfig
    var right: EdgeTapSideConfig

    init(left: EdgeTapSideConfig = EdgeTapSideConfig(isEnabled: true, mode: .switchToPrevious, designatedTool: .eraser),
         right: EdgeTapSideConfig = EdgeTapSideConfig(isEnabled: true, mode: .switchToDesignated, designatedTool: .eraser)) {
        self.left = left
        self.right = right
    }
}
