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
    /// 备份 / 恢复生命周期的**唯一真值**。
    ///
    /// 旧的 5 个存储字段（`isWorking` / `progress` / `statusText` / `lastError` /
    /// `lastSummary` / `pendingRestore`）全部降级为它的只读投影，
    /// 于是「同一事实有多个持有者」从根上不可表达（见 `BackupPhasePolicy.swift` 的说明）。
    private(set) var phase: BackupPhase = .idle

    // MARK: - 只读投影（签名与类型和旧存储字段完全一致，既有调用点零改动）

    /// 是否忙碌。严格等价于旧的 `isWorking`（只有导出 / 校验 / 恢复为真）。
    var isWorking: Bool { phase.isWorking }
    /// 进度 0…1；非进度相位恒为 0（消除旧实现的进度残值）。
    var progress: Double { phase.progress }
    /// 状态文案。
    var statusText: String { phase.statusText }
    /// 失败信息（含完整性告警）。与 `lastSummary` 互斥 —— 不会同时非 nil。
    var lastError: String? { phase.failureMessage ?? phase.warningMessage }
    /// 成功摘要（只有 `.finished` 才非空）。
    var lastSummary: RestoreSummary? { phase.summary }
    /// 待恢复内容（唯一真值来自 `phase`）。
    var pendingRestore: RestoreBundle? { phase.pendingRestore }
    /// 是否正在等待用户选择恢复策略（`RootView` 的弹窗唯一读它）。
    var isAwaitingStrategy: Bool { phase.isAwaitingStrategy }

    private let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"

    /// **唯一的相位写入点** —— 所有状态变化都必须经过 `BackupPolicy.reduce`。
    private func emit(_ event: BackupEvent) {
        phase = BackupPolicy.reduce(phase, event: event)
    }

    // MARK: - 导出

    func exportArchive(context: ModelContext, reason: SnapshotReason = .manual) async -> URL? {
        guard BackupPolicy.acceptsNewRequest(phase) else { return nil }
        emit(.exportBegan)

        let request = makeRequest(context: context, reason: reason)
        if request.database.pages.isEmpty && request.database.days.isEmpty && reason == .manual {
            emit(.failed(message: "当前没有任何画作内容，无需备份。"))
            return nil
        }

        do {
            let output = try await BackupService.shared.writeArchive(request: request) { value in
                Task { @MainActor in
                    self.emit(.exportProgressed(value))
                }
            }
            // 导出没有 `RestoreSummary` 语义，用空摘要占位；`statusText` 走 message 字段。
            emit(.exportSucceeded(message: "备份完成（\(formattedSize(output.byteCount))）",
                                  summary: RestoreSummary()))
            return output.url
        } catch {
            emit(.failed(message: error.localizedDescription))
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
                            workspaceUUIDs: $0.workspaceUUIDs,
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
        guard BackupPolicy.acceptsNewRequest(phase) else { return false }
        emit(.importBegan)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let localCopy = AppPaths.work.appendingPathComponent("import-\(UUID().uuidString).vcal")
        try? FileManager.default.removeItem(at: localCopy)
        do {
            try FileManager.default.copyItem(at: url, to: localCopy)
        } catch {
            emit(.failed(message: "无法读取所选文件：\(error.localizedDescription)"))
            return false
        }

        do {
            let bundle = try await RestoreService.extract(archiveAt: localCopy)
            var warning: String?
            if let manifest = bundle.manifest, manifest.databaseDigest.isEmpty == false {
                let digest = SHA256.hash(data: bundle.databaseData).map { String(format: "%02x", $0) }.joined()
                if digest != manifest.databaseDigest {
                    // 指纹不一致仍允许导入，但必须明确告警，不静默丢弃用户资产。
                    // 告警作为**待恢复相位的载荷**存在：它允许与「等待用户选择策略」共存，
                    // 但绝不与失败 / 成功终态混为一谈。
                    warning = "归档指纹与清单不一致，内容可能被外部修改过。"
                }
            }
            emit(.importParsed(bundle, .smartMerge, warning: warning))
            return true
        } catch {
            emit(.failed(message: error.localizedDescription))
            return false
        }
    }

    func applyPendingRestore(mode: RestoreMode, context: ModelContext) -> RestoreSummary? {
        guard let bundle = phase.pendingRestore else { return nil }
        emit(.strategyChosen(mode))
        emit(.restoreBegan)
        let summary = RestoreApplier.apply(bundle: bundle, mode: mode, context: context)
        emit(.restoreSucceeded(message: summary.message, summary: summary))
        return summary
    }

    /// 放弃待恢复内容（弹窗取消 / 「取消导入」）。
    ///
    /// 只在「等待用户选择策略」时生效：其它相位的终止由下一次请求自然覆盖，
    /// 这样可以避免弹窗自动收起（系统会置 `isPresented = false`）时误清掉刚落地
    /// 的成功态。
    func clearPendingRestore() {
        guard phase.isAwaitingStrategy else { return }
        emit(.dismissed)
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
