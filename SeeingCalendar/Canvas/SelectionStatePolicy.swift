import Foundation

// MARK: - M2 选区语义相位

/// 选区语义相位（与 spec 三态一致，但**只有一份真值**）。
///
/// 为什么需要它：旧实现里「当前是哪种选区」由 5 个扁平字段涌现
/// （`selectedImageIDs` / `selectedStrokes` / `isGroupTransforming` / `croppingImageID` /
/// `isAdjustingSelection`），而 `selectionKind: CanvasSelectionKind` 只是它们的**存储镜像**，
/// 却有**三个写者**：`notifySelection()`（重推导后赋值）、`commitSelection(notify:false)`
/// 与 `discardSelection()`（各自直接赋 `selectionKind = .none`）。
/// 三个写者各写各的，就出现了「镜像与原始事实不一致」的窗口 —— 例如传 `notify: false`
/// 时既不广播、也不重推导，直接旁路改镜像。
///
/// 本相位把「由原始事实推导出的唯一真值」显式化，`selectionKind` 随之降级为**只读投影**，
/// 于是判别「当前是哪种选区」不再有第二个副本、也不再有第二个写者。
enum SelectionPhase: Equatable, Sendable {
    case none
    case image(id: UUID)
    case composite                        // 多对象，未进入变形态
    case compositeTransform               // 多对象，已进入变形态
    case cropping(id: UUID)

    /// 该相位是否需要重建手柄 / 重弹菜单。
    ///
    /// 编号表是**唯一**的一份：`SelectionOverlayView.Mode.shapeTag` 委派到这里，
    /// 避免渲染层再维护第二张同编号的表（两张表漂移过一次就再也对不齐）。
    var shapeTag: Int {
        switch self {
        case .none: return Self.noneShapeTag
        case .composite: return Self.compositeShapeTag
        case .image: return Self.imageShapeTag
        case .compositeTransform: return Self.compositeTransformShapeTag
        case .cropping: return Self.croppingShapeTag
        }
    }

    /// 各形态的 tag 常量（不含载荷）。渲染层据此委派，无需构造真实 id。
    static let noneShapeTag = 0
    static let compositeShapeTag = 1
    static let imageShapeTag = 2
    static let compositeTransformShapeTag = 3
    static let croppingShapeTag = 4
}

/// 选区相位的推导策略。
///
/// 由选区**原始事实**推导相位的**纯函数** —— 这是 M2 的核心：
/// 把原先散落在 `notifySelection()` 里的手写 if-else 链收成**唯一一处**。
enum SelectionStatePolicy {
    /// 唯一推导入口。
    ///
    /// 优先级逐位等价于旧 `notifySelection()` 的 if-else 链：
    /// **cropping > compositeTransform > 单图 > none > composite**。
    /// 顺序不是风格问题：裁剪态必须压过变形态（裁剪期间 `isGroupTransforming` 可能仍为真），
    /// 而单图判定必须要求 `strokeCount == 0`（单图 + 笔迹是 compositeTransform，不是 image）。
    static func phase(imageIDs: [UUID], strokeCount: Int,
                      isGroupTransforming: Bool, croppingID: UUID?) -> SelectionPhase {
        if let croppingID {
            return .cropping(id: croppingID)
        }
        if isGroupTransforming, !imageIDs.isEmpty || strokeCount > 0 {
            return .compositeTransform
        }
        if imageIDs.count == 1, strokeCount == 0 {
            return .image(id: imageIDs[0])
        }
        if imageIDs.isEmpty, strokeCount == 0 {
            return .none
        }
        return .composite
    }

    /// 进入变形态的准入判定（#242 固化：套索选中**含笔迹**即默认进入变形态）。
    ///
    /// 为什么含笔迹就进变形态：笔迹一旦被取出成浮动预览，缩放/旋转后必须留在变形态，
    /// 否则「做一次操作就掉出变形态」，连续编辑被打断。
    static func entersGroupTransform(strokeCount: Int) -> Bool {
        strokeCount > 0
    }

    /// 裁剪态准入：裁剪只对**单张**贴图成立（多选时裁剪无意义）。
    static func canCrop(imageIDs: [UUID]) -> Bool {
        imageIDs.count == 1
    }
}

// MARK: - M11 交互相位（与选区相位**正交**）

/// 常驻交互相位。
///
/// 为什么需要它：旧实现里「有笔正按在画布上」（`isToolSessionActive`）与
/// 「正在拖拽选区」（`isAdjustingSelection`）是两台**各自没有类型**的独立 FSM，
/// 混住在同一批 `Bool` 字段里，谁真谁假全凭调用点约定；而 #241 又要求
/// 「拖拽期间只允许几何更新」，这条纪律只由 `isAdjustingSelection` 一个裸 bool 守护。
/// 本相位把这两台 FSM 收进一个枚举，并把纪律固化为 `allowsOverlayRebuild`。
///
/// 与 `SelectionPhase` **正交**：选区相位回答「选中的是什么」，
/// 交互相位回答「此刻正在做什么交互」。两者可任意组合（如「变形态 + 正在拖手柄」）。
enum InteractionPhase: Equatable, Sendable {
    case idle
    case toolSession                      // 有笔正按在画布上
    case adjustingSelection               // 拖手柄 / 拖贴图 / 整体变换 / 裁剪拖拽

