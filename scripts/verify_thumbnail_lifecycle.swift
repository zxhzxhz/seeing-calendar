#!/usr/bin/env swift
//
//  verify_thumbnail_lifecycle.swift
//  月历缩略图生命周期门禁（CI 以 --strict 执行）
//
//  这个门禁管两类 bug，都是用户实测报回来的：
//
//  【冷启动空白】1.0.18 / 1.0.19 都栽在这上面。
//     装载结果原本存在 `MonthGridView` 的 `@State` 里，`.task(id:)` 一被父层指纹
//     取消就整批丢 —— 「取消」与「结果丢失」是同一件事，装载结果依赖调度运气。
//     1.0.20 把图像表移进 `ThumbnailStore`（单例，跨视图共享、跨取消存活）。
//     本门禁从两个方向钉死它：① 装载逻辑的可收敛性/合并性；
//     ② 生产源码里不得再出现视图自持的缩略图表（文本同步护栏，见 D4）。
//
//  【清空页后缩略图不更新】月历上挂着清空前的残影，缩略图与内容不符。
//     成因有两个，得一起修：
//     ① 合成函数把「无笔迹且无贴图」和「读不到笔迹文件」都变成「没有结果」，
//        旧 PNG 于是原封不动留在磁盘上。1.0.20 引入三态结果 + 处置表：
//        只有**权威确认无内容**才允许删；「读不到」必须保留。
//     ② 清空是个不需要离线合成就能下结论的事实，不该等 2 秒防抖 + 一遍后台合成。
//        `clearPage()` 当场 `forget` 收图（乐观），`save()` 的 `regenerate` 随后
//        得出同样的结论 —— 幂等。
//     另外：`regenerate` 的合成是 `await` 的，撤「无内容」标记必须与写缓存同帧
//     （断言 9），否则挂起窗口里 `primeFromDisk` 会把磁盘陈图复活。
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

// MARK: - 被测逻辑（生产代码的镜像）

/// 镜像 `SeeingCalendar/Rendering/ThumbnailLoadPolicy.swift` 的 `ThumbnailRenderResult`。
/// 四个 case 的名字与语义必须与生产一致，漂移由断言 0 的文本护栏拦截。
enum RenderResult: Equatable {
    case png
    case empty
    case unreadable
    case failed
}

enum Disposition: Equatable {
    case commit
    case clear
    case preserve
}

enum ThumbnailLoadPolicy {
    static func disposition(for result: RenderResult) -> Disposition {
        switch result {
        case .png:                 return .commit
        case .empty:               return .clear
        case .unreadable, .failed: return .preserve
        }
    }

    static func advancesVersion(_ disposition: Disposition) -> Bool {
        disposition != .preserve
    }
}

// MARK: - 断言 0：与生产源码同源（文本护栏）

/// 从仓库根读生产源文件。脚本以 `swift scripts/xxx.swift` 运行，CWD 即仓库根。
func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 把连续空白压成单个空格，避开对齐空格带来的脆弱匹配。
func normalizeWhitespace(_ source: String) -> String {
    source.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        .joined(separator: " ")
}

