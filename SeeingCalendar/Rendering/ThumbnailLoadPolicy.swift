import Foundation

/// `ThumbnailRenderer.renderPNG` 的结果。
///
/// **必须把「确认为空」与「读不到」分开**：二者的表象完全一样（都没有图），
/// 但处置方向相反 ——
/// - 确认为空：内容确实被清空了，月历上必须把旧图收走，否则会挂着清空前的残影，
///   缩略图与内容不符；
/// - 读不到：笔迹文件还没落盘 / 数据损坏，此时**绝不能**动已有的图 ——
///   一次读盘抖动就擦掉用户的缩略图，比不刷新严重得多。
///
/// `PageRepository.addPage` 不建笔迹文件，新页在首次 `save()` 之前本来就没有 `.drawing`，
/// 所以「文件不存在」是**正常状态**，不能当成「这一页是空的」。
enum ThumbnailRenderResult: Sendable {
    /// 合成成功。
    case png(Data)
    /// 笔迹文件读得到，且笔迹与贴图都为空。**权威结论：这一页没有内容。**
    case empty
    /// 笔迹文件读不到 —— 不下任何结论。
    case unreadable
    /// 合成或 PNG 编码失败。
    case failed
}

/// 缩略图处置策略：**纯逻辑**，不依赖 SwiftUI / SwiftData / PencilKit / UIImage，
/// 因此可被 `scripts/verify_thumbnail_lifecycle.swift` 直接引用验证
/// （门禁脚本另有一份镜像实现，并带文本同步护栏，两边漂移即让构建失败）。
///
/// 固化的不变量：
///
/// 1. **「确认为空」才允许删除**。清空一页之后，月历上必须立刻空掉；但**只有**
///    把笔迹与贴图实读一遍、确认真的没有内容，才允许执行删除。
///    「文件读不到」「合成失败」都不算证据。
/// 2. **拿到结论就推进代次，无论来自哪条路径**。推进代次会让整棵月历树重新拉取；
///    装载路径刚合成出来的图也必须能被看见，所以它也推进 —— 而上一版把装载当成
///    “只补缓存不推进”，结果新合成的图跨不过 `MonthPager` 的等值短路，
///    这正是冷启动一直空白的结构性原因。
///    不至于死循环：`images[key] != nil` 与 `emptySlots.contains(key)` 两个前置短路
///    保证下一轮 `load` 不再产生写入。
/// 3. **`.preserve` 永不推进**。拿不到结论还推进代次是有害的：月历白拉一轮，
///    而且把“还没读出来”伪装成“已经是最新的”。
enum ThumbnailLoadPolicy {
    /// 一次合成结果对缓存条目的处置方式。
    enum Disposition: Equatable {
        /// 有新图 → 写入缓存。
        case commit
        /// **权威确认无内容** → 移除缓存条目、删除磁盘 PNG。
        case clear
        /// 拿不到结论 → 现有条目原样保留。
        case preserve
    }

    /// 处置判定。入参是 `ThumbnailRenderer.renderPNG` 的结果。
    static func disposition(for result: ThumbnailRenderResult) -> Disposition {
        switch result {
        case .png:                   return .commit
        case .empty:                 return .clear
        case .unreadable, .failed:   return .preserve
        }
    }

    /// 只有拿到了明确结论（有图 / 确认为空）才推进内容代次。
    /// 「拿不到结论」推进代次是有害的：月历会白拉一轮，而且把「还没读出来」
    /// 伪装成「已经是最新的」。
    static func advancesVersion(_ disposition: Disposition) -> Bool {
        disposition != .preserve
    }
}
