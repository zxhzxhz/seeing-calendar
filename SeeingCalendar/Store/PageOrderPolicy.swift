import Foundation

/// 页面序的不变量（**纯逻辑**，不依赖 SwiftData，因此可被门禁直接镜像与穷举）。
///
/// 不变量（这三条是全部使用方的共同前提）：
/// 1. **封面 = `index` 最小的页**；`index` 必须从 0 开始**连续无洞**。
/// 2. 页序**恒为稳定序**：同 index 的多个页（理论上不该出现）按给定顺序保持相对位置。
/// 3. `pageCount` 恒等于 `pages.count`，是**只读冗余缓存**，只允许经唯一漏斗写入。
///
/// 为什么要把这些抽出来：这条不变量原本由 6 处代码各自重算
/// （`PageRepository.ensureCoverPage` / `addPage` / `applyPageOrder` / `deletePage` /
/// `reindex`，以及 `DayRecord.coverPage`）。多份实现迟早分叉 —— 历史事故（memory #259）
/// 正是 `coverPage` 的判定写错（按「数组第一个」而不是「index 最小」取封面），
/// 页序一旦不是顺序就选错封面。收敛到一份纯函数后，门禁可以穷举证明它不会退化。
enum PageOrderPolicy {
    /// 排序：按 index 升序，**稳定**。
    ///
    /// 用 `enumerated()` 的原始下标做 tiebreaker，而不是依赖 `sorted` 的稳定性 ——
    /// 「稳定」在本文的不变量里是硬要求，不该建立在标准库的实现细节上。
    static func sorted<T>(_ pages: [T], index: @escaping (T) -> Int) -> [T] {
        pages.enumerated()
            .sorted { lhs, rhs in
                let left = index(lhs.element)
                let right = index(rhs.element)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 封面：`index` 最小的那一页（空数组返回 nil）。
    static func coverIndex<T>(in pages: [T], index: @escaping (T) -> Int) -> T? {
        sorted(pages, index: index).first
    }

    /// 下一个可用 index（`max + 1`，空数组为 0）。
    static func nextIndex(after indices: [Int]) -> Int {
        (indices.max() ?? -1) + 1
    }

    /// 归一化：把 `ordered` 按给定顺序重新编号为 0,1,2,…，返回 (元素, 新 index) 列表。
    static func normalized<T>(_ ordered: [T]) -> [(item: T, index: Int)] {
        ordered.enumerated().map { (item: $0.element, index: $0.offset) }
    }

    /// 删除后是否**必须**重新写入封面指针（只有被删的确实是封面才需要）。
    ///
    /// 本 schema 的封面是 `index` 的投影、没有独立指针，但「删除后是否要动封面相关资源」
    /// 的判据仍只有这一条：被删的不是封面，封面槽位就不该被碰。
    static func requiresCoverReassignment(deletedIsCover: Bool) -> Bool {
        deletedIsCover
    }

    /// 一个 `index` 集合是否是合法的连续页序（0..<count 无重复无洞）。
    static func isContiguous(_ indices: [Int]) -> Bool {
        Set(indices) == Set(0..<indices.count)
    }
}