/// 取出某个声明的主体文本（花括号配平）。找不到返回 nil。
/// 用来断言「函数体内不得出现某写法」，比全文件包含性断言精确得多。
func declarationBody(of declaration: String, in source: String) -> String? {
    guard let start = source.range(of: declaration),
          let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var index = open.lowerBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        else if character == "}" {
            depth -= 1
            if depth == 0 { return String(source[open.lowerBound...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

func verifyProductionSourceSync() {
    guard let policy = productionSource("SeeingCalendar/Rendering/ThumbnailLoadPolicy.swift") else {
        check(false, "读不到生产文件 ThumbnailLoadPolicy.swift（门禁必须在仓库根运行）")
        return
    }
    let flatPolicy = normalizeWhitespace(policy)
    // 处置表必须与本地镜像逐臂一致。
    for arm in ["case .png: return .commit",
                "case .empty: return .clear",
                "case .unreadable, .failed: return .preserve"] {
        check(flatPolicy.contains(arm), "ThumbnailLoadPolicy 缺少处置臂：`\(arm)`")
    }
    // 比表达式而不是比“带了 return 的整行”：单表达式函数体里的 `return` 是可省的，
    // 护栏钉的是语义（只有 preserve 不推进代次），不是句法写法。
    check(flatPolicy.contains("disposition != .preserve"),
          "ThumbnailLoadPolicy.advancesVersion 必须只对 preserve 返回 false")

    guard let renderer = productionSource("SeeingCalendar/Rendering/ThumbnailRenderer.swift") else {
        check(false, "读不到生产文件 ThumbnailRenderer.swift")
        return
    }
    // 「确认为空」必须要求笔迹文件**读得到** —— 否则新建页（没有 .drawing）会被当成空页。
    check(normalizeWhitespace(renderer).contains("return drawingReadable ? .empty : .unreadable"),
          "renderPNG 必须区分「确认为空」与「读不到」：空页判定不得脱离 drawingReadable")

    guard let grid = productionSource("SeeingCalendar/Views/MonthGridView.swift") else {
        check(false, "读不到生产文件 MonthGridView.swift")
        return
    }
    // 冷启动 bug 的结构性护栏：月历不得自持缩略图表。
    check(!grid.contains("@State private var thumbnails"),
          "MonthGridView 不得再自持缩略图 @State（图像表必须住在 ThumbnailStore）")
    check(!grid.contains("loadedVersion"),
          "MonthGridView 不得再有 loadedVersion 这类本地代次记账")
    check(grid.contains("primeFromDisk"),
          "MonthGridView 的装载必须先走 ThumbnailStore.primeFromDisk（磁盘批量补齐）")

    // ── 清空页 bug 的两条新不变量 ────────────────────────────────────────────
    guard let store = productionSource("SeeingCalendar/Store/ThumbnailStore.swift") else {
        check(false, "读不到生产文件 ThumbnailStore.swift")
        return
    }
    if let body = declarationBody(of: "func regenerate(_ slot: ThumbnailSlot", in: store) {
        // 撤标记这件事必须与写缓存同帧发生。若在 `await render` 之前先撤，
        // 挂起期间月历重启跑 `primeFromDisk` 就会把磁盘上那张**陈旧** PNG 复活
        // —— 代次已经被 `forget` 推进过，月历正好在那时重拉。
        check(!body.contains("emptySlots.remove("),
              "★ regenerate 不得在合成挂起前撤掉无内容标记（会让陈旧 PNG 在挂起窗口里复活）")
    } else {
        check(false, "找不到 regenerate(_:page:) 定义")
    }
    if let body = declarationBody(of: "func forget(_ slot: ThumbnailSlot", in: store) {
        // 【M3 显式化同步】以下两条字面量随 M3 相位机改动同步：
        // ① 旧的 `version &+= 1` 与 ② 旧的 `emptySlots.insert(` 都已收进唯一的
        //   相位折叠 + 代次推进入口 `apply(.forgot, to:)`。`.forgot` 在
        //   SlotLifecyclePolicy.advancesVersion 里恒为真（代次必然推进），
        //   相位落到 .confirmedEmpty（取代旧的 emptySlots.insert）。
        // 语义未变：forget 仍是「推进代次 + 落到确认为空」。
        check(body.contains("apply(.forgot"),
              "forget 是内容变更（清空），必须经 apply(.forgot) 推进代次，否则 EquatableView 不重算")
        check(body.contains(".forgot"),
              "forget 必须落到 .confirmedEmpty 相位（取代旧 emptySlots.insert），否则会拿磁盘陈图把它复活")
        check(body.contains("removeItem(at: AppPaths.thumbnailURL(fileName))"),
              "forget 必须同时删掉磁盘上那张已知陈旧的 PNG")
    } else {
        check(false, "找不到 forget(_:fileName:) 定义")
    }
    // 只删文件、不收内存条目的旧 API 不得回潮：缓存现在住在单例里，
    // 只删磁盘 PNG 的话，删页之后月历会一直挂着那一页的旧图且无人刷新。
    check(!store.contains("func invalidate(_ fileName: String)"),
          "★ 不得恢复按文件名失效的 invalidate(fileName:)（它无法收走内存条目）")

    // ── M3 负向护栏：旧的 emptySlots 成员集合必须消失 ──────────────────────
    // 它的语义（权威确认为空）已被单一真值表 states 的 .confirmedEmpty 相位完全吸收。
    // 若它回潮，说明「四张表涌现一个状态」的旧形状又回来了。
    check(!store.contains("private var emptySlots: Set<String> = []"),
          "★ ThumbnailStore 不得再有 emptySlots 成员集合（语义已被 .confirmedEmpty 相位吸收）")

    // ── 冷启动 bug 的真根因护栏：写入 images 必须与推进代次同帧 ─────────────
    //
    // 1.0.19 的失败链条：读路径 `thumbnail(for:)` 直接命中 NSCache 后返回，**没有任何
    // 代次推进**；于是图已到 `@State thumbnails` 里，但 `thumbnailVersion` 没变 →
    // `MonthPager` 的 `EquatableView` 判定相等 → MonthGridView.body 不重算 →
    // 子视图自己的 `@State` 写入被短路由吞掉。用户点一下日期格（`selectedDate` 在
    // 等值判定里）才强制重算，图才出现 —— 正是报的「启动后不显示，点一下才出现」。
    //
    // 因此不变量是：**凡改写 `images`，同一同步作用域里必须 `version &+= 1`**。
    if let body = declarationBody(of: "func primeFromDisk(", in: store) {
        check(body.contains("version &+= 1"),
              "★ primeFromDisk（冷启动磁盘补齐路径）必须推进代次，否则刚补进来的图跨不过等值短路")
        check(body.contains("if changed") || body.contains("changed ="),
              "primeFromDisk 必须成批只推进一次代次（逐格推进会让根视图白重算几十轮）")
    } else {
        check(false, "找不到 primeFromDisk(_:)")
    }
    if let body = declarationBody(of: "func image(_ slot: ThumbnailSlot)", in: store) {
        check(!body.contains("version"),
              "渲染路径的读入口必须是纯字典查找：不推进代次、不做 IO、无副作用")
    } else {
        check(false, "找不到 image(_:)")
    }
    if let body = declarationBody(of: "private func commit(_ image: UIImage", in: store) {
        check(!body.contains("version"),
              "★ 淘汰不得推进代次：否则「补进来 → 挤掉别的 → 再补」会变成每轮重算的死循环")
    } else {
        check(false, "找不到 commit(_:forKey:)")
    }
    // 容量必须大于「任何一屏可能同时需要的槽位数」：3 个月 × 42 格 = 126，抽屉预览若干。
    if let limitText = store.components(separatedBy: "memoryLimit = ").dropFirst().first,
       let limit = Int(limitText.prefix(while: { $0.isNumber })) {
        check(limit >= 3 * 42,
              "★ memoryLimit(\(limit)) 必须 ≥ 126，否则淘汰会在月历上反复振荡")
    } else {
        check(false, "读不到 memoryLimit 字面值")
    }

    guard let editor = productionSource("SeeingCalendar/Views/EditorModel.swift") else {
        check(false, "读不到生产文件 EditorModel.swift")
        return
    }
    if let body = declarationBody(of: "func clearPage()", in: editor) {
        // “用户清空了这一页”是不需要离线合成就能下结论的事实，所以必须当场收图，
        // 不能等 markDirty 的 2 秒防抖 + 一遍后台 PNG 合成。
        check(body.contains("ThumbnailStore.shared.forget(page.pageSlot"),
              "★ 清空必须立刻乐观收图（forget），否则月历会接着挂清空前的图")
        check(body.contains("markDirty()"), "清空仍需落盘（markDirty → save）")
    } else {
        check(false, "找不到 clearPage() 定义")
    }
    // 删页路径同样必须收内存条目（含封面槽位）。
    guard let repository = productionSource("SeeingCalendar/Store/PageRepository.swift") else {
        check(false, "读不到生产文件 PageRepository.swift")
        return
    }
    if let body = declarationBody(of: "func removeFiles(for page: DrawingPage)", in: repository) {
        check(body.contains("ThumbnailStore.shared.forget(page.pageSlot"),
              "★ 删页必须收走该页的内存条目（否则月历永远挂着已删页的旧图）")
        check(body.contains("ThumbnailStore.shared.forget(page.coverSlot"),
              "删页时如果删的是封面，必须一并收走封面槽位")
        check(body.contains("let wasCover = page.day?.coverPage?.uuid == page.uuid"),
              "封面槽位只能在被删页确实是封面时才动（非封面页共享 dayKey，误删会错杀当天封面）")
    } else {
        check(false, "找不到 removeFiles(for:) 定义")
    }
    // 点击「完成」必过 save() → refreshThumbnails，封面/单页两个槽位都要重算。
    if let body = declarationBody(of: "private func refreshThumbnails(for page: DrawingPage)", in: editor) {
        check(body.contains("regenerate(page.coverSlot"), "完成时必须重算封面槽位")
        check(body.contains("regenerate(page.pageSlot"), "完成时必须重算单页槽位（抽屉预览）")
        check(body.contains("day.coverPage?.uuid == page.uuid"),
              "封面判定必须问模型（day.coverPage），不得复述 page.index == 0")
    } else {
        check(false, "找不到 refreshThumbnails(for:) 定义")
    }
    // 点击「完成」必过落盘 → refreshThumbnails，封面/单页两个槽位都要重算。
    //
    // 这里钉的是**语义**而不是旧句法：“完成”必须先落盘。落盘入口已统一到
    // `flushPendingSave()`（撤销/重做也走它，因为撤销是已定型动作、不该走 2s 去抖），
    // 所以断言分两步：完成必须经过它，而它必须真的写盘（并撤掉去抖中的那次重复写盘）。
    check(declarationBody(of: "func finishEditing()", in: editor)?.contains("flushPendingSave()") == true,
          "点击完成必须先落盘（缩略图重算挂在 save() 里）")
    if let flush = declarationBody(of: "func flushPendingSave()", in: editor) {
        check(flush.contains("saveTask?.cancel()"),
              "立即落盘必须先撤掉去抖中的那次写盘（否则 2s 后会重复写一遍）")
        check(flush.contains("save()"), "立即落盘必须真的写盘")
    } else {
        check(false, "找不到 flushPendingSave() 定义")
    }
}

// MARK: - 缩略图 store 模拟

/// 镜像 `ThumbnailStore` 的关键决策：内存表 + 无内容标记 + 内容代次 + 在途合并。
///
/// `@MainActor` 与生产一致：生产 `ThumbnailStore` 本身就是 `@MainActor` 单例，
/// 只有镜像了隔离属性才算真的镜像了它。这里从前是个 nonisolated 的 `final class`，
/// 用 `@unchecked` 冒充 `Sendable`、注释里写「这里单线程串行」——而顶层代码在 Swift 5
/// 模式下是 nonisolated 的，`async let` 子任务于是落到全局并发池：断言 6 的三个
/// `async let` 同时读写同一个 Swift Dictionary，CI 上直接 `Segmentation fault: 11`。
/// 隔离必须写在类型上，不能写在注释里。
@MainActor
final class FakeStore {
    private(set) var images: [String: String] = [:]        // 槽位键 → 图标识
    private(set) var emptySlots: Set<String> = []
    private(set) var version = 0
    private(set) var renders = 0                           // 实际执行的合成次数
    /// 磁盘（槽位键 → 文件名）→ PNG 是否存在。合成会写回这里，模拟落盘。
    private(set) var diskPNGs: Set<String> = []
    /// 门禁专用：往假磁盘里放一张 PNG（模拟上一轮退出时留下的文件 / 删文件失败）。
    /// `diskPNGs` 本身是 `private(set)`，断言不得直接改它。
    func seedDiskPNG(_ slot: String) { diskPNGs.insert(slot) }
    /// 磁盘上有笔迹文件（`renderPNG` 能不能读到内容）。
    var drawingFiles: Set<String> = []
    /// 下一次合成的返回（用于制造 .empty / .unreadable 场景）。
    var nextRenderResult: RenderResult = .png
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// 装载路径（结论明确同样推进代次，与生产 `ThumbnailStore.settle` 一致）。
    func load(_ slot: String, name: String, drawingGone: Bool = false) async -> String? {
        if let hit = images[slot] { return hit }
        if emptySlots.contains(slot) { return nil }
        if diskPNGs.contains(slot) {
            images[slot] = "img:\(slot)"
            version += 1
            return images[slot]
        }
        if !drawingGone, let existing = inFlight[name] { return await existing.value }
        let task = Task<String?, Never> { [self] in
            renders += 1
            try? await Task.sleep(nanoseconds: 3_000_000)   // 制造交错窗口
            let outcome = drawingFiles.contains(name) ? nextRenderResult : RenderResult.unreadable
            switch ThumbnailLoadPolicy.disposition(for: outcome) {
            case .commit:
                diskPNGs.insert(slot); images[slot] = "img:\(slot)"; version += 1; return images[slot]
            case .clear:
                diskPNGs.remove(slot); images.removeValue(forKey: slot); emptySlots.insert(slot)
                version += 1
                return nil
            case .preserve:
                return nil
            }
        }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        return await task.value
    }

    /// 磁盘批量补齐（最多推进一次代次）。
    func primeFromDisk(_ entries: [(slot: String, name: String)]) -> [(slot: String, name: String)] {
        var misses: [(slot: String, name: String)] = []
        var changed = false
        for entry in entries {
            if images[entry.slot] != nil { continue }
            if emptySlots.contains(entry.slot) { continue }
            if diskPNGs.contains(entry.slot) { images[entry.slot] = "img:\(entry.slot)"; changed = true }
            else { misses.append(entry) }
        }
        if changed { version += 1 }
        return misses
    }

    /// 内容变更路径（编辑保存 / 清空页）。
    ///
    /// 与生产 `ThumbnailStore.regenerate` 一致：**这里不预撤 `emptySlots`**，
    /// 撤标记只发生在 `.commit` 分支（即写缓存那一帧）。合成用 `await` 模拟挂起，
    /// 好让断言 9 把「挂起窗口里 `primeFromDisk` 把陈旧 PNG 复活」这个坑钉死。
    func regenerate(_ slot: String, name: String) async {
        try? await Task.sleep(nanoseconds: 3_000_000)
        renders += 1
        let outcome = drawingFiles.contains(name) ? nextRenderResult : RenderResult.unreadable
        let disposition = ThumbnailLoadPolicy.disposition(for: outcome)
        switch disposition {
        case .commit:
            emptySlots.remove(slot)          // 写缓存与撤标记同帧，不可分割
            diskPNGs.insert(slot); images[slot] = "img:\(slot)"
        case .clear:
            diskPNGs.remove(slot); images.removeValue(forKey: slot); emptySlots.insert(slot)
        case .preserve:
            return   // 非破坏：保留已有图，且不推进代次
        }
        if ThumbnailLoadPolicy.advancesVersion(disposition) { version += 1 }
    }

    /// 乐观收图（用户执行清空 / 页被删除）：不需要离线合成就能下结论的事实。
    ///
    /// 与生产 `ThumbnailStore.forget(_:fileName:)` 对应：磁盘 PNG 也当场删
    /// （磁盘在镜像里按槽位键，生产里按文件名）。
    func forget(_ slot: String) {
        diskPNGs.remove(slot)
        images.removeValue(forKey: slot)
        emptySlots.insert(slot)
        version += 1
    }

    func image(_ slot: String) -> String? { images[slot] }
}

// MARK: - 断言 1：处置表（「确认为空」才允许删）

func verifyDispositionTable() {
    checkEqual(ThumbnailLoadPolicy.disposition(for: .png), Disposition.commit, "有图 → 提交")
    checkEqual(ThumbnailLoadPolicy.disposition(for: .empty), Disposition.clear, "确认为空 → 清除")
    checkEqual(ThumbnailLoadPolicy.disposition(for: .unreadable), Disposition.preserve,
               "★ 读不到笔迹不得当成空页（新建页本来就没有 .drawing）")
    checkEqual(ThumbnailLoadPolicy.disposition(for: .failed), Disposition.preserve, "合成失败 → 保留")

    check(ThumbnailLoadPolicy.advancesVersion(.commit), "提交后必须推进代次")
    check(ThumbnailLoadPolicy.advancesVersion(.clear), "清空后必须推进代次")
    check(!ThumbnailLoadPolicy.advancesVersion(.preserve), "拿不到结论时不得推进代次")
}

// MARK: - 断言 2：★ 用户报的 bug —— 清空页后缩略图必须立刻消失

@MainActor
func verifyClearPageRefreshesCover() async {
    let store = FakeStore()
    let slot = "cover|2026-10-08"
    let name = "page-2026-10-08.png"

    // 用户画了东西并保存 → 月历上有图。
    store.drawingFiles.insert(name)
    store.nextRenderResult = .png
    await store.regenerate(slot, name: name)
    check(store.image(slot) != nil, "保存后月历封面应有图")
    check(store.diskPNGs.contains(slot), "保存后磁盘上应有 PNG")
    let versionAfterDraw = store.version

    // 用户点「清空当前页」：乐观收图，旧图与磁盘 PNG 当场消失（不等防抖也不等合成）。
    store.nextRenderResult = .empty
    store.forget(slot)
    check(store.image(slot) == nil, "★ 点清空后旧图必须当场从月历消失（乐观收图）")
    check(!store.diskPNGs.contains(slot), "★ 点清空后磁盘陈旧 PNG 必须当场删除（不留复活口）")
    check(store.version > versionAfterDraw, "★ 清空必须推进代次，否则月历不重算")

    // 用户接着点「完成」：save() → regenerate 得出同样的「确认为空」。
    await store.regenerate(slot, name: name)
    check(store.image(slot) == nil, "★ 清空后内存条目必须被收走（缩略图与内容不符的根因）")
    check(!store.diskPNGs.contains(slot), "★ 清空后磁盘 PNG 必须被删除（否则下次冷启动又冒出来）")

    // 清空后重新保存一张 —— 标记必须被撤掉，图要能回来。
    store.nextRenderResult = .png
    await store.regenerate(slot, name: name)
    check(store.image(slot) != nil, "清空后再作画，缩略图必须能重新生成")

    // 同一槽位再清一次：乐观收图之后，磁盘不得被 primeFromDisk 重新扶进来。
    store.nextRenderResult = .empty
    store.forget(slot)
    _ = store.primeFromDisk([(slot: slot, name: name)])
    check(store.image(slot) == nil, "★ 清空后重启装载不得把旧图扶回月历")
}

// MARK: - 断言 3：新建页（没有笔迹文件）不得误删封面

@MainActor
func verifyNewPageDoesNotWipeCover() async {
    let store = FakeStore()
    let coverSlot = "cover|2026-10-09"
    let coverName = "page-2026-10-09.png"
    let freshName = "page-2026-10-09-1.png"     // 新加的拓展页：没有 .drawing

    store.drawingFiles.insert(coverName)
    store.nextRenderResult = .png
    await store.regenerate(coverSlot, name: coverName)
    check(store.image(coverSlot) != nil, "封面应先有图")
    let versionBefore = store.version

    // 用户新加一页 → 立刻保存。新页没有笔迹文件 → renderPNG 得 .unreadable。
    store.nextRenderResult = .unreadable
    await store.regenerate("page|fresh-uuid", name: freshName)
    check(store.image(coverSlot) != nil, "★ 新页保存不得擦掉封面缩略图（.unreadable 必须 preserve）")
    checkEqual(store.version, versionBefore, "拿不到结论时不得推进代次（否则月历白拉一轮）")
}

// MARK: - 断言 4：冷启动磁盘批量补齐只推进一次代次

@MainActor
func verifyColdStartBulkPrime() async {
    let store = FakeStore()
    // 上一轮退出时留下的 42 张 PNG。
    var entries: [(slot: String, name: String)] = []
    for day in 1...42 {
        let key = String(format: "2026-10-%02d", day)
        entries.append((slot: "cover|\(key)", name: "page-\(key).png"))
        store.seedDiskPNG("cover|\(key)")
    }
    let misses = store.primeFromDisk(entries)
    check(misses.isEmpty, "磁盘都有图时不应产生待合成项")
    checkEqual(store.version, 1, "★ 42 张批量补齐只许推进一次代次（逐格提交会让根视图白重算 42 轮）")
    checkEqual(store.images.count, 42, "42 格都应补齐")
    // 再跑一轮必须完全静默（否则 .task(id:) 会被自己的写入反复重启）。
    let second = store.primeFromDisk(entries)
    check(second.isEmpty, "第二轮不得再产生待合成项")
    checkEqual(store.version, 1, "第二轮不得推进代次（收敛性：否则形成重启死循环）")
}

// MARK: - 断言 5：已确认无内容的槽位不得反复重算（收敛性）

@MainActor
func verifyConfirmedEmptyConverges() async {
    let store = FakeStore()
    let slot = "cover|2026-10-10"
    let name = "page-2026-10-10.png"
    store.drawingFiles.insert(name)      // 文件在，但内容为空

    store.nextRenderResult = .empty
    _ = await store.load(slot, name: name)
    check(store.emptySlots.contains(slot), "确认为空后应记入无内容标记")
    let rendersAfterFirst = store.renders

    // 后续每一轮装载都不得再合成（否则 version 反复变 → 视图反复重启 → 死循环）。
    for _ in 0..<3 {
        let miss = store.primeFromDisk([(slot: slot, name: name)])
        check(miss.isEmpty, "已确认无内容的槽位不得再列为待合成项")
        if let m = miss.first { _ = await store.load(m.slot, name: m.name) }
    }
    checkEqual(store.renders, rendersAfterFirst, "★ 已确认无内容的页不得反复重算")
}

// MARK: - 断言 6：同页并发请求必须合并，人人有图

@MainActor
func verifyConcurrentCoalescing() async {
    let store = FakeStore()
    let name = "page-2026-09-30.png"
    store.drawingFiles.insert(name)
    store.nextRenderResult = .png
    // 9 月网格与 10 月网格同时要 9/30（10 月网格首行含 9/27–9/30）。
    async let a = store.load("cover|2026-09-30", name: name)
    async let b = store.load("cover|2026-09-30", name: name)
    async let c = store.load("cover|2026-09-30", name: name)
    let (ra, rb, rc) = await (a, b, c)
    check(ra != nil && rb != nil && rc != nil, "★ 并发三方都必须拿到图（抢输那格不得为空）")
    checkEqual(ra, rb, "并发请求结果应一致")
    checkEqual(store.renders, 1, "同一页并发只应合成一次（在途合并）")
}

// MARK: - 断言 7：非破坏 —— 拿不到结论时已有图必须原样保留

@MainActor
func verifyNonDestructiveOnUnavailable() async {
    let store = FakeStore()
    let slot = "cover|2026-10-11"
    let name = "page-2026-10-11.png"
    store.drawingFiles.insert(name)
    store.nextRenderResult = .png
    await store.regenerate(slot, name: name)
    check(store.image(slot) != nil, "先要有图")
    let versionBefore = store.version

    // 模拟读盘抖动：文件这次读不到。
    store.drawingFiles.remove(name)
    store.nextRenderResult = .png
    await store.regenerate(slot, name: name)
    check(store.image(slot) != nil, "★ 读盘抖动不得擦掉用户的缩略图")
    checkEqual(store.version, versionBefore, "不得推进代次")

    // 装载路径同样不得破坏。
    _ = await store.load(slot, name: name, drawingGone: true)
    check(store.image(slot) != nil, "装载路径遇到读不到也不得破坏已有图")
}

// MARK: - 断言 9：★ 合成挂起窗口里不得让陈旧 PNG 复活

/// 这是 1.0.20 修法里最容易复发的一个坑，值得单独钉。
///
/// `regenerate` 是 `await` 的。如果它在挂起**之前**就把 `emptySlots` 标记撤掉，
/// 而 `forget` 又刚好把内存条目收了、代次推了 —— 月历会恰好在那个窗口里重启，
/// 跑一轮 `primeFromDisk`：内存里没图、标记也没了，磁盘上那张**陈旧** PNG
/// 就被扶回缓存，用户看到清空的图又回来了。
/// 修法：撤标记只能发生在 `.commit`（写缓存那一帧）。
@MainActor
func verifyNoStaleResurrectionDuringRegenerate() async {
    let store = FakeStore()
    let slot = "cover|2026-10-12"
    let name = "page-2026-10-12.png"

    store.drawingFiles.insert(name)
    store.nextRenderResult = .png
    await store.regenerate(slot, name: name)
    check(store.image(slot) != nil && store.diskPNGs.contains(slot), "先要有图 + 磁盘 PNG")

    // 清空（乐观收图）→ 完成（触发后台合成）。合成还在挂起。
    store.nextRenderResult = .empty
    store.forget(slot)
    // 故意把陈旧 PNG 拨回磁盘：模拟 `forget` 那一步删文件失败（磁盘满 / 权限）。
    // 排查不能只依赖「文件已经删了」，标记必须自己顶得住。
    store.seedDiskPNG(slot)
    async let regenerating: Void = store.regenerate(slot, name: name)
    try? await Task.sleep(nanoseconds: 1_500_000)          // 落在合成挂起窗口内
    _ = store.primeFromDisk([(slot: slot, name: name)])     // 月历恰在此刻重启
    check(store.image(slot) == nil, "★ 合成挂起窗口内不得让陈旧 PNG 复活（清空的图必须保持消失）")
    await regenerating
    check(store.image(slot) == nil, "合成完成后也必须是空")
    check(!store.diskPNGs.contains(slot), "清空后磁盘 PNG 必须被删除")
}

// MARK: - 断言 8：网格布局前提（防止 2026 年 10 月首行不含 9/30 导致门禁空转）

func gridKeys(forMonth month: Int, year: Int = 2026) -> [String] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    cal.firstWeekday = 1                                   // 周日开头
    let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
    let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
    return (0..<42).map { offset in
        let date = cal.date(byAdding: .day, value: offset, to: start)!
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

func verifyGridLayoutPremise() {
    let october = gridKeys(forMonth: 10)
    checkEqual(october.first, Optional("2026-09-27"), "2026-10 网格首格应为 09-27（周日起）")
    check(october.contains("2026-09-30"), "2026-10 网格必须含 09-30（前置格）")
    let november = gridKeys(forMonth: 11)
    checkEqual(november.first, Optional("2026-11-01"), "2026-11 网格首格应为 11-01（当日即周日）")
    check(!november.contains("2026-09-30"), "2026-11 网格不含 09-30")
    check(gridKeys(forMonth: 9).contains("2026-09-30"), "2026-09 网格必须含 09-30")
}

// MARK: - 断言 10：门禁自身的隔离前提（防数据竞争回潮）

/// `FakeStore` 必须自带 `@MainActor`，否则门禁自己就是数据竞争源。
///
/// 曾经的样子：`FakeStore` 是 nonisolated 的 `final class`，注释里写着「这里单线程串行」，
/// 而顶层代码在 Swift 5 模式下是 nonisolated 的 —— `async let` 子任务于是落到全局并发池，
/// 断言 6 的三个 `async let` 同时读写同一个 Swift Dictionary，CI 上直接
/// `Segmentation fault: 11`（exit 139）。重跑就绿，最容易被当成基础设施抖动放过去。
///
/// 比「随机红」更麻烦的是它的后果：**测量本身有竞争时，它的通过不说明被测逻辑是对的**。
/// 所以隔离必须写在类型上，不能写在注释里；`async let` 只允许出现在自带隔离的函数里。
///
/// 针脚一律拆开拼接（本门禁比对的是 `normalizeWhitespace` 后的原文，**不剥注释**），
/// 否则这个函数自己就成了命中项。
func verifyStoreIsolation() {
    guard let source = productionSource("scripts/verify_thumbnail_lifecycle.swift") else {
        check(false, "读不到门禁脚本自身（门禁必须在仓库根运行）")
        return
    }
    let flat = normalizeWhitespace(source)

    check(flat.contains("@MainActor " + "final class FakeStore"),
          "★ FakeStore 必须声明 @MainActor：它是可变状态的载体，隔离不能只写在注释里")
    check(!flat.contains("@unchecked" + " Sendable"),
          "★ 不得再用 @unchecked 给可变状态打口头担保冒充可并发 —— 那正是上次 SIGSEGV 的掩护")
    check(!flat.contains("Task." + "detached"),
          "★ 不得用脱开 main actor 的任务在隔离外碰状态：那等于把同一个竞争放回来")

    // 扁平化之后没有行号可用，于是用「两个 `func verify…` 之间的片段」当函数体：
    // 每个片段的头部是函数名，体是它到下一个验证函数声明之间的全部内容。
    // 隔离注解写在 `func` **之前**，所以它在**上一个**片段的尾部。
    let chunks = flat.components(separatedBy: "func verify")
    var storeDriven = 0
    for index in 1..<chunks.count {
        let chunk = chunks[index]
        guard let brace = chunk.firstIndex(of: "{") else { continue }
        guard String(chunk[brace...]).contains("FakeStore" + "(") else { continue }
        guard let paren = chunk.firstIndex(of: "(") else { continue }
        let name = String(chunk[chunk.startIndex..<paren])
        if name == "StoreIsolation" { continue }   // 这个函数自己就是针脚本体
        storeDriven += 1
        check(chunks[index - 1].hasSuffix("@MainActor "),
              "★ verify\(name) 驱动了 FakeStore，声明上必须带 @MainActor —— 否则它的 async let 子任务跑出主 actor，并发读写同一个字典")
    }
    check(storeDriven >= 7,
          "驱动 FakeStore 的验证函数应不少于 7 个，实际 \(storeDriven) 个：脚本结构变了，本护栏要跟着改")
}

// MARK: - 断言 11：★ M3 缩略图槽位相位机（四张表涌现的状态 → 单表显式状态）
//
// 镜像 `SeeingCalendar/Rendering/ThumbnailSlotLifecycle.swift` 的 SlotLifecycle /
// SlotEvent / SlotLifecyclePolicy。相位名与语义必须与生产一致；漂移由断言 13 的
// 文本护栏拦截。

enum SlotPhase: Equatable {
    case unknown
    case loading
    case present
    case confirmedEmpty

    var hasImage: Bool { self == .present }
    var isConfirmedEmpty: Bool { self == .confirmedEmpty }
    var needsLoad: Bool { self == .unknown }
    var blocksReload: Bool { self == .present || self == .loading }
}

enum SlotEv: Equatable {
    case loadBegan
    case loadSucceeded
    case loadConfirmedEmpty
    case loadUnavailable
    case forgot
    case evicted
}

/// 镜像生产的桥接枚举 `SlotSettlement`（处置 → 相位事件）。
enum SlotSettlement: Equatable {
    case commit
    case clear
    case preserve
}

enum SlotMachine {
    static func event(for settlement: SlotSettlement) -> SlotEv {
        switch settlement {
        case .commit:   return .loadSucceeded
        case .clear:    return .loadConfirmedEmpty
        case .preserve: return .loadUnavailable
        }
    }

    static func reduce(_ phase: SlotPhase, event: SlotEv) -> SlotPhase {
        switch event {
        case .loadBegan:          return phase == .unknown ? .loading : phase
        case .loadSucceeded:      return .present
        case .loadConfirmedEmpty: return .confirmedEmpty
        case .loadUnavailable:    return phase
        case .forgot:             return .confirmedEmpty
        case .evicted:            return phase == .present ? .unknown : phase
        }
    }

    static func isTerminal(_ phase: SlotPhase) -> Bool {
        phase == .present || phase == .confirmedEmpty
    }

    static func advancesVersion(from phase: SlotPhase, event: SlotEv) -> Bool {
        switch event {
        case .loadSucceeded, .loadConfirmedEmpty, .forgot:
            return isTerminal(reduce(phase, event: event))
        case .loadBegan, .loadUnavailable, .evicted:
            return false
        }
    }
}

/// 破坏变体：`.loadUnavailable` 会把相位清成 `.unknown` ——
/// 旧代码里「读不到 == 空 / 一次读盘抖动就擦掉用户的缩略图」的错误形状。
/// 正确实现必须与它分歧，否则检查器就是退化成恒真的。
enum BrokenSlotMachine {
    static func reduce(_ phase: SlotPhase, event: SlotEv) -> SlotPhase {
        if event == .loadUnavailable { return .unknown }
        return SlotMachine.reduce(phase, event: event)
    }
}

let allSlotPhases: [SlotPhase] = [.unknown, .loading, .present, .confirmedEmpty]
let allSlotEvents: [SlotEv] = [.loadBegan, .loadSucceeded, .loadConfirmedEmpty,
                               .loadUnavailable, .forgot, .evicted]

/// 断言 11：相位 × 事件穷举（24 组合）的五条不变量。
func verifySlotLifecycleMachine() {
    checkEqual(allSlotPhases.count * allSlotEvents.count, 24,
               "相位 × 事件必须穷举 24 组合（4 相位 × 6 事件）")

    for phase in allSlotPhases {
        for event in allSlotEvents {
            let label = "\(phase) × \(event)"
            let next = SlotMachine.reduce(phase, event: event)

            // 不变量 1：.loadUnavailable 在任何相位下都不改变相位（读取抖动不得擦图）。
            if event == .loadUnavailable {
                checkEqual(next, phase, "★ \(label)：.loadUnavailable 不得改变相位（非破坏）")
            }
            // 不变量 2：.evicted 从 .present 回到 .unknown；对其余相位原样返回。
            if event == .evicted {
                if phase == .present {
                    checkEqual(next, .unknown, "★ \(label)：.evicted 必须把 .present 打回 .unknown")
                } else {
                    checkEqual(next, phase, "\(label)：.evicted 对非 .present 相位应原样返回")
                }
                check(!SlotMachine.advancesVersion(from: phase, event: .evicted),
                      "★ \(label)：淘汰绝不推进代次")
            }
            // 不变量 5：.loading 收到 .loadBegan 幂等。
            if phase == .loading, event == .loadBegan {
                checkEqual(next, .loading, "★ \(label)：.loading × .loadBegan 必须幂等")
            }
            // .loadBegan 只把 .unknown 抬到 .loading，绝不降级已落定的相位。
            if event == .loadBegan {
                let expected: SlotPhase = phase == .unknown ? .loading : phase
                checkEqual(next, expected, "\(label)：.loadBegan 的落点")
            }
            // 结论事件从任何相位都落到对应结论态。
            if event == .loadSucceeded {
                checkEqual(next, .present, "\(label)：必须落到 .present")
            }
            if event == .loadConfirmedEmpty || event == .forgot {
                checkEqual(next, .confirmedEmpty, "\(label)：必须落到 .confirmedEmpty")
            }
            // 终态与代次的准入一致性：推进代次的转移必须落进终态。
            if SlotMachine.advancesVersion(from: phase, event: event) {
                check(SlotMachine.isTerminal(next), "\(label)：推进代次的转移必须落进终态")
            }
        }
    }
}

/// 断言 12：advancesVersion / needsLoad / blocksReload 的真值表。
func verifySlotLifecycleTruthTables() {
    // advancesVersion：恰好 loadSucceeded / loadConfirmedEmpty / forgot 为真。
    for phase in allSlotPhases {
        for event in allSlotEvents {
            let expected = (event == .loadSucceeded
                            || event == .loadConfirmedEmpty
                            || event == .forgot)
            checkEqual(SlotMachine.advancesVersion(from: phase, event: event), expected,
                       "advancesVersion(\(phase), \(event)) 必须为 \(expected)")
            if event == .loadUnavailable || event == .evicted {
                check(!SlotMachine.advancesVersion(from: phase, event: event),
                      "★ \(event) 不得推进代次（preserve / 淘汰固化的不变量）")
            }
        }
    }

    // needsLoad：恰好 .unknown 为真。
    for phase in allSlotPhases {
        checkEqual(phase.needsLoad, phase == .unknown, "needsLoad 必须恰好对 .unknown 为真")
    }
    check(SlotPhase.unknown.needsLoad, "★ .unknown 需要发起装载")
    check(!SlotPhase.loading.needsLoad, "在途不需要发起新装载")
    check(!SlotPhase.present.needsLoad, "有图不需要装载")
    check(!SlotPhase.confirmedEmpty.needsLoad, "确认空不需要装载")

    // blocksReload：present / loading 为真。
    check(SlotPhase.present.blocksReload && SlotPhase.loading.blocksReload,
          "present / loading 不得重复发起装载")
    check(!SlotPhase.unknown.blocksReload && !SlotPhase.confirmedEmpty.blocksReload,
          "unknown / confirmedEmpty 不阻止重载")

    // 处置 → 事件映射。
    checkEqual(SlotMachine.event(for: .commit), .loadSucceeded, "commit → loadSucceeded")
    checkEqual(SlotMachine.event(for: .clear), .loadConfirmedEmpty, "clear → loadConfirmedEmpty")
    checkEqual(SlotMachine.event(for: .preserve), .loadUnavailable, "preserve → loadUnavailable")

    // isTerminal。
    check(SlotMachine.isTerminal(.present), ".present 是终态")
    check(SlotMachine.isTerminal(.confirmedEmpty), ".confirmedEmpty 是终态")
    check(!SlotMachine.isTerminal(.unknown), ".unknown 不是终态")
    check(!SlotMachine.isTerminal(.loading), ".loading 不是终态")
}

/// 断言 13：反证 —— 「读不到就清成 .unknown」的破坏变体必须被抓到。
func verifyBrokenSlotVariantIsCaught() {
    var diverges = false
    for phase in allSlotPhases {
        for event in allSlotEvents {
            guard event == .loadUnavailable, phase != .unknown else { continue }
            if SlotMachine.reduce(phase, event: event) != BrokenSlotMachine.reduce(phase, event: event) {
                diverges = true
            }
        }
    }
    check(diverges, "★ 「读不到就清成 .unknown」的破坏变体必须与正确实现分歧（检查器不得退化成恒真）")

    let good = SlotMachine.reduce(.present, event: .loadUnavailable)
    let bad = BrokenSlotMachine.reduce(.present, event: .loadUnavailable)
    checkEqual(good, .present, "正确实现：.present 遇 .loadUnavailable 必须保留原相位（非破坏）")
    checkEqual(bad, .unknown, "破坏变体确实会清成 .unknown —— 反证有效")
    check(good != bad, "正反两实现必须在「有图 + 读不到」上分歧")
}

/// 断言 14：与生产源码同源（M3 文本护栏）。
///
/// 全部用**单行字面量**，绝不使用 `\n` 转义 —— 否则 gate_preflight.py
/// 处理不了转义、会误报。
func verifySlotLifecycleSourceSync() {
    guard let lifecycle = productionSource("SeeingCalendar/Rendering/ThumbnailSlotLifecycle.swift") else {
        check(false, "读不到生产文件 ThumbnailSlotLifecycle.swift")
        return
    }
    check(lifecycle.contains("enum SlotLifecycle: Equatable, Sendable"),
          "SlotLifecycle 必须是 Equatable + Sendable 的纯值类型")
    check(lifecycle.contains("case unknown"), "SlotLifecycle 必须保留 .unknown")
    check(lifecycle.contains("case loading"), "SlotLifecycle 必须保留 .loading")
    check(lifecycle.contains("case present"), "SlotLifecycle 必须保留 .present")
    check(lifecycle.contains("case confirmedEmpty"), "SlotLifecycle 必须保留 .confirmedEmpty")
    check(lifecycle.contains("var needsLoad: Bool { self == .unknown }"),
          "needsLoad 必须恰好等价于 .unknown（旧两句前置短路的合并表达）")
    check(lifecycle.contains("var blocksReload: Bool { self == .present || self == .loading }"),
          "blocksReload 必须是 present || loading")
    check(lifecycle.contains("case loadBegan"), "SlotEvent 必须保留 .loadBegan")
    check(lifecycle.contains("case forgot"), "SlotEvent 必须保留 .forgot")
    check(lifecycle.contains("case evicted"), "SlotEvent 必须保留 .evicted")
    check(lifecycle.contains("case .loadUnavailable:"), "reduce 必须保留 .loadUnavailable 事件臂")
    check(lifecycle.contains("return phase == .unknown ? .loading : phase"),
          "loadBegan 只允许把 .unknown 抬到 .loading")
    check(lifecycle.contains("return phase == .present ? .unknown : phase"),
          "evicted 必须把 .present 打回 .unknown")
    check(lifecycle.contains("return isTerminal(reduce(phase, event: event))"),
          "advancesVersion 必须经终态准入判定")
    check(lifecycle.contains("static func isTerminal(_ phase: SlotLifecycle) -> Bool"),
          "isTerminal 必须是独立可测的纯函数")
    check(lifecycle.contains("enum SlotSettlement: Equatable, Sendable"),
          "必须有独立的桥接枚举 SlotSettlement（相位机不得依赖 ThumbnailLoadPolicy 的类型）")
    check(lifecycle.contains("static func event(for settlement: SlotSettlement) -> SlotEvent"),
          "处置 → 相位事件的映射必须是本文件的纯函数")
    // 纯逻辑：不得 import 任何 UI / 持久化框架。
    check(!lifecycle.contains("import UIKit"), "相位机不得 import UIKit")
    check(!lifecycle.contains("import SwiftUI"), "相位机不得 import SwiftUI")
    check(!lifecycle.contains("import PencilKit"), "相位机不得 import PencilKit")
    check(!lifecycle.contains("import SwiftData"), "相位机不得 import SwiftData")

    guard let store = productionSource("SeeingCalendar/Store/ThumbnailStore.swift") else {
        check(false, "读不到生产文件 ThumbnailStore.swift")
        return
    }
    check(store.contains("private var states: [String: SlotLifecycle] = [:]"),
          "★ ThumbnailStore 必须以 states 相位表作单一真值表")
    check(store.contains("SlotLifecyclePolicy.event(for: settlement(of: disposition))"),
          "settle 必须经相位机的事件映射落地")
    check(store.contains("states[slot.storageKey]?.isConfirmedEmpty ?? false"),
          "isConfirmedEmpty 必须降级为 states 的只读投影")
}

// MARK: - 运行

verifyProductionSourceSync()
verifyDispositionTable()
await verifyClearPageRefreshesCover()
await verifyNewPageDoesNotWipeCover()
await verifyColdStartBulkPrime()
await verifyConfirmedEmptyConverges()
await verifyConcurrentCoalescing()
await verifyNonDestructiveOnUnavailable()
verifyGridLayoutPremise()
await verifyNoStaleResurrectionDuringRegenerate()
verifyStoreIsolation()
verifySlotLifecycleMachine()
verifySlotLifecycleTruthTables()
verifyBrokenSlotVariantIsCaught()
verifySlotLifecycleSourceSync()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 缩略图生命周期：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
