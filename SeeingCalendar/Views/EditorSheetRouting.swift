import Foundation

/// 编辑器里互斥的模态路由。**至多一个在屏由类型强制。**
///
/// 为什么需要它：旧实现把「哪个模态在屏」拆成 13 个平行的 `@State` 布尔
/// （`isCameraPresented` / `isPageManagerPresented` / …），它们可以任意同真。
/// SwiftUI 对「多个 sheet 同真」的行为是把其中一个**静默丢弃** —— 用户看到的
/// 就是「点了没反应」。这里把「至多一个模态在屏」变成由类型自证的路由：
/// 一个 `EditorSheetRoute?` 同一时刻只能持有 0 个或 1 个 case。
///
/// 二次编辑（`editText` / `editShape`）虽然真值来自 `EditorModel.editSession`，
/// 但路由仍归这里 —— 否则「编辑文本」与「编辑形状」会退回成两个可同真的布尔，
/// 同屏互斥性就漏了一个口子。
enum EditorSheetRoute: Equatable, Identifiable {
    case camera
    case fileImporter
    case pageManager
    case weather
    case addText
    case addSticker
    case addSignature
    case addShape
    case edgeDoubleTapSettings
    /// 二次编辑：由 `EditorModel.editSession` 驱动，但路由仍归这里，
    /// 保证「编辑文本」与「编辑形状」不可能同屏。
    case editText
    case editShape

    /// 稳定的字符串 id，供 `Identifiable`。
    ///
    /// 刻意逐 case 手写而非用 `String(describing:)`：路由 id 会进入 SwiftUI 的
    /// 身份判定，必须与源码里的措辞解耦（改注释、改 case 顺序都不得动它）。
    var id: String {
        switch self {
        case .camera: return "camera"
        case .fileImporter: return "fileImporter"
        case .pageManager: return "pageManager"
        case .weather: return "weather"
        case .addText: return "addText"
        case .addSticker: return "addSticker"
        case .addSignature: return "addSignature"
        case .addShape: return "addShape"
        case .edgeDoubleTapSettings: return "edgeDoubleTapSettings"
        case .editText: return "editText"
        case .editShape: return "editShape"
        }
    }

    /// 该路由是否由 `EditorModel` 的状态派生（而非视图本地开关）。
    ///
    /// 视图侧读取端（`effectiveSheetRoute`）用它区分「本地路由」与「model 派生路由」，
    /// 关闭后者时必须回写 model 会话（见 `requiresModelCleanup`）。
    var isDerivedFromModel: Bool {
        switch self {
        case .editText, .editShape: return true
        case .camera, .fileImporter, .pageManager, .weather, .addText,
             .addSticker, .addSignature, .addShape, .edgeDoubleTapSettings:
            return false
        }
    }
}

/// 非模态的确认框（它们与模态互斥性无关，但要与模态分开管）。
///
/// 为什么单独一档：确认框在 iOS 上是 `.confirmationDialog`（action sheet），
/// 与 `.sheet` 不是同一套呈现系统 —— 把它塞进 `EditorSheetRoute` 会让
/// 「至少一个 sheet」的语义被污染。分开之后，`sheetRoute` 永远只描述 sheet。
enum EditorDialogRoute: Equatable, Identifiable {
    case clearPageConfirm
    case deletePageConfirm

    var id: String {
        switch self {
        case .clearPageConfirm: return "clearPageConfirm"
        case .deletePageConfirm: return "deletePageConfirm"
        }
    }
}

/// 图片导入来源：把「新建导入」与「原地替换」收进一个路由，
/// 消除 `!model.isReplacingImage && isPhotoPickerRequested` 这个交叉条件。
///
/// 旧实现里这两个布尔分属两个所有者（视图 `isPhotoPickerRequested`、
/// model `isReplacingImage`），「在屏的是哪一种」只能靠 `&&` / `!` 拼出来。
/// 收进一个枚举后，「至多是其中一种」不再需要调用方记得排除。
enum PhotoPickerRoute: Equatable {
    case none
    case importNew
    case replaceExisting

    /// 是否正在呈现相册选择器。
    var isPresented: Bool {
        switch self {
        case .none: return false
        case .importNew, .replaceExisting: return true
        }
    }
}

/// 调色盘 popover 的显隐（toggle 语义，独立于互斥模态）。
///
/// 为什么不合进 `EditorSheetRoute`：它由 `EditorModel.onRequestToggleColorPicker`
/// **toggle** 驱动，且没有对应的 `.sheet`（它是工具栏调色盘 popover）。
/// toggle 语义与「设置某个路由」不同，放同一枚举里会迫使调用方写
/// 「读当前值再取反」的模板代码。
enum ColorPickerRoute: Equatable {
    case hidden
    case presented

    mutating func toggle() {
        self = (self == .presented) ? .hidden : .presented
    }
}

/// 模态互斥机的准入判定（纯逻辑，可穷举测试）。
///
/// 固化的不变量：
///
/// 1. **同路由幂等接受、异路由拒绝** —— 这是「至多一屏」的类型化表达。
///    关闭请求（`requested == nil`）任意时刻都接受；没有模态在屏（`current == nil`）
///    时任意请求都接受。
/// 2. **`derivedRoute` 文本优先** —— 两者同时为真时选 `.editText`。
///    真实模型里 `editSession` 是单值，二者不可能同真，所以这只是防御性 tie-break；
///    选文本的理由是「刚被双击的文本一定被打开」，且文本编辑在交互链上更靠前。
/// 3. **只有二次编辑路由需要回写 model**（`requiresModelCleanup`）——
///    它们关闭时要把 `EditorModel.editSession` 收敛为 `.none`。
enum EditorSheetRoutingPolicy {
    /// 当前已有一个模态在屏时，新的模态请求是否被接受。
    ///
    /// 规则：**同一路由**的重复请求幂等接受（用于 Binding setter 回写）；
    /// 不同路由一律拒绝（先关再开由调用方显式做）。
    static func accepts(current: EditorSheetRoute?, requested: EditorSheetRoute?) -> Bool {
        // 关闭请求：任意 current 都接受。
        guard let requested = requested else { return true }
        // 没有模态在屏：任意请求都接受。
        guard let current = current else { return true }
        // 同路由幂等接受（Binding setter 回写会走到这里）；异路由拒绝。
        return current == requested
    }

    /// 由 `EditorModel` 会话状态推导「应该显示哪个二次编辑模态」。
    ///
    /// 两者皆假 → `nil`；两者皆真 → 文本优先（见类型注释的不变量 2）。
    static func derivedRoute(isEditingText: Bool, isEditingShape: Bool) -> EditorSheetRoute? {
        if isEditingText { return .editText }
        if isEditingShape { return .editShape }
        return nil
    }

    /// 关闭某路由时是否需要回写 model 侧状态（二次编辑会话要收敛为 `.none`）。
    static func requiresModelCleanup(_ route: EditorSheetRoute) -> Bool {
        switch route {
        case .editText, .editShape: return true
        case .camera, .fileImporter, .pageManager, .weather, .addText,
             .addSticker, .addSignature, .addShape, .edgeDoubleTapSettings:
            return false
        }
    }
}
