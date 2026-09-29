import CryptoKit
import Foundation
import Observation
import SwiftData
import UIKit

// MARK: - 打包 actor（后台流式写盘，内存驻留恒定）

actor BackupService {
    static let shared = BackupService()

    struct Output: Sendable {
        var url: URL
        var manifest: BackupManifest
        var byteCount: Int
    }

    func writeArchive(request: BackupRequest, progress: @Sendable (Double) -> Void) throws -> Output {
        let databaseData = try BackupCoding.encoder.encode(request.database)
        let digest = SHA256.hash(data: databaseData).map { String(format: "%02x", $0) }.joined()

        let manifest = BackupManifest(schemaVersion: 1,
                                      appVersion: request.appVersion,
                                      exportDate: request.exportDate,
                                      deviceModel: request.deviceModel,
                                      systemVersion: request.systemVersion,
                                      workspaceCount: request.database.workspaces.count,
                                      dayCount: request.database.days.count,
                                      pageCount: request.database.pages.count,
                                      imageCount: request.database.images.count,
                                      databaseDigest: digest)
        let manifestData = try BackupCoding.encoder.encode(manifest)

        var items: [ZipWriter.Item] = [
            ZipWriter.Item(name: BackupEntry.manifest, source: .data(manifestData)),
            ZipWriter.Item(name: BackupEntry.database, source: .data(databaseData))
        ]
        for (name, url) in request.drawingFiles.sorted(by: { $0.key < $1.key }) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(ZipWriter.Item(name: name, source: .file(url)))
        }
        for (name, url) in request.assetFiles.sorted(by: { $0.key < $1.key }) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(ZipWriter.Item(name: name, source: .file(url)))
        }

        progress(0.15)
        let destination = AppPaths.work.appendingPathComponent(request.fileName)
        try ZipWriter.write(items: items, to: destination)
        progress(1.0)

        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
        return Output(url: destination, manifest: manifest, byteCount: size)
    }
}

// MARK: - 主线程协调器（快照 / 导出 / 恢复）

@MainActor
@Observable
final class BackupCoordinator {
    private(set) var isWorking = false
    private(set) var progress: Double = 0
    private(set) var statusText = ""
    private(set) var lastError: String?
    private(set) var lastSummary: RestoreSummary?
    private(set) var pendingRestore: RestoreBundle?

    private let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"

    // MARK: - 导出

    func exportArchive(context: ModelContext, reason: SnapshotReason = .manual) async -> URL? {
        guard !isWorking else { return nil }
        isWorking = true
        progress = 0
        statusText = "正在整理数据…"
        lastError = nil
        defer { isWorking = false }

        let request = makeRequest(context: context, reason: reason)
        if request.database.pages.isEmpty && request.database.days.isEmpty && reason == .manual {
            lastError = "当前没有任何画作内容，无需备份。"
            return nil
        }

        statusText = "正在打包 .vcal 归档…"
        do {
            let output = try await BackupService.shared.writeArchive(request: request) { value in
                Task { @MainActor in
                    self.progress = value
                }
            }
            progress = 1
            statusText = "备份完成（\(formattedSize(output.byteCount))）"
            return output.url
        } catch {
            lastError = error.localizedDescription
            statusText = "备份失败"
            return nil
        }
    }

