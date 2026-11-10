import Foundation

/// 自动保存相位。
///
/// 为什么需要它：旧实现把「当前页有未落盘的改动」这个概念**隐式**编码在
/// `saveTask != nil` 上 —— 没有任何类型能表达它，也没法穷举测试。两台编辑器的
/// 写盘竞态（换页后 2 秒到点的那次重复写盘）就藏在这个隐式状态里。
///
/// 显式化之后，相位是**单一真值**，并固化以下不变量：
///
/// 1. `SavePolicy.shouldCommit(phase:pageUUID:)` 必须同时校验**相位**（仍在
///    `.debouncing`）与**页身份**（pageUUID 一致）—— 这是「防抖任务误写换页后的
///    另一页」的直接修法。
/// 2. `.flushRequested` 之后必到 `.saving`，且 `isDirty == false` —— `save()`
///    不允许把相位留在脏态。
/// 3. `.saving` 期间收到的 `.contentChanged` 必须落回 `.debouncing`
///    —— 落盘期间的新改动不得被吞掉。
/// 4. 相位是 `Equatable` 的纯值类型，可穷举 (相位 × 事件) 全组合验证。
enum SavePhase: Equatable, Sendable {
    case clean
    /// 有改动待落盘，去抖计时中。`pageUUID` 是 markDirty 时刻那一页。
    case debouncing(pageUUID: UUID)
    /// 正在同步落盘（save() 体内）。
    case saving(pageUUID: UUID)

    /// 是否存在待落盘的改动。
    ///
    /// **只有 `.debouncing` 算脏**：`.saving` 表示落盘已经在同步进行（这份内容
    /// 即将被写下），而落盘期间产生的新改动会由 `.contentChanged` 重新变脏
    /// （见 `reduce` 的 `.contentChanged` 分支）。因此 `flushRequested` 之后
    /// `isDirty` 必为 false。
    var isDirty: Bool {
        if case .debouncing = self { return true }
        return false
    }

    /// 待落盘 / 正在落盘的目标页；`.clean` 时为 nil。
    var pendingPageUUID: UUID? {
        switch self {
        case .clean: return nil
        case .debouncing(let pageUUID), .saving(let pageUUID): return pageUUID
        }
    }
}

/// 自动保存相位机的驱动事件。
enum SaveEvent: Equatable, Sendable {
    /// 页面内容变化（`markDirty` 的语义）。
    case contentChanged(pageUUID: UUID)
    /// 去抖计时到点。
    case debounceElapsed
    /// 请求立即落盘（`flushPendingSave` 的语义）。
    case flushRequested
    /// 同步落盘完成。
    case saveCompleted
}

/// 自动保存相位机。
///
/// **纯逻辑**：不依赖 SwiftUI / SwiftData / UIKit，因此可被
/// `scripts/verify_editor_session.swift` 直接镜像并穷举验证。
enum SavePolicy {
    /// 去抖窗口（原为 `markDirty` 内联的 `.seconds(2)` 字面量）。
    static let debounce: Duration = .seconds(2)

    /// 去抖任务是否仍应落盘：**只有「相位仍是 `.debouncing` 且 pageUUID 未变」才允许**。
    ///
    /// 这是本相位机的核心纪律：旧实现的防抖任务体不校验任何身份，换页后 2 秒到点的
    /// 那次落盘会把**新**的 currentPage 再写一遍。把「相位还在去抖」与「页身份一致」
    /// 两条同时作为准入条件，这次重复写盘从根上变得不可表达。
    static func shouldCommit(phase: SavePhase, pageUUID: UUID) -> Bool {
        guard case .debouncing(let pending) = phase else { return false }
        return pending == pageUUID
    }

    /// 相位转移。
    static func reduce(_ phase: SavePhase, event: SaveEvent) -> SavePhase {
        switch event {
        case .contentChanged(let pageUUID):
            // 任何相位下的内容变化都重新变脏，并锚定到最新这一页：
            // 既覆盖「`.saving` 期间又来改动」（不变量 3），也覆盖「换页前的改动作废」。
            return .debouncing(pageUUID: pageUUID)

        case .debounceElapsed:
            // 只有去抖到点才把「待落盘」推进为「正在落盘」；
            // `.clean` 与「已在 `.saving`」对这一事件原样返回（幂等）。
            if case .debouncing(let pageUUID) = phase {
                return .saving(pageUUID: pageUUID)
            }
            return phase

        case .flushRequested:
            // 立即落盘：有待落盘内容时收编为同步落盘并保持同一页身份（不变量 2）；
            // 本来就干净时无事可做，保持 `.clean`
            // （此时调用方 `save()` 会直接用当前页开启一次落盘）。
            if let pageUUID = phase.pendingPageUUID {
                return .saving(pageUUID: pageUUID)
            }
            return .clean

        case .saveCompleted:
            return .clean
        }
    }
}

/// 二次编辑会话。
///
/// 为什么需要它：旧实现用 6 个平行字段（`editingItemID` / `editingItemPayload` /
/// `editingTextConfig` / `isEditingText` / `editingShapeConfig` / `isEditingShape`）
/// 表达同一件事 —— 而 `CanvasItemPayload` 单独就能判别编辑态种类与配置。其中后 4 个
/// 是 payload 的手工镜像，在回调里逐个赋值、在 `updateEditedItem` 里逐个清零，
/// 任一路径漏写一个就会漂移。这里把 **payload 作为唯一真值**，其余全部是派生投影。
enum CanvasEditSession: Equatable {
    case none
    case text(id: UUID, config: TextItemConfig)
    case shape(id: UUID, config: ShapeItemConfig)

    /// 由回调拿到的 `(id, payload)` 构造会话。
    ///
    /// 这是唯一的构造入口 —— 杜绝调用方手工同步多个平行字段。
    static func session(id: UUID, payload: CanvasItemPayload) -> CanvasEditSession {
        switch payload {
        case .text(let config): return .text(id: id, config: config)
        case .shape(let config): return .shape(id: id, config: config)
        }
    }

    /// 二次编辑目标图元 id。
    var itemID: UUID? {
        switch self {
        case .none: return nil
        case .text(let id, _), .shape(let id, _): return id
        }
    }

    /// 二次编辑载荷（与种类/配置一一对应）。
    var payload: CanvasItemPayload? {
        switch self {
        case .none: return nil
        case .text(_, let config): return .text(config)
        case .shape(_, let config): return .shape(config)
        }
    }

    /// 是否正在编辑文本。
    var isEditingText: Bool {
        if case .text = self { return true }
        return false
    }

    /// 是否正在编辑形状。
    var isEditingShape: Bool {
        if case .shape = self { return true }
        return false
    }

    /// 文本配置（非文本会话为 nil）。
    var textConfig: TextItemConfig? {
        if case .text(_, let config) = self { return config }
        return nil
    }

    /// 形状配置（非形状会话为 nil）。
    var shapeConfig: ShapeItemConfig? {
        if case .shape(_, let config) = self { return config }
        return nil
    }
}
