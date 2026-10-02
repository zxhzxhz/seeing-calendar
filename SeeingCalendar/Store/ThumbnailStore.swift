import Foundation
import Observation
import PencilKit
import UIKit

/// 缩略图槽位：全应用统一的缓存键。
///
/// 为什么需要两种槽位（而不是统一按缩略图文件名）：
/// 月历的 `cell(for:)` 跑在 **126 格的渲染路径**上，那里只能读「存储属性」，
/// 一旦为了拿文件名去碰 `DayRecord.coverPage`（内部是 `pages.sorted`），
/// 每一帧都会触发上百次 SwiftData fault —— 正是 `DayRecord.pageCount` 这个冗余字段
/// 存在的理由。`DayRecord.key` 与 `DrawingPage.uuid` 都是存储属性，零成本。
///
/// 而封面与「同一天的其它页」必须分开命名空间：一天可以有多页，
/// 抽屉里要同时显示封面页和拓展页的缩略图，它们不能互相顶掉。
enum ThumbnailSlot: Hashable, Sendable {
    /// 月历封面：一天一张，键取 `DayRecord.key`（已含维度 UUID，跨维度不串图）。
    case cover(dayKey: String)
    /// 编辑器抽屉里的单页预览：键取 `DrawingPage.uuid`。
    case page(uuid: UUID)

    var storageKey: String {
        switch self {
        case .cover(let dayKey): return "cover|\(dayKey)"
        case .page(let uuid):    return "page|\(uuid.uuidString)"
        }
    }
}

/// 一次请求的对外结论。
enum ThumbnailOutcome: Equatable, Sendable {
    /// 缓存里已经有图，或本次成功生成。
    case image
    /// **权威结论：这一页确实没有可渲染内容**（无笔迹且无贴图）。
    case empty
    /// 暂时拿不到（笔迹文件还没落盘 / 合成失败）。调用方必须保持原样。
    case unavailable
}

