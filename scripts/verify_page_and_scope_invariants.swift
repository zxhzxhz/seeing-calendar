#!/usr/bin/env swift
//
//  verify_page_and_scope_invariants.swift
//  页面序不变量（M15）与订阅作用域哨兵（M16）门禁（CI 以 --strict 执行）。
//
//  钉三类回退：
//
//  【页面序：封面 = index 最小】`PageRepository` 曾把「封面页 = index 最小的页」
//     在 6 处各自重算（ensureCoverPage / addPage / applyPageOrder / deletePage /
//     reindex 以及 DayRecord.coverPage）。历史事故（memory #259）正是 `coverPage`
//     的判定写错：按「数组第一个」而不是「index 最小」取封面，页序一旦乱序就选错。
//     本门禁从两个方向钉死：① 对 0…6 个页的所有重排穷举 `coverIndex` / `isContiguous`
//     / `normalized`（断言 2、3）；② 直接复现 memory #259 的两种乱序输入（断言 4）。
//
//  【pageCount 冗余缓存的写入漏斗】`pageCount` 是 `pages.count` 的冗余缓存（存在理由：
//     月历渲染路径不能触发 SwiftData 关系 fault）。它只允许经唯一出口写入。
//     本门禁用 countOccurrences 断言 `PageRepository.swift` 里 `day.pageCount =`
//     的直接赋值只出现在白名单（commitPageOrder + backfillPageCountsIfNeeded）。
//
//  【订阅作用域：空数组 = 全局】`ICSSubscription.workspaceUUIDs: [UUID]` 曾用哨兵值
//     表达二态语义，类型上无约束。本门禁穷举 `SubscriptionScopeValue` 的**往返 / applies
//     真值表 / merge 全局吸收 / migrating 合成**，并反证「不吸收全局的并集实现」必然分歧。
//
//  运行：swift scripts/verify_page_and_scope_invariants.swift [--strict]
//

import Foundation

// MARK: - 迷你断言框架

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    checks += 1
    if lhs != rhs { failures.append("\(label)：期望 \(rhs)，实际 \(lhs)") }
}

// MARK: - 被测逻辑（生产代码的镜像，必须与生产逐字等价）