    /// 拖拽期间只允许几何更新：绝不重建手柄、绝不重弹菜单（#241）。
    var allowsOverlayRebuild: Bool {
        switch self {
        case .idle, .toolSession: return true
        case .adjustingSelection: return false
        }
    }

    /// 是否正处在选区拖拽中。旧 `isAdjustingSelection` 的等价投影。
    var isAdjusting: Bool { self == .adjustingSelection }
}

/// 交互相位的驱动事件。
enum InteractionEvent: Equatable, Sendable {
    case toolSessionBegan
    case toolSessionEnded
    case selectionAdjustingBegan
    case selectionAdjustingEnded
}

/// 交互相位机（纯逻辑，可被门禁穷举 3×4 组合验证）。
///
/// 关键纪律：`*Ended` 事件**只收尾自己那一相**，绝不误清另一相。
/// 例如 `toolSessionEnded` 只把 `.toolSession` 打回 `.idle`；若此刻正 `.adjustingSelection`
/// （理论上不该共存，但代码路径众多），它必须原样返回 —— 否则会把进行中的拖拽踢出
/// 「只做几何更新」的保护区，直接违反 #241。
enum InteractionPolicy {
    static func reduce(_ phase: InteractionPhase, event: InteractionEvent) -> InteractionPhase {
        switch event {
        case .toolSessionBegan:
            return .toolSession

        case .toolSessionEnded:
            return phase == .toolSession ? .idle : phase

        case .selectionAdjustingBegan:
            return .adjustingSelection

        case .selectionAdjustingEnded:
            return phase == .adjustingSelection ? .idle : phase
        }
    }
}

// MARK: - 手势暂存（per-mode scratch）

/// 手势进行中的基准暂存。
///
/// 为什么要把 5 个扁平字段收成一个带类型的枚举：原先 `gestureBaseTransform` /
/// `cropBase` / `groupBaseBounds` / `groupBaseTransforms` / `groupAccumulatedDelta`
/// 是 5 个各自独立的字段，**在错误的模式下取值只会静默给出垃圾几何**
/// （例如在单图缩放手势里读 `groupBaseBounds` 得到 `.null`，却不会报任何错）。
/// 现在基准与**手势种类**绑定在同一个值里：取值前必须先匹配 case，
/// 「在错误模式下读到垃圾」变成不可表达。
enum SelectionGestureScratch: Equatable {
    case none
    case moveImage(base: CGAffineTransform)
    case crop(crop: CGRect, transform: CGAffineTransform, natural: CGSize)
    case group(bounds: CGRect, transforms: [UUID: CGAffineTransform], accumulated: CGAffineTransform?)
}

extension SelectionGestureScratch {
    /// 单图缩放手势的基准变换（仅 `.moveImage` 有值）。
    var baseTransform: CGAffineTransform? {
        if case .moveImage(let base) = self { return base }
        return nil
    }

    /// 裁剪手势的基准（仅 `.crop` 有值）。
    var cropBase: (crop: CGRect, transform: CGAffineTransform, natural: CGSize)? {
        if case .crop(let crop, let transform, let natural) = self { return (crop, transform, natural) }
        return nil
    }

    /// 整体变换的基准包围盒（仅 `.group` 有值，其余返回 `.null`）。
    var groupBounds: CGRect {
        if case .group(let bounds, _, _) = self { return bounds }
        return .null
    }

    /// 整体变换的基准变换表（仅 `.group` 有值）。
    var groupTransforms: [UUID: CGAffineTransform] {
        if case .group(_, let transforms, _) = self { return transforms }
        return [:]
    }

    /// 整体变换的累计 delta（仅 `.group` 有值）。
    var accumulatedDelta: CGAffineTransform? {
        if case .group(_, _, let accumulated) = self { return accumulated }
        return nil
    }
}

// MARK: - 套索捕获相位

/// 套索捕获相位。
///
/// 为什么单独成相、而不并入 `InteractionPhase`：套索捕获是 `SelectionOverlayView`
/// **渲染层内部**的一次触摸生命周期（`touchesBegan/Moved/Ended`），
/// 而 `InteractionPhase` 是容器层的交互真值。把前者塞进后者，会让渲染层反向持有容器状态、
/// 也让「覆盖层在捕获套索」与「容器在调整选区」被迫互斥 —— 而它们其实可以并存
/// （手指在套索层落下的同时，容器侧并无调整手势）。故按层各持一台。
enum LassoCapturePhase: Equatable, Sendable {
    case idle
    case capturing

    var isCapturing: Bool { self == .capturing }
}
