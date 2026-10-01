import Foundation

/// 缩略图装载策略：**纯逻辑**，不依赖 SwiftUI / SwiftData / UIImage，
/// 因此可被 `scripts/verify_thumbnail_lifecycle.swift` 直接引用验证。
///
/// 这里固化的三条不变量，都是 1.0.18 修掉的那个 bug 的教训：
///
/// 1. **非破坏提交**：一批装载结果只写入新增/更新与删除项，**绝不整表覆盖**。
///    月历格子里已有的图若在本次结果里缺失（并发合并失败、关系读取为空、
///    该格不属于当前网格），绝不能因此把已有的图擦掉 —— 整表覆盖正是
///    「9→10 能看到 9/30 缩略图、10→11→10 回来就没了」的直接成因。
/// 2. **代次变化才重解析**：内容代次没变时，已有图直接复用（不再重复解析）；
///    代次变了才逐格重新解析 —— 因为代次变化意味着可能有页被删除或重建，
///    此时也要把已失效的本地条目**主动移除**，否则会留下删除前的残影。
/// 3. **装载补齐不推进代次**：只是把缓存补齐（cache fill）不算内容变化，
///    不应让整棵月历树的等值短路失效。
enum ThumbnailLoadPolicy {
    /// 单格在本次装载中的处置方式。
    enum Resolution: Equatable {
        /// 已有有效图且代次未变 → 直接复用，不解析。
        case keep
        /// 需要解析（本地没有，或代次变了需要重新确认）。
        case resolve
        /// 代次变了且这一格已无封面页 → 本地条目失效，应移除。
        case drop
    }

    /// 单格处置判定。
    ///
    /// - Parameters:
    ///   - hasImage: 本地当前是否已有图。
    ///   - versionChanged: 内容代次是否相对上次装载发生变化。
    ///   - coverExists: 该日期键当前是否还有封面页（`DayRecord.coverPage != nil`）。
    static func resolution(hasImage: Bool, versionChanged: Bool, coverExists: Bool) -> Resolution {
        if versionChanged {
            return coverExists ? .resolve : .drop
        }
        return hasImage ? .keep : .resolve
    }

    /// 批次提交阈值：攒够这么多张再写一次 `@State`，把 42 格的更新次数压到个位数。
    static let batchSize = 8

    /// 把一批结果并入本地表。
    ///
    /// - Returns: 本地表中受影响的条目数（便于门禁断言与日志）。
    @discardableResult
    static func merge<T: Equatable>(_ into local: inout [String: T],
                         resolved: [String: T],
                         dropped: Set<String>) -> Int {
        var touched = 0
        for (key, value) in resolved where local[key] != value {
            local[key] = value
            touched += 1
        }
        // 只删「本次明确判定失效」的键，不顺手清空其它任何条目。
        for key in dropped where local.removeValue(forKey: key) != nil {
            touched += 1
        }
        return touched
    }
}