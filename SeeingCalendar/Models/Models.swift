import Foundation
import SwiftData

// MARK: - 维度（画板工作区）

@Model
final class Workspace {
    @Attribute(.unique) var uuid: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DayRecord.workspace)
    var days: [DayRecord] = []

    init(uuid: UUID = UUID(), name: String, sortIndex: Int = 0, createdAt: Date = .now) {
        self.uuid = uuid
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

// MARK: - 单日记录

@Model
final class DayRecord {
    /// 唯一键：`<workspace-uuid>|<yyyy-MM-dd>`
    @Attribute(.unique) var key: String
    var workspaceUUID: UUID
    var dateKey: String
    var note: String
    var updatedAt: Date
    /// 冗余页数：月历一次要渲染 126 个格子，若逐格访问 `pages` 关系会触发大量 SwiftData fault，
    /// 在真机上表现为「点选日期有十分明显的延迟」。这里用整型冗余把 fault 从渲染路径上彻底移除。
    var pageCount: Int = 0
    var workspace: Workspace?

    @Relationship(deleteRule: .cascade, inverse: \DrawingPage.day)
    var pages: [DrawingPage] = []

    init(workspaceUUID: UUID, dateKey: String, note: String = "", updatedAt: Date = .now) {
        self.key = DayRecord.makeKey(workspaceUUID: workspaceUUID, dateKey: dateKey)
        self.workspaceUUID = workspaceUUID
        self.dateKey = dateKey
        self.note = note
        self.updatedAt = updatedAt
    }

    static func makeKey(workspaceUUID: UUID, dateKey: String) -> String {
        "\(workspaceUUID.uuidString)|\(dateKey)"
    }

    var orderedPages: [DrawingPage] {
        pages.sorted { $0.index < $1.index }
    }

    /// 与 `pages.count` 对齐（关系变化后调用）。
    func syncPageCount() {
        pageCount = pages.count
    }

    var coverPage: DrawingPage? {
        orderedPages.first
    }

    var date: Date? {
        CalendarUtils.date(fromKey: dateKey)
    }

    var hasContent: Bool {
        !pages.isEmpty
    }
}

// MARK: - 每日画布分页（Page 1 为月历封面）

@Model
final class DrawingPage {
    @Attribute(.unique) var uuid: UUID
    var index: Int
    var dayKey: String
    var drawingFile: String
    var updatedAt: Date
    var day: DayRecord?

    @Relationship(deleteRule: .cascade, inverse: \ImageRecord.page)
    var images: [ImageRecord] = []

    init(uuid: UUID = UUID(), index: Int, dayKey: String, drawingFile: String) {
        self.uuid = uuid
        self.index = index
        self.dayKey = dayKey
        self.drawingFile = drawingFile
        self.updatedAt = .now
    }

    var drawingURL: URL { AppPaths.drawingURL(drawingFile) }

    var orderedImages: [ImageRecord] {
        images.sorted { $0.zIndex < $1.zIndex }
    }
}

// MARK: - 贴图图元（无损裁剪：只记录显示窗口，原始码流不动）

@Model
final class ImageRecord {
    @Attribute(.unique) var uuid: UUID
    var fileName: String

    // 世界变换矩阵（local(0,0)-(W,H) → 画布坐标），仅含平移 / 旋转 / 等比缩放
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var tx: Double
    var ty: Double

    // 归一化裁剪窗口（0...1，相对原始像素）
    var cropX: Double
    var cropY: Double
    var cropW: Double
    var cropH: Double

    var naturalWidth: Double
    var naturalHeight: Double
    var zIndex: Int
    /// 锁定后不可被选中/移动：用于把已排版好的素材固定为"底板"。
    var isLocked: Bool = false
    /// 可编辑图元元数据（文本/形状配置，nil 表示普通贴图/照片）。
    /// 带默认值 nil → SwiftData 零成本轻量自动迁移，旧记录无感升级。
    var payloadJSON: String? = nil
    var page: DrawingPage?

    init(uuid: UUID = UUID(),
         fileName: String,
         transform: CGAffineTransform,
         cropRect: CGRect,
         naturalSize: CGSize,
         zIndex: Int,
         isLocked: Bool = false,
         payloadJSON: String? = nil) {
        self.uuid = uuid
        self.fileName = fileName
        self.a = transform.a
        self.b = transform.b
        self.c = transform.c
        self.d = transform.d
        self.tx = transform.tx
        self.ty = transform.ty
        self.cropX = cropRect.origin.x
        self.cropY = cropRect.origin.y
        self.cropW = cropRect.size.width
        self.cropH = cropRect.size.height
        self.naturalWidth = naturalSize.width
        self.naturalHeight = naturalSize.height
        self.zIndex = zIndex
        self.isLocked = isLocked
        self.payloadJSON = payloadJSON
    }

    var worldTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    func setTransform(_ transform: CGAffineTransform) {
        a = transform.a
        b = transform.b
        c = transform.c
        d = transform.d
        tx = transform.tx
        ty = transform.ty
    }

    var cropRectOnImage: CGRect {
        CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
    }

    func setCropRect(_ rect: CGRect) {
        cropX = rect.origin.x
        cropY = rect.origin.y
        cropW = rect.size.width
        cropH = rect.size.height
    }

    var naturalSize: CGSize {
        CGSize(width: naturalWidth, height: naturalHeight)
    }

    /// 裁剪后可见区域的原始尺寸（视窗尺度）。
    var visibleSize: CGSize {
        CGSize(width: max(1, naturalWidth * cropW), height: max(1, naturalHeight * cropH))
    }
}

// MARK: - ICS 订阅源（全局 或 绑定单一维度）

@Model
final class ICSSubscription {
    @Attribute(.unique) var uuid: UUID
    var name: String
    var urlString: String
    var colorHex: String
    /// 【旧版单选作用域】`nil` = 全局。**只读兼容字段**：一次性迁移
    /// （`AppDataStack.migrateSubscriptionScopes`）把它搬进 `workspaceUUIDs` 并随即置 nil，
    /// 之后一律写 nil —— 所以「这个字段非空」永远只意味着「还没迁移」。
    var workspaceUUID: UUID?
    /// 作用域：**空数组 = 全局**（所有维度可见）；非空 = 只在列出的维度可见。
    /// 带默认值 → SwiftData 轻量迁移，老库升级无需重建（与 `isBuiltIn` 同一套路）。
    var workspaceUUIDs: [UUID] = []
    var isEnabled: Bool
    var lastFetched: Date?
    var lastError: String?
    var createdAt: Date
    /// 内置 ICS 本地凭据（随包发行、不可删除、URL 形如 `bundled://holidayCal-HO.ics`）。
    /// 带默认值 → SwiftData 轻量迁移，老库升级无需重建。
    var isBuiltIn: Bool = false

    init(uuid: UUID = UUID(),
         name: String,
         urlString: String,
         colorHex: String,
         scope: [UUID] = [],
         isEnabled: Bool = true,
         lastFetched: Date? = nil,
         lastError: String? = nil,
         isBuiltIn: Bool = false) {
        self.uuid = uuid
        self.name = name
        self.urlString = urlString
        self.colorHex = colorHex
        self.workspaceUUID = nil
        self.workspaceUUIDs = scope
        self.isEnabled = isEnabled
        self.lastFetched = lastFetched
        self.lastError = lastError
        self.isBuiltIn = isBuiltIn
        self.createdAt = .now
    }

    /// 绑定的内置来源（用户自建订阅为 nil）。
    var bundledSource: BundledHolidaySource? {
        BundledHolidaySource.source(forURLString: urlString)
    }

    /// 放假类内置订阅。
    var isOffDaySource: Bool { bundledSource == .offDay }
    /// 调休补班类内置订阅。
    var isMakeUpWorkSource: Bool { bundledSource == .makeUpWork }
    /// 假期类订阅不参与日格胶囊绘制（只驱动班休样式与角标），但仍会出现在抽屉里。
    var isHolidaySource: Bool { bundledSource != nil }

    /// 该订阅的日程是否出现在指定维度里。
    ///
    /// 判定规则与事件快照共用 `SubscriptionScope`，不在这里复述一遍：
    /// 两处各写一份的话，总有一边会先改。
    func applies(to workspaceUUID: UUID) -> Bool {
        SubscriptionScope.applies(workspaceUUIDs, to: workspaceUUID)
    }

    /// 作用域的唯一写入入口（全局传空数组）。
    ///
    /// 顺手把旧字段清掉：迁移的幂等性就靠这一点 —— 迁移只处理「旧字段非空」的记录，
    /// 而任何一次新的写入都已经把旧字段腾空了，重复迁移不会把旧值又盖回来。
    func setScope(_ scope: [UUID]) {
        workspaceUUIDs = scope
        workspaceUUID = nil
    }

    /// 维度被删除时把它的 uuid 从作用域里摘掉，返回值表示作用域是否因此发生变化。
    ///
    /// 不摘的后果不是报错，而是**静默消失**：一条只绑在该维度上的订阅从此哪个维度都不命中，
    /// 月历上什么都没有，用户只能靠设置页那行「已删除维度」猜到发生了什么。
    @discardableResult
    func removeFromScope(_ workspaceUUID: UUID) -> Bool {
        guard workspaceUUIDs.contains(workspaceUUID) else { return false }
        setScope(workspaceUUIDs.filter { $0 != workspaceUUID })
        return true
    }

    /// 订阅源的展示顺序：用户自建在上、内置凭据恒定居底。
    ///
    /// 内置凭据是班休数据的唯一来源（删不掉、也换不掉），它属于「基础设施」而不是
    /// 用户自建的同类项。按创建时间混排的话它总在最前，用户新建的订阅反被挤到下面；
    /// 而且只要内置行跟着列表上下移动，用户滑动删除时就永远要重新确认「删的是哪一行」。
    ///
    /// 只在两段内部保持输入顺序（列表的 `@Query` 已按 `createdAt` 排序），
    /// 不做二次排序 —— 顺序是用户看得懂的东西，不该在这里再被改写一次。
    static func displayOrder(_ items: [ICSSubscription]) -> [ICSSubscription] {
        items.filter { !$0.isBuiltIn } + items.filter(\.isBuiltIn)
    }
}