/// 镜像 SeeingCalendar/Store/PageOrderPolicy.swift。
enum PageOrder {
    static func sorted<T>(_ pages: [T], index: @escaping (T) -> Int) -> [T] {
        pages.enumerated()
            .sorted { lhs, rhs in
                let left = index(lhs.element)
                let right = index(rhs.element)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func cover<T>(in pages: [T], index: @escaping (T) -> Int) -> T? {
        sorted(pages, index: index).first
    }

    static func nextIndex(after indices: [Int]) -> Int {
        (indices.max() ?? -1) + 1
    }

    static func normalized<T>(_ ordered: [T]) -> [(item: T, index: Int)] {
        ordered.enumerated().map { (item: $0.element, index: $0.offset) }
    }

    static func requiresCoverReassignment(deletedIsCover: Bool) -> Bool {
        deletedIsCover
    }

    static func isContiguous(_ indices: [Int]) -> Bool {
        Set(indices) == Set(0..<indices.count)
    }
}

/// 镜像 SeeingCalendar/Models/SubscriptionScopeType.swift。
enum ScopeValue: Equatable, Sendable {
    case global
    case scoped(Set<UUID>)

    init(persisted: [UUID]) {
        self = persisted.isEmpty ? .global : .scoped(Set(persisted))
    }

    var persisted: [UUID] {
        switch self {
        case .global:
            return []
        case .scoped(let set):
            return Array(set)
        }
    }

    func applies(to workspaceUUID: UUID) -> Bool {
        switch self {
        case .global:
            return true
        case .scoped(let set):
            return set.contains(workspaceUUID)
        }
    }

    static func merge(_ a: ScopeValue, _ b: ScopeValue) -> ScopeValue {
        switch (a, b) {
        case (.global, _), (_, .global):
            return .global
        case (.scoped(let x), .scoped(let y)):
            return .scoped(x.union(y))
        }
    }

    static func migrating(legacy: UUID?, existing: [UUID]) -> ScopeValue {
        if let legacy { return .scoped([legacy]) }
        return ScopeValue(persisted: existing)
    }
}

/// 破坏变体 ①：封面取「数组第一个」—— memory #259 的旧事故形状。
enum BrokenPageOrder {
    static func cover<T>(in pages: [T], index: (T) -> Int) -> T? {
        pages.first
    }
}

/// 破坏变体 ②：merge 取并集、不吸收全局（把全局当成空集合）。
enum BrokenScopeValue {
    static func merge(_ a: ScopeValue, _ b: ScopeValue) -> ScopeValue {
        switch (a, b) {
        case (.scoped(let x), .scoped(let y)):
            return .scoped(x.union(y))
        case (.scoped(let x), .global):
            return .scoped(x)
        case (.global, .scoped(let y)):
            return .scoped(y)
        case (.global, .global):
            return .global
        }
    }
}

struct Page: Equatable {
    let index: Int
    let id: String
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 某个子串在文本里出现的次数（用于「写入漏斗」护栏）。
func countOccurrences(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var search = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: search) {
        count += 1
        search = range.upperBound..<haystack.endIndex
    }
    return count
}

func permutations<T>(_ items: [T]) -> [[T]] {
    guard !items.isEmpty else { return [[]] }
    var result: [[T]] = []
    for index in items.indices {
        var rest = items
        rest.remove(at: index)
        for tail in permutations(rest) {
            result.append([items[index]] + tail)
        }
    }
    return result
}

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    let policy = productionSource("SeeingCalendar/Store/PageOrderPolicy.swift") ?? ""
    check(!policy.isEmpty, "读不到 SeeingCalendar/Store/PageOrderPolicy.swift")
    check(policy.contains("enum PageOrderPolicy {"), "PageOrderPolicy 必须是独立纯逻辑枚举")
    check(policy.contains("static func sorted<T>(_ pages: [T], index: @escaping (T) -> Int) -> [T]"),
          "必须有稳定排序 sorted")
    check(policy.contains("static func coverIndex<T>(in pages: [T], index: @escaping (T) -> Int) -> T?"),
          "封面判定必须收敛到独立纯函数 coverIndex")
    check(policy.contains("static func nextIndex(after indices: [Int]) -> Int"),
          "下一个 index 必须是独立纯函数")
    check(policy.contains("static func normalized<T>(_ ordered: [T]) -> [(item: T, index: Int)]"),
          "归一化必须是独立纯函数")
    check(policy.contains("static func requiresCoverReassignment(deletedIsCover: Bool) -> Bool"),
          "删除后是否重算封面必须是独立纯函数")
    check(policy.contains("static func isContiguous(_ indices: [Int]) -> Bool"),
          "连续页序判定必须是独立纯函数")
    check(policy.contains("Set(indices) == Set(0..<indices.count)"),
          "连续判定必须按集合比较（无重复无洞），不是按顺序")
    check(policy.contains("return left != right ? left < right : lhs.offset < rhs.offset"),
          "★ 排序稳定性必须用原始下标兜底，不得依赖标准库的稳定性实现细节")
    check(policy.contains("(indices.max() ?? -1) + 1"),
          "nextIndex 必须是 max + 1（空数组为 0）")

    let models = productionSource("SeeingCalendar/Models/Models.swift") ?? ""
    check(!models.isEmpty, "读不到 SeeingCalendar/Models/Models.swift")
    check(models.contains("PageOrderPolicy.coverIndex"), "★ DayRecord.coverPage 必须委派 coverIndex")
    check(models.contains("PageOrderPolicy.sorted(pages"), "orderedPages 必须委派 PageOrderPolicy.sorted")
    check(models.contains("var scope: SubscriptionScopeValue {"),
          "ICSSubscription 必须暴露类型化作用域视图 scope")
    check(models.contains("func setScope(_ scope: [UUID])"),
          "作用域唯一写入入口 setScope 的签名不得变")
    // 负向护栏：旧的事故形状不得回潮。
    check(!models.contains("orderedPages.first"), "★ coverPage 不得回退为 orderedPages.first")
    check(!models.contains("pages.sorted { $0.index < $1.index }"),
          "★ 页序不得再散落各自重算（必须走 PageOrderPolicy）")

    // 存储属性一个都不许改（schema 不变）。
    check(models.contains("var pageCount: Int = 0"), "★ DayRecord.pageCount 存储属性必须保持 Int 且默认 0")
    check(models.contains("var workspaceUUIDs: [UUID] = []"),
          "★ ICSSubscription.workspaceUUIDs 存储属性必须保持 [UUID] 且默认空数组")
    check(models.contains("var workspaceUUID: UUID?"),
          "★ legacy workspaceUUID 字段不得删除（迁移还要读它一次）")

    let repo = productionSource("SeeingCalendar/Store/PageRepository.swift") ?? ""
    check(!repo.isEmpty, "读不到 SeeingCalendar/Store/PageRepository.swift")
    check(repo.contains("private func commitPageOrder(_ ordered: [DrawingPage], in day: DayRecord, touch: Bool)"),
          "pageCount 的唯一写入漏斗 commitPageOrder 必须存在")
    check(repo.contains("PageOrderPolicy.nextIndex(after: day.pages.map"),
          "addPage 必须用 PageOrderPolicy.nextIndex")
    check(repo.contains("PageOrderPolicy.sorted(day.pages"), "reindex / addPage 必须用 PageOrderPolicy.sorted")
    check(repo.contains("PageOrderPolicy.normalized(ordered)"),
          "commitPageOrder 必须用 PageOrderPolicy.normalized 重排")
    check(repo.contains("didBackfillPageCounts_v1"),
          "★ 回填 key 字符串一个字都不许改（改了就重跑回填）")
    // 负向护栏：旧的各处 syncPageCount 调用已被漏斗取代。
    check(!repo.contains("day.syncPageCount()"),
          "★ PageRepository 不得再散布 day.syncPageCount()（唯一的 pageCount 出口是 commitPageOrder）")

    // ★ 写入漏斗：`day.pageCount =` 只允许出现在白名单
    //   （commitPageOrder 1 处 + backfillPageCountsIfNeeded 1 处）。
    let pageCountWrites = countOccurrences("day.pageCount =", in: repo)
    check(pageCountWrites <= 2,
          "★ PageRepository 里 `day.pageCount =` 只允许 2 处（commitPageOrder + backfill），实际 \(pageCountWrites)")

    let event = productionSource("SeeingCalendar/Models/CalendarEvent.swift") ?? ""
    check(!event.isEmpty, "读不到 SeeingCalendar/Models/CalendarEvent.swift")
    check(event.contains("SubscriptionScopeValue(persisted: scope).applies(to: workspaceUUID)"),
          "★ SubscriptionScope.applies 必须委派 SubscriptionScopeValue（哨兵解读唯一地点）")

    let scopeType = productionSource("SeeingCalendar/Models/SubscriptionScopeType.swift") ?? ""
    check(!scopeType.isEmpty, "读不到 SeeingCalendar/Models/SubscriptionScopeType.swift")
    check(scopeType.contains("enum SubscriptionScopeValue: Equatable, Sendable {"),
          "SubscriptionScopeValue 必须是 Equatable + Sendable 的纯值类型")
    check(scopeType.contains("case global") && scopeType.contains("case scoped(Set<UUID>)"),
          "作用域必须是 .global / .scoped(Set<UUID>) 二态")
    check(scopeType.contains("static func migrating(legacy: UUID?, existing: [UUID]) -> SubscriptionScopeValue"),
          "迁移合成规则必须收敛到 migrating")
    check(scopeType.contains("case (.global, _), (_, .global):"),
          "★ merge 必须全局吸收（任一方为全局即全局）")

    let stack = productionSource("SeeingCalendar/App/AppDataStack.swift") ?? ""
    check(!stack.isEmpty, "读不到 SeeingCalendar/App/AppDataStack.swift")
    check(stack.contains("all.filter { $0.workspaceUUID != nil }"),
          "迁移必须只处理「旧字段非空」的记录")
    check(stack.contains("SubscriptionScopeValue.migrating(legacy: subscription.workspaceUUID,"),
          "★ 迁移合成必须调用 SubscriptionScopeValue.migrating")
    check(stack.contains("subscription.setScope(migrated.persisted)"),
          "迁移必须经 setScope 落地（顺带腾空旧字段）")
}

// MARK: - 断言 2：页面序穷举（0…6 个页的所有重排）

func verifyPageOrderExhaustive() {
    for n in 0...6 {
        let base = (0..<n).map { Page(index: $0, id: "p\($0)") }
        for perm in permutations(base) {
            let indices = perm.map(\.index)
            let label = "n=\(n) 重排 \(indices)"

            if let minIndex = indices.min() {
                checkEqual(PageOrder.cover(in: perm, index: { $0.index })?.index, minIndex,
                           "\(label) 封面必须是 index 最小者")
            } else {
                check(PageOrder.cover(in: perm, index: { $0.index }) == nil,
                      "\(label) 空页数组的封面必须是 nil")
            }

            check(PageOrder.isContiguous(indices), "\(label) 合法重排必须判连续")
            checkEqual(PageOrder.normalized(perm).map(\.index), Array(0..<n),
                       "\(label) 归一化产物 index 必须是 0..<n")
            checkEqual(PageOrder.normalized(perm).count, n, "\(label) 归一化元素数必须等于页数")
        }
    }

    // 稳定序：同 index 的多个页必须保持给定顺序。
    let duplicated = [Page(index: 1, id: "x"), Page(index: 1, id: "y"), Page(index: 0, id: "z")]
    checkEqual(PageOrder.sorted(duplicated, index: { $0.index }).map(\.id), ["z", "x", "y"],
               "★ 同 index 的多个页必须保持给定顺序（稳定序）")

    // nextIndex 边界。
    checkEqual(PageOrder.nextIndex(after: []), 0, "空页数组下一个 index 是 0")
    checkEqual(PageOrder.nextIndex(after: [0, 1, 2]), 3, "顺序页下一个 index 是 max+1")
    checkEqual(PageOrder.nextIndex(after: [3, 7]), 8, "有洞时下一个 index 仍是 max+1")

    // 删除首页 / 中间页 / 尾页的封面重算真值表。
    let three = [Page(index: 0, id: "a"), Page(index: 1, id: "b"), Page(index: 2, id: "c")]
    let coverID = PageOrder.cover(in: three, index: { $0.index })?.id
    for victim in three {
        let deletedIsCover = victim.id == coverID
        checkEqual(PageOrder.requiresCoverReassignment(deletedIsCover: deletedIsCover),
                   victim.id == "a",
                   "删除 \(victim.id) 的封面重算真值表")
    }
}

// MARK: - 断言 3：历史事故复现（memory #259）

func verifyHistoricalIncident() {
    // 「index 乱序 + 有洞」：数组第一个是 12，index 最小的是 3。
    let holey = [Page(index: 12, id: "x"), Page(index: 3, id: "y"), Page(index: 7, id: "z")]
    checkEqual(PageOrder.cover(in: holey, index: { $0.index })?.index, 3,
               "★ [3,7,12] 封面必须是 index 最小者 3，而不是数组第一个 12")
    check(!PageOrder.isContiguous(holey.map(\.index)), "★ [3,7,12] 有洞必须判否")

    // 「index 乱序但连续」：数组第一个是 1，index 最小的是 0。
    let reordered = [Page(index: 1, id: "b"), Page(index: 0, id: "a"), Page(index: 2, id: "c")]
    checkEqual(PageOrder.cover(in: reordered, index: { $0.index })?.index, 0,
               "★ [1,0,2] 封面必须是 0，而不是数组第一个 1")
    check(PageOrder.isContiguous(reordered.map(\.index)),
          "[1,0,2] 的 index 集合是 {0,1,2}，必须判连续")

    // 归一化必须把乱序有洞的页重排为 0,1,2。
    checkEqual(PageOrder.normalized(holey).map(\.item.id), ["x", "y", "z"],
               "归一化不得改变给定顺序")
    checkEqual(PageOrder.normalized(holey).map(\.index), [0, 1, 2],
               "归一化必须重新编号为 0,1,2")
}

// MARK: - 断言 5：订阅作用域穷举

func verifyScopeValue() {
    let alpha = UUID()
    let beta = UUID()
    let gamma = UUID()

    // 往返：[] / [a] / [a,b]。
    checkEqual(ScopeValue(persisted: []), .global, "空数组必须解读为全局")
    checkEqual(ScopeValue(persisted: []).persisted, [], "全局写回必须是空数组")
    checkEqual(ScopeValue(persisted: [alpha]), .scoped([alpha]), "[a] 必须解读为 scoped")
    checkEqual(ScopeValue(persisted: [alpha]).persisted, [alpha], "[a] 往返必须一致")
    checkEqual(Set(ScopeValue(persisted: [alpha, beta]).persisted), Set([alpha, beta]),
               "[a,b] 往返必须一致（集合语义）")
    check(ScopeValue(persisted: [alpha, alpha]) == .scoped([alpha]),
          "重复项必须收敛为同一个 scoped")

    // applies 真值表。
    check(ScopeValue.global.applies(to: alpha), "全局必须命中任意维度")
    check(ScopeValue.global.applies(to: gamma), "全局必须命中任意维度（第二个）")
    check(ScopeValue.scoped([alpha, beta]).applies(to: beta), "作用域内必须命中")
    check(!ScopeValue.scoped([alpha, beta]).applies(to: gamma), "★ 作用域外不得命中")

    // merge 的 3×3 组合：全局吸收。
    let cases: [ScopeValue] = [.global, .scoped([alpha]), .scoped([beta])]
    for lhs in cases {
        for rhs in cases {
            let merged = ScopeValue.merge(lhs, rhs)
            if lhs == .global || rhs == .global {
                checkEqual(merged, .global, "★ merge 全局吸收：\(lhs) + \(rhs)")
            } else {
                let expected = Set(lhs.persisted).union(Set(rhs.persisted))
                checkEqual(Set(merged.persisted), expected, "scoped 合并必须取并集：\(lhs) + \(rhs)")
            }
        }
    }
    checkEqual(ScopeValue.merge(.scoped([alpha]), .scoped([alpha])), .scoped([alpha]),
               "merge 幂等（同一集合合并仍是它自己）")

    // migrating：(legacy 有/无 × existing 空/非空 × 与 legacy 相同/不同) 全组合。
    checkEqual(ScopeValue.migrating(legacy: nil, existing: []), .global,
               "无 legacy + 空 existing → 全局")
    checkEqual(ScopeValue.migrating(legacy: nil, existing: [alpha]), .scoped([alpha]),
               "无 legacy + existing=[a] → scoped")
    checkEqual(Set(ScopeValue.migrating(legacy: nil, existing: [alpha, beta]).persisted),
               Set([alpha, beta]), "无 legacy + existing=[a,b] → scoped(现有)")
    checkEqual(ScopeValue.migrating(legacy: alpha, existing: []), .scoped([alpha]),
               "legacy=a + 空 existing → legacy 胜出")
    checkEqual(ScopeValue.migrating(legacy: alpha, existing: [alpha]), .scoped([alpha]),
               "legacy=a + existing=[a]（相同）→ scoped([a])")
    checkEqual(ScopeValue.migrating(legacy: alpha, existing: [beta]), .scoped([alpha]),
               "★ legacy=a + existing=[b]（不同）→ legacy 胜出，不得并入 existing")

    // 类型二态互斥。
    check(ScopeValue.global != ScopeValue.scoped([]), "global 与 scoped(空) 必须是不同值，不得混用")
}

// MARK: - 断言 6：反证 —— 破坏变体必须被抓到

func verifyBrokenVariants() {
    // ① 封面取数组第一个（旧事故形状）。
    let scrambled = [Page(index: 1, id: "b"), Page(index: 0, id: "a")]
    let good = PageOrder.cover(in: scrambled, index: { $0.index })
    let bad = BrokenPageOrder.cover(in: scrambled, index: { $0.index })
    checkEqual(good?.id, "a", "正确实现必须取 index 最小者")
    checkEqual(bad?.id, "b", "破坏变体确实取数组第一个 —— 反证有效")
    check(good?.id != bad?.id, "★ cover 破坏变体必须与正确实现分歧（检查器不得退化成恒真）")

    // ② merge 不吸收全局（错误的「取并集」实现）。
    let alpha = UUID()
    let scopedAlpha = ScopeValue.scoped([alpha])
    checkEqual(ScopeValue.merge(.global, scopedAlpha), .global, "正确实现：全局吸收")
    checkEqual(BrokenScopeValue.merge(.global, scopedAlpha), scopedAlpha,
               "破坏变体确实把全局收窄成 A —— 反证有效")
    check(ScopeValue.merge(.global, scopedAlpha) != BrokenScopeValue.merge(.global, scopedAlpha),
          "★ merge 破坏变体必须与正确实现分歧")
    check(ScopeValue.merge(scopedAlpha, .global) != BrokenScopeValue.merge(scopedAlpha, .global),
          "★ merge 破坏变体在另一个方向上也必须分歧")

    // 门禁不得退化成恒真：必须存在至少一个输入使正反实现分歧。
    var diverged = false
    for lhs in [ScopeValue.global, scopedAlpha] {
        for rhs in [ScopeValue.global, scopedAlpha] {
            if ScopeValue.merge(lhs, rhs) != BrokenScopeValue.merge(lhs, rhs) { diverged = true }
        }
    }
    check(diverged, "★ merge 门禁必须能在某个组合上识别破坏变体（否则恒真）")
}

// MARK: - 运行

verifySourceGuardrails()
verifyPageOrderExhaustive()
verifyHistoricalIncident()
verifyScopeValue()
verifyBrokenVariants()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 页面序与作用域不变量：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
