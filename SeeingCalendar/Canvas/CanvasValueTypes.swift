import PencilKit
import UIKit

/// 图层基线：`zIndex >= frontBase` 的贴图位于**手绘笔迹之上**，其余位于笔迹之下。
/// 用单一整型 zIndex 编码前后层，避免为一次排序引入 schema 变更。
enum CanvasLayers {
    static let frontBase = 10_000
}

/// 贴图实体的画布内快照（值语义，用于历史栈与持久化）。
struct CanvasImageItem: Identifiable {
    var id: UUID
    var fileName: String
    var image: UIImage
    var worldTransform: CGAffineTransform
    var cropRect: CGRect
    var naturalSize: CGSize
    var zIndex: Int

    /// 是否位于手绘笔迹之上。
    var isInFront: Bool { zIndex >= CanvasLayers.frontBase }
}

/// 画布内容快照（撤销 / 重做的最小单元）。
struct CanvasSnapshot {
    var drawing: PKDrawing
    var items: [CanvasImageItem]
}

/// 选区视觉状态机（与 spec 三态一致）。
enum CanvasSelectionKind: Equatable {
    case none
    case composite
    case image(UUID)
    case compositeTransform
    case cropping(UUID)
}

enum SelectionAction: Equatable {
    case copy
    case cut
    case delete
    case transform
    case finishTransform
    case crop
    case finishCrop
    case cancelCrop
    case replace
    case bringToFront
    case sendToBack

    var title: String {
        switch self {
        case .copy: return "复制"
        case .cut: return "剪切"
        case .delete: return "删除"
        case .transform: return "变形"
        case .finishTransform: return "完成变形"
        case .crop: return "裁剪"
        case .finishCrop: return "完成裁剪"
        case .cancelCrop: return "取消裁剪"
        case .replace: return "替换"
        case .bringToFront: return "置顶（笔迹之上）"
        case .sendToBack: return "置底"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .delete: return "trash"
        case .transform: return "arrow.up.left.and.arrow.down.right"
        case .finishTransform: return "checkmark"
        case .crop: return "crop"
        case .finishCrop: return "checkmark"
        case .cancelCrop: return "xmark"
        case .replace: return "arrow.triangle.2.circlepath"
        case .bringToFront: return "square.3.layers.3d.top.filled"
        case .sendToBack: return "square.3.layers.3d.bottom.filled"
        }
    }
}

/// 单图选区菜单里的「拷贝」与复合选区的「复制」共用同一动作，标题按上下文取值。
extension SelectionAction {
    static func copyAction(forSingleImage: Bool) -> SelectionAction { .copy }

    func title(singleImage: Bool) -> String {
        if self == .copy { return singleImage ? "拷贝" : "复制" }
        return title
    }
}

/// 手柄种类：单图（4 角等比 + 4 边裁剪 + 顶部旋转）/ 复合（8 向 + 旋转）。
enum SelectionHandleKind: Hashable {
    case imageCorner(Int)
    case imageEdge(Int)
    case imageRotate
    case groupCorner(Int)
    case groupRotate
}

/// 跨会话剪贴板载荷（笔迹 + 贴图）。
struct CanvasClipboard {
    var strokes: [PKStroke]
    var items: [CanvasImageItem]
}
