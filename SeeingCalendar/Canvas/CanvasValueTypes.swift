import PencilKit
import UIKit

/// 贴图实体的画布内快照（值语义，用于历史栈与持久化）。
struct CanvasImageItem: Identifiable {
    var id: UUID
    var fileName: String
    var image: UIImage
    var worldTransform: CGAffineTransform
    var cropRect: CGRect
    var naturalSize: CGSize
    var zIndex: Int
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
