//
//  ThumbnailSlotLifecycle.swift
//  单个缩略图槽位的生命周期相位机（纯逻辑）。
//
//  为什么需要它（M3：把「四张表涌现一个状态」改成「单表显式状态」）：
//
//  M3 之前，一个槽位的状态由**四张容器的成员关系**共同表达，没有类型 ——
//  `images[key] != nil` 表示有图、`emptySlots.contains(key)` 表示权威确认无内容、
//  `inFlight[name]` 表示正在合成、`insertionOrder` 表示淘汰序。四个入口
//  （`load` / `primeFromDisk` / `settle` / `forget`）各按不同顺序读这四张表；
//  `commit` / `remove` 是必须**手工配对**的两个写者，而且 `insertionOrder`
//  还要和 `images` 手工保持同步。代码注释自己写下了「写缓存与撤标记必须在同一帧内完成」
//  —— 一条需要靠注释警告的不变量，正是缺失的状态类型：多张表的成员关系可以各自
//  漂移，而没有任何编译期约束阻止它们漂移。
//
//  本文件把「一个槽位的生命周期」归纳成一个**显式相位**，让「有图 / 确认为空 /
//  在途 / 未知」不再由多张表的成员关系涌现，而是单一真值表上的一个取值。
//
//  **纯逻辑**：不依赖 UIKit / SwiftUI / PencilKit / SwiftData（连 Foundation
//  都不需要），因此可被 `scripts/verify_thumbnail_lifecycle.swift` 直接镜像，
//  并对 (相位 × 事件) 全组合穷举验证。

/// 单个缩略图槽位的生命周期相位。
enum SlotLifecycle: Equatable, Sendable {
    /// 还没有任何结论：既无图，也未确认空。
    case unknown
    /// 正在后台合成（图与确认空都还没有）。
    case loading
    /// 有图。
    case present
    /// 权威确认无内容（笔迹与贴图都实读为空）。
    case confirmedEmpty

    /// 是否持有图像（渲染路径据此判断能不能画）。
    var hasImage: Bool { self == .present }

    /// 是否已被权威判定为「无内容」。
    var isConfirmedEmpty: Bool { self == .confirmedEmpty }

    /// 是否需要发起装载。**恰好是 `.unknown`**。
    ///
    /// 这是旧代码「`images[key] != nil` 与 `emptySlots.contains(key)` 两句前置短路」
    /// 的合并表达：`.present` 与 `.confirmedEmpty` 都已持明确结论，不再需要装载。
    /// 它同时是「推进代次不会死循环」的结构性保证 —— 拿到结论后相位离开 `.unknown`，
    /// 下一轮装载不再产生写入，于是「重启 → 再写 → 再重启」无从形成。
    /// `.loading` 也不需要**发起**新的装载（应当合并到在途任务，见 `blocksReload`）。
    var needsLoad: Bool { self == .unknown }

    /// 是否不得**重复发起**装载：已有图（`.present`）或已在途（`.loading`）。
    ///
    /// 与 `needsLoad` 互补：`needsLoad` 回答「要不要发起」，`blocksReload`
    /// 回答「能不能重复发起」。二者的唯一分歧点是 `.loading` ——
    /// 它不需要**发起**（已经在飞），但同样不允许**重复发起**。
    var blocksReload: Bool { self == .present || self == .loading }
}

/// 生命周期事件的驱动源。
enum SlotEvent: Equatable, Sendable {
    /// 发起后台合成。
    case loadBegan
    /// 合成出图 → commit。
    case loadSucceeded
    /// 权威确认无内容 → clear。
    case loadConfirmedEmpty
    /// 读不到 / 失败 → preserve（不下结论）。
    case loadUnavailable
    /// 调用方已确知内容消失（乐观收图）。
    case forgot
    /// 内存淘汰（**刻意不推进代次**）。
    case evicted
}

/// 处置桥接枚举。
///
/// 为什么需要它：本文件**不得**依赖 `ThumbnailLoadPolicy.Disposition` ——
/// 那是另一条已固化的边界，被门禁独立镜像，两边漂移即让构建失败。若这里直接写
/// `event(for: ThumbnailLoadPolicy.Disposition)`，两个「固化边界」就互相引用对方的
/// 类型，相位机的镜像 / 穷举验证会被迫把处置表一起拖进来，独立性被破坏。
/// 用一个**同构的本地枚举**做桥梁，把「处置 → 相位事件」这条纯映射留在本文件，
/// 由 `ThumbnailStore` 负责把 `ThumbnailLoadPolicy.Disposition` 译成 `SlotSettlement`。
enum SlotSettlement: Equatable, Sendable {
    /// 有新图 → 写入缓存。
    case commit
    /// 权威确认无内容 → 移除缓存条目、删除磁盘 PNG。
    case clear
    /// 拿不到结论 → 现有条目原样保留。
    case preserve
}