/// 多级缩略图缓存：内存表 → 磁盘 PNG → 缺失时离线重建。
///
/// ## 1.0.20 的结构性修正：真值归位到 store
///
/// 旧实现把装载结果存进 `MonthGridView` 自己的 `@State`，只有 `loadThumbnails()`
/// 一趟跑完、`flush()` 提交，格子才看得到图。这带来一个无法自愈的失败模式：
/// 视图的 `.task(id:)` 会被父层指纹的任何变化取消并重启，而「取消」与「结果丢失」
/// 是同一件事 —— 装载结果依赖调度运气，表现为**冷启动空白、点一下才出现**。
///
/// 现在图像表就住在这里（`images`，`@Observable`），视图只**读**不**存**：
/// - 取消装载任务不会丢掉任何已经拿到的图（它们在单例里，不在任务栈上）；
/// - 任何一处写入都自动让所有读取方重绘，不需要父层把代次「传进去」才能看见；
/// - 「这一页被清空了」也在这里表达（条目被移除），视图不必自己维护一张
///   「哪一格该消失」的辅助表。
@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// 槽位 → 图像。**全应用唯一的缩略图真值来源。**
    private(set) var images: [String: UIImage] = [:]

    /// 内容代次，用于驱动 SwiftUI 刷新。
    ///
    /// 只要**拿到了明确结论**（合成出图 / 权威确认为空）就推进，不论来自装载路径
    /// 还是编辑路径。不推进的后果不是「少刷一次」：新合成的图跨不过月历的等值短路，
    /// 会一直停在旧画面上 —— 冷启动空白就是这个形状。
    /// 只有「读不到 / 合成失败」这类**无结论**的情形不推进（见 `ThumbnailLoadPolicy`）。
    ///
    /// 不推进也不会死循环：`images[key] != nil` 与 `emptySlots.contains(key)`
    /// 两个前置短路保证下一轮不再产生写入。
    private(set) var version: Int = 0

    /// 已**权威确认无内容**的槽位（笔迹与贴图都实读为空的结论）。
    ///
    /// 没有这张表会陷入死循环：清空一页之后，页对象还在（`coverPage != nil`），
    /// 每轮装载都会把它当「缺图」重新合成一次，每次得到 `.empty` 就又写一次缓存 ——
    /// 视图重启、再合成、再重启，永不收敛。内容变更时（`regenerate`）这个标记会被撤掉。
    private var emptySlots: Set<String> = []

    /// 同页在途生成合并表：后来者 await 同一个 Task，绝不各自重算。
    ///
    /// 月历同时常驻三个月，同一个日期会落在两个月的网格里（10 月网格第 1 行含 9/30，
    /// 9 月网格里当然也有 9/30），两格会几乎同时请求同一页。
    /// 旧实现里「见到同名文件正在生成就直接 return」，谁抢输谁那格就是空的。
    private var inFlight: [String: Task<ThumbnailOutcome, Never>] = [:]

    /// 插入序，用于软上限淘汰（缩略图只是派生缓存，淘汰后按需重建即可）。
    ///
    /// `memoryLimit` 必须大于「任何一屏可能同时需要的槽位数」：月历常驻三个月
    /// （3 × 42 = 126 格）+ 抽屉预览若干。取得过小会引爆一个振荡：被淘汰的格子
    /// 下一轮装载又会从磁盘重新补进来、再挤掉别的格子 —— 若淘汰也推进代次，
    /// 这个循环每轮都会让根视图重算一次，直接变成满负载空转。所以这里的取值
    /// 远离实际需求（512），而淘汰路径**不推进代次**。
    private var insertionOrder: [String] = []
    private let memoryLimit = 512

    private init() {}

    // MARK: - 读

    /// 渲染路径唯一的读入口：纯字典查找，不碰 SwiftData、不做 IO、无副作用。
    func image(_ slot: ThumbnailSlot) -> UIImage? {
        images[slot.storageKey]
    }

    /// 这个槽位是否已被权威判定为「无内容」。
    func isConfirmedEmpty(_ slot: ThumbnailSlot) -> Bool {
        emptySlots.contains(slot.storageKey)
    }

    // MARK: - 装载

    /// 磁盘批量补齐（**同步**，最多推进一次代次）。
    ///
    /// 冷启动时月历上往往有几十格都有既存 PNG；逐格提交会让代次跳几十下、
    /// 根视图白重算几十轮。返回磁盘上没有图、需要后台合成的槽位。
    ///
    /// 同步读盘是可接受的：缩略图只有 10–30 KB，且几乎总在页缓存里，
    /// 42 格一轮在毫秒级 —— 换来的是完全没有并发脆弱性。
    @discardableResult
    func primeFromDisk(_ entries: [(slot: ThumbnailSlot, page: DrawingPage)])
        -> [(slot: ThumbnailSlot, page: DrawingPage)] {
        var misses: [(slot: ThumbnailSlot, page: DrawingPage)] = []
        var changed = false
        for entry in entries {
            let key = entry.slot.storageKey
            if images[key] != nil { continue }
            if emptySlots.contains(key) { continue }
            let url = AppPaths.thumbnailURL(entry.page.thumbnailFileName)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                commit(image, forKey: key)
                changed = true
            } else {
                misses.append(entry)
            }
        }
        if changed { version &+= 1 }
        return misses
    }

    /// 装载某槽位的缩略图。**幂等、可重入，结果落在 store 而不是调用方手里。**
    ///
    /// 推进代次是安全的：`images[key] != nil` 与 `emptySlots.contains(key)` 两个前置
    /// 短路保证下一轮不会重复写入，因此不会形成「重启 → 再写 → 再重启」的死循环。
    @discardableResult
    func load(_ slot: ThumbnailSlot, page: DrawingPage?) async -> ThumbnailOutcome {
        let key = slot.storageKey
        if images[key] != nil { return .image }
        if emptySlots.contains(key) { return .empty }
        guard let page else { return .unavailable }

        let name = page.thumbnailFileName
        if let data = try? Data(contentsOf: AppPaths.thumbnailURL(name)),
           let image = UIImage(data: data) {
            commit(image, forKey: key)
            version &+= 1
            return .image
        }

        if let existing = inFlight[name] { return await existing.value }
        let task = Task<ThumbnailOutcome, Never> { [weak self] in
            guard let self else { return .unavailable }
            return await self.produce(slot: slot, name: name, page: page)
        }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        return await task.value
    }

    // MARK: - 内容变更

    /// 内容变更后重算并落盘（编辑器路径调用）。
    ///
    /// **清空页也走这里**：`ThumbnailLoadPolicy` 会把「确认为空」判成 `.clear`，
    /// 于是磁盘 PNG 被删除、内存条目被收走、代次推进 ——
    /// 这正是「清空后主页仍显示清空前缩略图」的直接修法。
    ///
    /// 注意这里**不**先撤掉 `emptySlots` 标记。撤了会开一个窗口：合成是 `await` 的，
    /// 挂起期间月历很可能被重启并跑一轮 `primeFromDisk`，把磁盘上那张陈旧的 PNG
    /// 又复活进来（代次推进已经发生过）。标记改由 `commit` 在同一帧里撤，
    /// 写缓存与撤标记不可分割。
    @discardableResult
    func regenerate(_ slot: ThumbnailSlot, page: DrawingPage) async -> ThumbnailOutcome {
        settle(await render(page: page), slot: slot, name: page.thumbnailFileName)
    }

    /// 丢弃一个槽位：**调用方已确知内容消失**（用户清空当前页 / 页被删除）。
    ///
    /// 这是「乐观收图」：清空是个不需要离线合成就能下结论的事实，
    /// 因此立刻把旧图从内存与月历上收走（并打上无内容标记，防止磁盘上那张
    /// 陈旧 PNG 被下一轮 `primeFromDisk` 复活），随后 `save()` 的 `regenerate`
    /// 会得到同样的 `.empty` 结论 —— 幂等，不冲突。
    ///
    /// 磁盘 PNG 也当场删掉：它是一个**已知陈旧**的产物，留着只会给复活留门。
    func forget(_ slot: ThumbnailSlot, fileName: String) {
        try? FileManager.default.removeItem(at: AppPaths.thumbnailURL(fileName))
        remove(slot.storageKey)
        emptySlots.insert(slot.storageKey)
        // 必须推进代次：月历那层是 EquatableView，父层指纹不变就不会重算，
        // 光靠 `@Observable` 失效不可靠。
        version &+= 1
    }

    /// 全量失效（导入恢复后调用，缩略图会按需重建）。
    func invalidateAll() {
        images.removeAll()
        insertionOrder.removeAll()
        emptySlots.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.thumbnails,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        version &+= 1
    }

    // MARK: - 内部

    /// 后台合成（并把成功结果落盘）。
    private func render(page: DrawingPage) async -> ThumbnailRenderResult {
        let specs: [ThumbnailImageSpec] = page.orderedImages.map { record in
            ThumbnailImageSpec(url: AppPaths.assetURL(record.fileName),
                               worldTransform: record.worldTransform,
                               cropRect: record.cropRectOnImage,
                               naturalSize: record.naturalSize)
        }
        let drawingURL = page.drawingURL
        let url = AppPaths.thumbnailURL(page.thumbnailFileName)

        let result = await Task.detached(priority: .utility) {
            ThumbnailRenderer.renderPNG(drawingFile: drawingURL, images: specs)
        }.value

        if case .png(let png) = result {
            try? png.write(to: url, options: .atomic)
        }
        return result
    }

    /// 装载路径的合成：结果同样经 `settle` 落地（结论明确就推进代次）。
    private func produce(slot: ThumbnailSlot, name: String, page: DrawingPage) async -> ThumbnailOutcome {
        settle(await render(page: page), slot: slot, name: name)
    }

    /// 唯一的落地决策点。装载路径与内容变更路径**共用**它，
    /// 判定规则全部委托给 `ThumbnailLoadPolicy`（纯逻辑，CI 门禁对它有直接覆盖）。
    ///
    /// 关键：拿到明确结论（有图 / 确认为空）就必须推进代次。
    /// 不推进的话，刚合成出来的图跨不过 `MonthPager` 的 `EquatableView` 短路，
    /// 格子会一直停在空图上 —— 那正是冷启动空白 bug 的形状。
    /// 而推进不会形成死循环：下一轮 `load` 会被 `images[key] != nil` /
    /// `emptySlots.contains(key)` 直接短路，不再产生写入。
    private func settle(_ result: ThumbnailRenderResult,
                        slot: ThumbnailSlot,
                        name: String) -> ThumbnailOutcome {
        let disposition = ThumbnailLoadPolicy.disposition(for: result)
        let key = slot.storageKey

        switch disposition {
        case .commit:
            guard case .png(let data) = result, let image = UIImage(data: data) else {
                return .unavailable
            }
            // `commit` 内部撤掉 `emptySlots` 标记：写缓存与撤标记必须在同一帧内完成。
            commit(image, forKey: key)
        case .clear:
            try? FileManager.default.removeItem(at: AppPaths.thumbnailURL(name))
            remove(key)
            emptySlots.insert(key)
        case .preserve:
            // 笔迹文件读不到 / 合成失败 → 不下结论，保留已有图（非破坏），也不推进代次。
            return .unavailable
        }

        if ThumbnailLoadPolicy.advancesVersion(disposition) { version &+= 1 }
        return disposition == .clear ? .empty : .image
    }

    private func commit(_ image: UIImage, forKey key: String) {
        emptySlots.remove(key)
        if images[key] == nil { insertionOrder.append(key) }
        images[key] = image
        // 淘汰**刻意不推进代次**（下面还有一段说明，改前请先读完）。
        while insertionOrder.count > memoryLimit, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    private func remove(_ key: String) {
        guard images.removeValue(forKey: key) != nil else { return }
        insertionOrder.removeAll { $0 == key }
    }
}

extension DrawingPage {
    var thumbnailFileName: String {
        let base = drawingFile.hasSuffix(".drawing")
            ? String(drawingFile.dropLast(".drawing".count))
            : drawingFile
        return base + ".png"
    }

    /// 本页封面槽位（月历用）：`dayKey` 由 `PageRepository.addPage` 写成 `DayRecord.key`。
    var coverSlot: ThumbnailSlot { .cover(dayKey: dayKey) }
    /// 本页单页槽位（编辑器抽屉用）。
    var pageSlot: ThumbnailSlot { .page(uuid: uuid) }
}

extension DayRecord {
    /// 这一天的封面槽位。`key` 是存储属性，渲染路径上读它不触发关系 fault。
    var coverSlot: ThumbnailSlot { .cover(dayKey: key) }
}
