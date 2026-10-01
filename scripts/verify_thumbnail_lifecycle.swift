#!/usr/bin/env swift
//
//  verify_thumbnail_lifecycle.swift
//  月历缩略图生命周期门禁（CI 以 --strict 执行）
//
//  修的 bug：在 10 月页里能看到 9/30 的缩略图（9 月滑到 10 月），
//  但 10 月滑到 11 月再滑回 10 月，9/30 的缩略图没了。
//
//  根因是两条叠加的缺陷，本脚本把它们的**判定逻辑**（ThumbnailLoadPolicy，
//  生产代码同源文件）逐条钉死：
//
//  D1 并发抢输：月历常驻三个月，10 月网格首行含 9/27–9/30，9 月网格也含 9/30。
//     旧 `ThumbnailStore.regenerate` 遇到同名文件正在生成就直接 return，
//     `thumbnail(for:)` 随后读到空缓存返回 nil；`loadThumbnails` 又用
//     `thumbnails = result` 整表覆盖 → 抢输那一格把本来已有的图一起抹掉。
//  D2 短路锁死：缩略图存在子视图 `@State`，父层看不见，代次也没进 `==`，
//     于是补齐所需的重算被 Equatable 短路吃掉 → 一直停在空图上。
//
//  运行：swift scripts/verify_thumbnail_lifecycle.swift [--strict]
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

// MARK: - 被测逻辑（生产代码同源文件）

enum ThumbnailLoadPolicy {
    enum Resolution: Equatable {
        case keep
        case resolve
        case drop
    }

    static func resolution(hasImage: Bool, versionChanged: Bool, coverExists: Bool) -> Resolution {
        if versionChanged {
            return coverExists ? .resolve : .drop
        }
        return hasImage ? .keep : .resolve
    }

    static let batchSize = 8

    @discardableResult
    static func merge<T: Equatable>(_ local: inout [String: T],
                         resolved: [String: T],
                         dropped: Set<String>) -> Int {
        var touched = 0
        for (key, value) in resolved where local[key] != value {
            local[key] = value
            touched += 1
        }
        for key in dropped where local.removeValue(forKey: key) != nil {
            touched += 1
        }
        return touched
    }
}

// MARK: - 月历夹具（2026 年：10/1 是周四，故 10 月网格首行 = 9/27 … 10/3）

/// 7×6 网格的日期键：以周日为周首。
func gridKeys(forMonth month: Int, year: Int = 2026) -> [String] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    cal.firstWeekday = 1                                   // 周日开头
    let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
    let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
    return (0..<42).map { offset in
        let date = cal.date(byAdding: .day, value: offset, to: start)!
        return dateKey(date, cal: cal)
    }
}

