import Foundation
import SwiftData

/// `.vcal` 解包：完整性校验 + 落盘解压（后台执行，主线程零阻塞）。
enum RestoreService {
    static func extract(archiveAt url: URL) async throws -> RestoreBundle {
        try await Task.detached(priority: .userInitiated) {
            try extractSync(archiveAt: url)
        }.value
    }

    private static func extractSync(archiveAt url: URL) throws -> RestoreBundle {
        let reader = try ZipReader(url: url)
        guard let databaseEntry = reader.entry(named: BackupEntry.database) else {
            throw RestoreError.missingDatabase
        }
        let databaseData = try reader.readData(databaseEntry, limit: 512 << 20)
        let database = try BackupCoding.decoder.decode(BackupDatabase.self, from: databaseData)
        guard !database.workspaces.isEmpty || !database.days.isEmpty else {
            throw RestoreError.emptyBackup
        }

        var manifest: BackupManifest?
        if let entry = reader.entry(named: BackupEntry.manifest) {
            manifest = try? BackupCoding.decoder.decode(BackupManifest.self,
                                                        from: reader.readData(entry, limit: 8 << 20))
        }

        let temp = try AppPaths.makeWorkDirectory()
        var files: [String: URL] = [:]
        for entry in reader.entries where BackupEntry.isPayload(entry.name) {
            let flattened = entry.name.replacingOccurrences(of: "/", with: "_")
            let target = temp.appendingPathComponent(flattened)
            do {
                try reader.extract(entry, to: target)
                files[entry.name] = target
            } catch {
                // 单个资产损坏不应阻断整体恢复，其余数据照常还原。
                continue
            }
        }
        return RestoreBundle(manifest: manifest,
                             database: database,
                             databaseData: databaseData,
                             files: files)
    }
}

