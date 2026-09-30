import Foundation
import PencilKit
import SwiftData
import UIKit

/// 元数据（SwiftData）与二进制资产（文件系统）之间的唯一读写通道。
@MainActor
struct PageRepository {
    let context: ModelContext

    // MARK: - 维度

    func workspaceList() -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.sortIndex)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func ensureDefaultWorkspace() -> Workspace {
        let existing = workspaceList()
        if let first = existing.first { return first }
        let workspace = Workspace(name: "个人创作", sortIndex: 0)
        context.insert(workspace)
        try? context.save()
        return workspace
    }

    func createWorkspace(named name: String) -> Workspace {
        let next = (workspaceList().map(\.sortIndex).max() ?? -1) + 1
        let workspace = Workspace(name: name, sortIndex: next)
        context.insert(workspace)
        try? context.save()
        return workspace
    }

    /// 删除维度并级联清理磁盘资产；返回值表示是否还有其它维度存活。
    func deleteWorkspace(_ workspace: Workspace) -> Bool {
        let orphanPages = workspace.days.flatMap { $0.pages }
        for page in orphanPages {
            removeFiles(for: page)
        }
        context.delete(workspace)
        try? context.save()
        cleanupOrphanAssets()
        return !workspaceList().isEmpty
    }

    // MARK: - 单日

    func day(for date: Date, workspace: Workspace, create: Bool) -> DayRecord? {
        let dateKey = CalendarUtils.key(for: date)
        return day(forKey: dateKey, workspace: workspace, create: create)
    }

    func day(forKey dateKey: String, workspace: Workspace, create: Bool) -> DayRecord? {
        let key = DayRecord.makeKey(workspaceUUID: workspace.uuid, dateKey: dateKey)
        let descriptor = FetchDescriptor<DayRecord>(predicate: #Predicate { $0.key == key })
        let found = (try? context.fetch(descriptor)) ?? []
        if let record = found.first { return record }
        guard create else { return nil }
        let record = DayRecord(workspaceUUID: workspace.uuid, dateKey: dateKey)
        context.insert(record)
        record.workspace = workspace
        try? context.save()
        return record
    }

    func updateNote(_ note: String, for day: DayRecord) {
        guard day.note != note else { return }
        day.note = note
        day.updatedAt = .now
        try? context.save()
    }

    // MARK: - 分页

    /// 保证 Page 1 存在（月历封面永远取 Page 1）。
    @discardableResult
    func ensureCoverPage(for day: DayRecord) -> DrawingPage {
        if let cover = day.coverPage { return cover }
        return addPage(to: day)
    }

    @discardableResult
    func addPage(to day: DayRecord) -> DrawingPage {
        let index = (day.pages.map(\.index).max() ?? -1) + 1
        let page = DrawingPage(index: index, dayKey: day.key, drawingFile: AppPaths.newFileName(extension: "drawing"))
        context.insert(page)
        page.day = day
        day.updatedAt = .now
        day.syncPageCount()
        try? context.save()
        return page
    }

    /// 按给定顺序重排页面：index 即位置，Page 1 自动成为月历封面。
    func applyPageOrder(_ ordered: [DrawingPage], in day: DayRecord) {
        for (position, page) in ordered.enumerated() where page.index != position {
            page.index = position
        }
        day.syncPageCount()
        day.updatedAt = .now
        try? context.save()
    }

    /// 一次性回填历史数据的 pageCount（旧库升级到本版本时执行一次）。
    func backfillPageCountsIfNeeded() {
        let key = "didBackfillPageCounts_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let descriptor = FetchDescriptor<DayRecord>()
        let days = (try? context.fetch(descriptor)) ?? []
        for day in days {
            let actual = day.pages.count
            if day.pageCount != actual {
                day.pageCount = actual
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - 内置 ICS 本地凭据

    /// 幂等播种两条内置节假日订阅（放假 / 调休），默认开启、不可删除。
    /// 用固定 UUID 做身份锚：老库里即便被误删，下次启动也会重新长出来。
    @discardableResult
    func ensureBuiltInSubscriptions() -> Bool {
        let existing = (try? context.fetch(FetchDescriptor<ICSSubscription>())) ?? []
        var byUUID: [UUID: ICSSubscription] = [:]
        for item in existing { byUUID[item.uuid] = item }

        var changed = false
        for source in BundledHolidaySource.allCases {
            if let record = byUUID[source.stableUUID] {
                // 兼容旧记录：补上 isBuiltIn 与最新展示名。
                if !record.isBuiltIn { record.isBuiltIn = true; changed = true }
                if record.name != source.subscriptionName { record.name = source.subscriptionName; changed = true }
                continue
            }
            let record = ICSSubscription(uuid: source.stableUUID,
                                         name: source.subscriptionName,
                                         urlString: source.urlString,
                                         colorHex: source.colorHex,
                                         isEnabled: true,
                                         isBuiltIn: true)
            context.insert(record)
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    func deletePage(_ page: DrawingPage) {
        let day = page.day
        removeFiles(for: page)
        context.delete(page)
        try? context.save()
        if let day {
            reindex(day)
        }
    }

    /// 删除页面后重排索引（Page 1 语义必须保持连续）。
    func reindex(_ day: DayRecord) {
        let ordered = day.pages.sorted { $0.index < $1.index }
        for (index, page) in ordered.enumerated() where page.index != index {
            page.index = index
        }
        day.syncPageCount()
        try? context.save()
    }

    // MARK: - 笔迹

    func loadDrawing(for page: DrawingPage) -> PKDrawing {
        guard let data = try? Data(contentsOf: page.drawingURL), !data.isEmpty else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    func writeDrawing(_ drawing: PKDrawing, for page: DrawingPage) {
        let data = drawing.dataRepresentation()
        do {
            try data.write(to: page.drawingURL, options: .atomic)
        } catch {
            // 磁盘写入失败不应中断编辑流程，下一轮自动保存会重试。
        }
        page.updatedAt = .now
    }

    // MARK: - 贴图

    func loadImageItems(for page: DrawingPage) -> [CanvasImageItem] {
        let records = page.orderedImages
        var items: [CanvasImageItem] = []
        items.reserveCapacity(records.count)
        for record in records {
            let url = AppPaths.assetURL(record.fileName)
            guard let image = UIImage(contentsOfFile: url.path) else { continue }
            items.append(CanvasImageItem(id: record.uuid,
                                         fileName: record.fileName,
                                         image: image,
                                         worldTransform: record.worldTransform,
                                         cropRect: record.cropRectOnImage,
                                         naturalSize: record.naturalSize,
                                         zIndex: record.zIndex,
                                         isLocked: record.isLocked))
        }
        return items
    }

    /// 全量对账：新增 / 更新 / 删除，保证数据库与画布一致。
    /// `zIndex` 直接沿用画布给出的全局序号（含「笔迹之上」的前置层区间）。
    func saveImageItems(_ items: [CanvasImageItem], for page: DrawingPage) {
        var existing: [UUID: ImageRecord] = [:]
        for record in page.images { existing[record.uuid] = record }

        for item in items.sorted(by: { $0.zIndex < $1.zIndex }) {
            if let record = existing.removeValue(forKey: item.id) {
                record.fileName = item.fileName
                record.setTransform(item.worldTransform)
                record.setCropRect(item.cropRect)
                record.naturalWidth = Double(item.naturalSize.width)
                record.naturalHeight = Double(item.naturalSize.height)
                record.zIndex = item.zIndex
                record.isLocked = item.isLocked
            } else {
                let record = ImageRecord(uuid: item.id,
                                         fileName: item.fileName,
                                         transform: item.worldTransform,
                                         cropRect: item.cropRect,
                                         naturalSize: item.naturalSize,
                                         zIndex: item.zIndex,
                                         isLocked: item.isLocked)
                context.insert(record)
                record.page = page
            }
        }

        for orphan in existing.values {
            context.delete(orphan)
        }
        page.updatedAt = .now
        try? context.save()
    }

    /// 导入贴图：原始码流原样落盘（不做二次转码，保留 EXIF 与画质）。
    func storeAsset(data: Data, preferredExtension ext: String) -> String {
        let fileName = AppPaths.newFileName(extension: ext)
        let url = AppPaths.assetURL(fileName)
        try? data.write(to: url, options: .atomic)
        return fileName
    }

    func copyAsset(from source: URL, preferredExtension ext: String) -> String {
        let fileName = AppPaths.newFileName(extension: ext)
        let url = AppPaths.assetURL(fileName)
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            return ""
        }
        return fileName
    }

    // MARK: - 清理

    func removeFiles(for page: DrawingPage) {
        try? FileManager.default.removeItem(at: page.drawingURL)
        try? FileManager.default.removeItem(at: AppPaths.thumbnailURL(page.thumbnailFileName))
        for record in page.images {
            try? FileManager.default.removeItem(at: AppPaths.assetURL(record.fileName))
        }
        ThumbnailStore.shared.invalidate(page.thumbnailFileName)
    }

    /// 物理级对账：删除不再被任何记录引用的贴图文件。
    func cleanupOrphanAssets() {
        let descriptor = FetchDescriptor<ImageRecord>()
        let records = (try? context.fetch(descriptor)) ?? []
        var referenced = Set(records.map(\.fileName))
        let thumbDescriptor = FetchDescriptor<DrawingPage>()
        for page in (try? context.fetch(thumbDescriptor)) ?? [] {
            referenced.insert(page.drawingFile)
        }

        let manager = FileManager.default
        for directory in [AppPaths.assets, AppPaths.drawings] {
            let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where !referenced.contains(file) {
                try? manager.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
}