    func makeRequest(context: ModelContext, reason: SnapshotReason) -> BackupRequest {
        let workspaces = (try? context.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let days = (try? context.fetch(FetchDescriptor<DayRecord>())) ?? []
        let subscriptions = (try? context.fetch(FetchDescriptor<ICSSubscription>())) ?? []

        var database = BackupDatabase()
        database.workspaces = workspaces.map {
            WorkspaceDTO(uuid: $0.uuid, name: $0.name, sortIndex: $0.sortIndex, createdAt: $0.createdAt)
        }
        database.subscriptions = subscriptions.map {
            SubscriptionDTO(uuid: $0.uuid,
                            name: $0.name,
                            urlString: $0.urlString,
                            colorHex: $0.colorHex,
                            workspaceUUID: $0.workspaceUUID,
                            isEnabled: $0.isEnabled)
        }

        var drawingFiles: [String: URL] = [:]
        var assetFiles: [String: URL] = [:]

        var dayDTOs: [DayDTO] = []
        for day in days {
            guard let workspaceUUID = day.workspace?.uuid ?? workspaces.first(where: { $0.uuid == day.workspaceUUID })?.uuid else { continue }
            let dayPages = day.pages.sorted { $0.index < $1.index }
            var pageUUIDs: [UUID] = []
            for page in dayPages {
                pageUUIDs.append(page.uuid)
                drawingFiles[BackupEntry.drawing(page.drawingFile)] = page.drawingURL
                var imageUUIDs: [UUID] = []
                for record in page.orderedImages {
                    imageUUIDs.append(record.uuid)
                    let url = AppPaths.assetURL(record.fileName)
                    if FileManager.default.fileExists(atPath: url.path) {
                        assetFiles[BackupEntry.asset(record.fileName)] = url
                    }
                    database.images.append(ImageDTO(uuid: record.uuid,
                                                    fileName: record.fileName,
                                                    a: record.a, b: record.b, c: record.c, d: record.d,
                                                    tx: record.tx, ty: record.ty,
                                                    cropX: record.cropX, cropY: record.cropY,
                                                    cropW: record.cropW, cropH: record.cropH,
                                                    naturalWidth: record.naturalWidth,
                                                    naturalHeight: record.naturalHeight,
                                                    zIndex: record.zIndex))
                }
                database.pages.append(PageDTO(uuid: page.uuid,
                                              index: page.index,
                                              drawingFile: page.drawingFile,
                                              updatedAt: page.updatedAt,
                                              imageUUIDs: imageUUIDs))
            }
            dayDTOs.append(DayDTO(workspaceUUID: workspaceUUID,
                                  dateKey: day.dateKey,
                                  note: day.note,
                                  updatedAt: day.updatedAt,
                                  pageUUIDs: pageUUIDs))
        }
        database.days = dayDTOs

        let stamp = BackupCoordinator.fileStamp(Date())
        let name = reason == .manual
            ? "VisualCalendar_Backup_\(stamp).vcal"
            : "AutoSnapshot_\(stamp).vcal"

        let device = UIDevice.current
        return BackupRequest(database: database,
                             appVersion: appVersion,
                             deviceModel: device.model,
                             systemVersion: "\(device.systemName) \(device.systemVersion)",
                             exportDate: Date(),
                             fileName: name,
                             drawingFiles: drawingFiles,
                             assetFiles: assetFiles)
    }

    /// 自动本地快照：只保留最近 3 个版本。
    func performAutoSnapshot(context: ModelContext) async {
        guard let url = await exportArchive(context: context, reason: .auto) else { return }
        let destination = AppPaths.snapshots.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: url, to: destination)
        pruneSnapshots(keeping: 3)
    }

    private func pruneSnapshots(keeping limit: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: AppPaths.snapshots,
                                                                   includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "vcal" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left > right
            }
        for file in files.dropFirst(limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 恢复

    func prepareRestore(at url: URL) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        statusText = "正在校验归档…"
        lastError = nil
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let localCopy = AppPaths.work.appendingPathComponent("import-\(UUID().uuidString).vcal")
        try? FileManager.default.removeItem(at: localCopy)
        do {
            try FileManager.default.copyItem(at: url, to: localCopy)
        } catch {
            lastError = "无法读取所选文件：\(error.localizedDescription)"
            return false
        }

        do {
            let bundle = try await RestoreService.extract(archiveAt: localCopy)
            if let manifest = bundle.manifest, manifest.databaseDigest.isEmpty == false {
                let digest = SHA256.hash(data: bundle.databaseData).map { String(format: "%02x", $0) }.joined()
                if digest != manifest.databaseDigest {
                    // 指纹不一致仍允许导入，但必须明确告警，不静默丢弃用户资产。
                    lastError = "归档指纹与清单不一致，内容可能被外部修改过。"
                }
            }
            pendingRestore = bundle
            statusText = "归档校验通过"
            return true
        } catch {
            lastError = error.localizedDescription
            statusText = "归档解析失败"
            return false
        }
    }

    func applyPendingRestore(mode: RestoreMode, context: ModelContext) -> RestoreSummary? {
        guard let bundle = pendingRestore else { return nil }
        let summary = RestoreApplier.apply(bundle: bundle, mode: mode, context: context)
        pendingRestore = nil
        lastSummary = summary
        statusText = summary.message
        return summary
    }

    func clearPendingRestore() {
        pendingRestore = nil
    }

    // MARK: - 工具

    private func formattedSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func fileStamp(_ date: Date) -> String {
        let parts = CalendarUtils.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d%02d%02d_%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0)
    }
}

enum SnapshotReason: Sendable {
    case manual
    case auto
}