/// 冲突消解应用器：完整覆写 / 智能增量合并。
@MainActor
enum RestoreApplier {
    static func apply(bundle: RestoreBundle, mode: RestoreMode, context: ModelContext) -> RestoreSummary {
        var summary = RestoreSummary(mode: mode)
        if mode == .fullOverwrite {
            wipe(context: context)
        }

        // 1. 维度
        var workspaceMap: [UUID: Workspace] = [:]
        for workspace in (try? context.fetch(FetchDescriptor<Workspace>())) ?? [] {
            workspaceMap[workspace.uuid] = workspace
        }
        for dto in bundle.database.workspaces where workspaceMap[dto.uuid] == nil {
            let workspace = Workspace(uuid: dto.uuid, name: dto.name, sortIndex: dto.sortIndex, createdAt: dto.createdAt)
            context.insert(workspace)
            workspaceMap[dto.uuid] = workspace
            summary.workspaces += 1
        }
        if workspaceMap.isEmpty, let first = bundle.database.workspaces.first {
            let workspace = Workspace(uuid: first.uuid, name: first.name, sortIndex: first.sortIndex, createdAt: first.createdAt)
            context.insert(workspace)
            workspaceMap[first.uuid] = workspace
            summary.workspaces += 1
        }

        // 2. 索引化归档内容
        var daysMap: [String: DayRecord] = [:]
        for day in (try? context.fetch(FetchDescriptor<DayRecord>())) ?? [] {
            daysMap[day.key] = day
        }
        var pagesByUUID: [UUID: PageDTO] = [:]
        for page in bundle.database.pages where pagesByUUID[page.uuid] == nil {
            pagesByUUID[page.uuid] = page
        }
        var imagesByUUID: [UUID: ImageDTO] = [:]
        for image in bundle.database.images where imagesByUUID[image.uuid] == nil {
            imagesByUUID[image.uuid] = image
        }

        // 3. 逐日还原
        for dayDTO in bundle.database.days {
            guard let workspace = workspaceMap[dayDTO.workspaceUUID] else { continue }
            let key = DayRecord.makeKey(workspaceUUID: workspace.uuid, dateKey: dayDTO.dateKey)

            let day: DayRecord
            if let existing = daysMap[key] {
                day = existing
                if existing.note.isEmpty, !dayDTO.note.isEmpty {
                    existing.note = dayDTO.note
                }
                existing.updatedAt = .now
            } else {
                let record = DayRecord(workspaceUUID: workspace.uuid,
                                       dateKey: dayDTO.dateKey,
                                       note: dayDTO.note,
                                       updatedAt: dayDTO.updatedAt)
                context.insert(record)
                record.workspace = workspace
                daysMap[key] = record
                day = record
                summary.days += 1
            }

            var nextIndex = (day.pages.map(\.index).max() ?? -1) + 1
            for pageUUID in dayDTO.pageUUIDs {
                guard let pageDTO = pagesByUUID[pageUUID] else { continue }
                let drawingFile = AppPaths.newFileName(extension: "drawing")
                if let source = bundle.files[BackupEntry.drawing(pageDTO.drawingFile)] {
                    try? FileManager.default.copyItem(at: source, to: AppPaths.drawingURL(drawingFile))
                }
                let page = DrawingPage(index: nextIndex, dayKey: day.key, drawingFile: drawingFile)
                context.insert(page)
                page.day = day
                nextIndex += 1
                summary.pages += 1

                for imageUUID in pageDTO.imageUUIDs {
                    guard let imageDTO = imagesByUUID[imageUUID] else { continue }
                    let ext = (imageDTO.fileName as NSString).pathExtension
                    let assetName = AppPaths.newFileName(extension: ext.isEmpty ? "png" : ext)
                    if let source = bundle.files[BackupEntry.asset(imageDTO.fileName)] {
                        try? FileManager.default.copyItem(at: source, to: AppPaths.assetURL(assetName))
                    }
                    let transform = CGAffineTransform(a: imageDTO.a, b: imageDTO.b,
                                                      c: imageDTO.c, d: imageDTO.d,
                                                      tx: imageDTO.tx, ty: imageDTO.ty)
                    let crop = CGRect(x: imageDTO.cropX, y: imageDTO.cropY,
                                      width: imageDTO.cropW, height: imageDTO.cropH)
                    let size = CGSize(width: imageDTO.naturalWidth, height: imageDTO.naturalHeight)
                    let record = ImageRecord(uuid: UUID(),
                                             fileName: assetName,
                                             transform: transform,
                                             cropRect: crop,
                                             naturalSize: size,
                                             zIndex: imageDTO.zIndex)
                    context.insert(record)
                    record.page = page
                    summary.images += 1
                }
            }
        }

        // 4. 订阅源
        var knownSubscriptions = Set(((try? context.fetch(FetchDescriptor<ICSSubscription>())) ?? []).map(\.uuid))
        for dto in bundle.database.subscriptions where !knownSubscriptions.contains(dto.uuid) {
            // 作用域：新备份读 `workspaceUUIDs`（空数组就是全局，不能被当成「没写」而回退），
            // 旧备份没有这个键，才回退到旧版单选字段。
            let scope = dto.workspaceUUIDs ?? dto.workspaceUUID.map { [$0] } ?? []
            let subscription = ICSSubscription(uuid: dto.uuid,
                                               name: dto.name,
                                               urlString: dto.urlString,
                                               colorHex: dto.colorHex,
                                               scope: scope,
                                               isEnabled: dto.isEnabled)
            context.insert(subscription)
            knownSubscriptions.insert(dto.uuid)
            summary.subscriptions += 1
        }

        try? context.save()
        ThumbnailStore.shared.invalidateAll()
        return summary
    }

    private static func wipe(context: ModelContext) {
        try? context.delete(model: ImageRecord.self)
        try? context.delete(model: DrawingPage.self)
        try? context.delete(model: DayRecord.self)
        try? context.delete(model: Workspace.self)
        try? context.delete(model: ICSSubscription.self)
        try? context.save()

        for directory in [AppPaths.drawings, AppPaths.assets, AppPaths.thumbnails] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