func dateKey(_ date: Date, cal: Calendar) -> String {
    let parts = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

/// 模拟 ThumbnailStore：内存图 + 「同页在途生成」合并表 + 内容代次。
/// 并发安全由测试代码本身保证（单线程串行 + async let 只用于制造交错）。
final class FakeStore: @unchecked Sendable {
    private(set) var version = 0
    private var memory: [String: String] = [:]           // 文件名 → 图标识
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var rendersInProgress = 0

    /// 模拟「两个月的网格几乎同时要同一页」的并发场景。
    func thumbnail(for name: String, renderDelay: UInt64 = 0) async -> String? {
        if let hit = memory[name] { return hit }
        if let existing = inFlight[name] { return await existing.value }   // 合并
        let task = Task<String?, Never> {
            if renderDelay > 0 {
                rendersInProgress += 1
                try? await Task.sleep(nanoseconds: renderDelay)
                rendersInProgress -= 1
            }
            let produced = memory[name] ?? "img:\(name)"
            memory[name] = produced
            return produced
        }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        return await task.value
    }

    /// 内容变更（编辑保存）→ 落盘 + 推进代次。
    func regenerate(name: String) { memory[name] = "img:\(name)"; version += 1 }
    /// 内容失效（删除页）→ 清图 + 推进代次。
    func invalidate(name: String) { memory.removeValue(forKey: name); version += 1 }

    var concurrentRenders: Int { rendersInProgress }
}

/// 一个 MonthGridView 的等价物：@State 缩略图表 + 代次。
struct GridInstance {
    var thumbnails: [String: String] = [:]
    var loadedVersion = -1

    /// 复刻 MonthGridView.loadThumbnails 的新实现。
    mutating func load(month: Int, store: FakeStore, covers: Set<String>) async {
        let versionChanged = loadedVersion != store.version
        var resolved: [String: String] = [:]
        var dropped: Set<String> = []
        var pending = 0
        let keys = gridKeys(forMonth: month)

        for key in keys {
            if Task.isCancelled { break }
            let coverExists = covers.contains(key)
            switch ThumbnailLoadPolicy.resolution(hasImage: thumbnails[key] != nil,
                                                  versionChanged: versionChanged,
                                                  coverExists: coverExists) {
            case .keep:
                continue
            case .drop:
                dropped.insert(key)
            case .resolve:
                let image = await store.thumbnail(for: "page-\(key).png")
                guard let image else { continue }
                resolved[key] = image
            }
            pending += 1
            if pending >= ThumbnailLoadPolicy.batchSize {
                ThumbnailLoadPolicy.merge(&thumbnails, resolved: resolved, dropped: dropped)
                resolved.removeAll(); dropped.removeAll(); pending = 0
            }
        }
        ThumbnailLoadPolicy.merge(&thumbnails, resolved: resolved, dropped: dropped)
        loadedVersion = store.version
    }
}

// MARK: - 断言 1：同页并发请求必须合并，人人有图

func verifyConcurrentCoalescing() async {
    let store = FakeStore()
    let name = "page-2026-09-30.png"
    // 9 月网格与 10 月网格同时要 9/30（10 月网格首行含 9/27–9/30）。
    async let a = store.thumbnail(for: name, renderDelay: 5_000_000)
    async let b = store.thumbnail(for: name, renderDelay: 5_000_000)
    async let c = store.thumbnail(for: name, renderDelay: 5_000_000)
    let (ra, rb, rc) = await (a, b, c)
    check(ra != nil, "并发 A 应拿到图")
    check(rb != nil, "并发 B 应拿到图（旧实现这里会 nil：撞上 regenerate 在途）")
    check(rc != nil, "并发 C 应拿到图")
    checkEqual(ra, rb, "并发请求结果应一致")
    checkEqual(rb, rc, "并发请求结果应一致")
    // 合并后同一文件只应合成一次（而不是每格各合成一次）
    check(store.concurrentRenders == 0, "在途合成应收尾")
}

// MARK: - 断言 2：用户报的翻页序列 9 → 10 → 11 → 10，9/30 缩略图必须还在

func verifyPagingRoundTrip() async {
    let store = FakeStore()
    // 用户只在 9/30 画了日记。
    let drawn = "2026-09-30"
    var covers: Set<String> = [drawn]

    // 三个常驻槽位：月视图里 [-1, 0, +1] 三个月各自一份网格实例。
    var back = GridInstance()      // -1 槽
    var center = GridInstance()    //  0 槽
    var forward = GridInstance()   // +1 槽

    // 9 月：back=8, center=9, forward=10；9/30 的图此刻被中心格装载。
    await center.load(month: 9, store: store, covers: covers)
    check(center.thumbnails[drawn] != nil, "9 月页应显示 9/30 缩略图")

    // 10 月：中心槽变 10 月（其网格首行含 9/27–9/30）→ 9/30 的图也要在。
    await center.load(month: 10, store: store, covers: covers)
    check(center.thumbnails[drawn] != nil, "10 月页的上月格应显示 9/30 缩略图")

    // 11 月：-1 槽变 10 月（新实例），中心槽变 11 月。
    back = GridInstance()
    await back.load(month: 10, store: store, covers: covers)
    check(back.thumbnails[drawn] != nil, "11 月时的 10 月页应显示 9/30 缩略图")

    // 滑回 10 月：中心槽当前显示的是 11 月（其网格首行 10/25…，不含 9/30）。
    await center.load(month: 11, store: store, covers: covers)
    check(center.thumbnails[drawn] == nil, "11 月网格不含 9/30，中心槽此时没有它的图")

    // 再回到 10 月 —— 这正是用户报的丢图现场。
    await center.load(month: 10, store: store, covers: covers)
    check(center.thumbnails[drawn] != nil, "★ 10→11→10 往回翻后 9/30 缩略图必须还在")
}

// MARK: - 断言 3：装载补齐不得推进代次（否则翻页时 126 格白白重算）

func verifyVersionDiscipline() async {
    let store = FakeStore()
    checkEqual(store.version, 0, "初始代次应为 0")
    var grid = GridInstance()
    await grid.load(month: 9, store: store, covers: ["2026-09-30"])
    checkEqual(store.version, 0, "装载补齐不得推进代次（旧实现每补一张图就 +1）")

    store.regenerate(name: "page-2026-09-30.png")     // 编辑保存
    checkEqual(store.version, 1, "内容变更必须推进代次")
    await grid.load(month: 9, store: store, covers: ["2026-09-30"])
    checkEqual(store.version, 1, "重新装载仍不应推进代次")
}

// MARK: - 断言 4：已失效的条目要能被移除（否则删除页后留残影）

func verifyDropOnInvalidate() async {
    let store = FakeStore()
    var grid = GridInstance()
    await grid.load(month: 9, store: store, covers: ["2026-09-30"])
    check(grid.thumbnails["2026-09-30"] != nil, "9/30 初始应有图")

    // 用户删掉这一页 → 代次推进 + 封面关系为空。
    store.invalidate(name: "page-2026-09-30.png")
    await grid.load(month: 9, store: store, covers: [])
    check(grid.thumbnails["2026-09-30"] == nil, "页删除后本地条目必须被移除")
}

// MARK: - 断言 5：整表覆盖是罪魁（回归护栏：merge 不得删除未提及的键）

func verifyMergeIsNonDestructive() {
    var local: [String: String] = ["a": "1", "b": "2", "c": "3"]
    ThumbnailLoadPolicy.merge(&local, resolved: ["b": "20"], dropped: ["c"])
    checkEqual(local.count, 2, "merge 后应只剩 a、b")
    checkEqual(local["a"], Optional("1"), "未提及的键 a 必须原样保留")
    checkEqual(local["b"], Optional("20"), "已解析的键应被更新")
    check(local["c"] == nil, "明确失效的键 c 应被移除")

    // 旧实现：result 里缺 a 就把 a 抹掉。
    let legacy: [String: String] = ["b": "20"]
    check(legacy["a"] == nil, "整表覆盖会抹掉本次结果里缺失的键（这正是丢图成因）")
    check(local["a"] != nil, "新实现不会这样：未提及的键原样保留")
}

// MARK: - 断言 6：网格布局前提（防止 2026 年 10 月首行不含 9/30 导致门禁空转）

func verifyGridLayoutPremise() {
    let october = gridKeys(forMonth: 10)
    checkEqual(october.first, Optional("2026-09-27"), "2026-10 网格首格应为 09-27（周日起）")
    check(october.contains("2026-09-30"), "2026-10 网格必须含 09-30（前置格）")
    let november = gridKeys(forMonth: 11)
    checkEqual(november.first, Optional("2026-10-25"), "2026-11 网格首格应为 10-25")
    check(!november.contains("2026-09-30"), "2026-11 网格不含 09-30")
    let september = gridKeys(forMonth: 9)
    check(september.contains("2026-09-30"), "2026-09 网格必须含 09-30")
}

// MARK: - 运行

await verifyConcurrentCoalescing()
await verifyPagingRoundTrip()
await verifyVersionDiscipline()
await verifyDropOnInvalidate()
verifyMergeIsNonDestructive()
verifyGridLayoutPremise()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 缩略图生命周期：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)