/// 缩略图槽位生命周期相位机。
///
/// 固化并写进本文件的五条不变量：
///
/// 1. **`.loadUnavailable` 在任何相位下都不改变相位** —— 读取抖动（笔迹文件还没落盘 /
///    合成失败）不得擦掉用户的缩略图。
/// 2. **`.evicted` 从 `.present` 回到 `.unknown`，且不推进代次** —— 淘汰后按需重建；
///    若淘汰也推进代次，「补进来 → 挤掉别的 → 再补」会变成每轮重算的满负载空转。
/// 3. **`advancesVersion` 为真的恰好是拿到明确结论的转移**：
///    `loadSucceeded → present`、`loadConfirmedEmpty → confirmedEmpty`、
///    `forgot → confirmedEmpty`。其余（`loadBegan` / `loadUnavailable` / `evicted`）
///    一律为假。
/// 4. **`needsLoad` 为真的恰好是 `.unknown`** —— 旧代码两句前置短路的合并表达，
///    也是「推进代次不会死循环」的结构性保证。
/// 5. **`.loading` 收到 `.loadBegan` 是幂等的**（原样返回）。
enum SlotLifecyclePolicy {
    /// 处置 → 相位事件。（纯映射，放在本文件以保持相位机自洽、可独立镜像。）
    static func event(for settlement: SlotSettlement) -> SlotEvent {
        switch settlement {
        case .commit:   return .loadSucceeded
        case .clear:    return .loadConfirmedEmpty
        case .preserve: return .loadUnavailable
        }
    }

    /// 唯一的相位转移函数。
    ///
    /// 关键决策：
    /// - `.loadBegan` 只把 `.unknown` 抬到 `.loading`；已落定（`.present` /
    ///   `.confirmedEmpty`）与已在途（`.loading`）**原样返回** ——
    ///   不能把「已有结论」重新降级成「在途」（不变量 5 及其推广）。
    /// - `.loadSucceeded` / `.loadConfirmedEmpty` / `.forgot` 从**任何**相位都落到
    ///   对应结论态：拿到新结论就应该覆盖旧结论（例如清空页后用 `.clear` 覆盖 `.present`）。
    /// - `.loadUnavailable` **不改变**任何相位（不变量 1）。
    /// - `.evicted` 只把 `.present` 打回 `.unknown`，其余相位无图可淘汰，原样返回
    ///   （不变量 2）。
    static func reduce(_ phase: SlotLifecycle, event: SlotEvent) -> SlotLifecycle {
        switch event {
        case .loadBegan:
            return phase == .unknown ? .loading : phase
        case .loadSucceeded:
            return .present
        case .loadConfirmedEmpty:
            return .confirmedEmpty
        case .loadUnavailable:
            return phase
        case .forgot:
            return .confirmedEmpty
        case .evicted:
            return phase == .present ? .unknown : phase
        }
    }

    /// 该转移是否推进内容代次。
    ///
    /// **固化不变量：只有拿到明确结论的转移才推进**（不变量 3）：
    /// `loadSucceeded → present`、`loadConfirmedEmpty → confirmedEmpty`、
    /// `forgot → confirmedEmpty`。
    ///
    /// `.loadUnavailable`（即 `.preserve`）与 `.evicted` **都不推进**：
    /// - `.preserve` 推进是有害的：月历白拉一轮，而且把「还没读出来」伪装成「已经是最新的」；
    /// - `evicted` 推进会让淘汰振荡变成满负载空转（见 `SlotLifecycle` 的说明）。
    static func advancesVersion(from phase: SlotLifecycle, event: SlotEvent) -> Bool {
        switch event {
        case .loadSucceeded, .loadConfirmedEmpty, .forgot:
            // 这三种事件都把相位送进承载明确结论的终态，代次纪律据此放行。
            return isTerminal(reduce(phase, event: event))
        case .loadBegan, .loadUnavailable, .evicted:
            return false
        }
    }

    /// 相位是否承载**明确结论**（有图 / 权威确认为空）。
    ///
    /// 这是代次纪律的准入判定：只有落进终态的转移才允许推进内容代次。
    /// `.unknown` 与 `.loading` 都不是终态 —— 它们不携带可对外宣告的结论。
    static func isTerminal(_ phase: SlotLifecycle) -> Bool {
        switch phase {
        case .present, .confirmedEmpty: return true
        case .unknown, .loading:        return false
        }
    }
}
