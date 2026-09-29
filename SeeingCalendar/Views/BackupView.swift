import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.vcal`（Visual Calendar Archive）：ZIP 容器的自定义扩展名。
    static let vcalArchive = UTType(exportedAs: "com.seeingcalendar.vcal")
}

/// 备份 / 恢复 / 自动快照面板。
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let coordinator: BackupCoordinator

    @State private var exportedURL: URL?
    @State private var snapshots: [URL] = []
    @State private var isImporterPresented = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                exportSection
                snapshotSection
                restoreSection
            }
            .navigationTitle("备份与恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { snapshots = Self.listSnapshots() }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: [.vcalArchive, .zip],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        _ = await coordinator.prepareRestore(at: url)
                        if let error = coordinator.lastError {
                            message = error
                        }
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - 区块

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Label("版本", systemImage: "number")
                    .font(.system(size: 13))
                Spacer()
                Text(AppVersion.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(coordinator.statusText.isEmpty ? "就绪" : coordinator.statusText,
                      systemImage: coordinator.isWorking ? "arrow.triangle.2.circlepath" : "checkmark.seal")
                    .font(.system(size: 13))
                Spacer()
                if coordinator.isWorking {
                    ProgressView(value: coordinator.progress)
                        .frame(width: 80)
                }
            }
            if let error = coordinator.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        } header: {
            Text("状态")
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Button {
                Task {
                    exportedURL = await coordinator.exportArchive(context: context)
                }
            } label: {
                Label("生成完整备份（.vcal）", systemImage: "square.and.arrow.up")
            }
            .disabled(coordinator.isWorking)

            if let exportedURL {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exportedURL.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        Text(fileSizeText(exportedURL))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: exportedURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text("手动完整备份")
        } footer: {
            Text("归档为 ZIP 容器：manifest.json + database_dump.json + drawings/ + assets/，可通过文件 App、隔空投送、外置硬盘或云盘保存。")
        }
    }

    @ViewBuilder
    private var snapshotSection: some View {
        Section {
            if snapshots.isEmpty {
                Text("暂无自动快照").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ForEach(snapshots, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent).font(.system(size: 12))
                            Text(fileSizeText(url)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? FileManager.default.removeItem(at: snapshots[index])
                    }
                    snapshots = Self.listSnapshots()
                }
            }
        } header: {
            Text("自动本地快照（最多保留 3 份）")
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        Section {
            Button {
                isImporterPresented = true
            } label: {
                Label("选择 .vcal 归档导入", systemImage: "tray.and.arrow.down")
            }
            .disabled(coordinator.isWorking)

            if coordinator.pendingRestore != nil {
                Text("归档已就绪，请选择冲突消解策略：")
                    .font(.system(size: 12, weight: .medium))
                ForEach(RestoreMode.allCases) { mode in
                    Button {
                        if let summary = coordinator.applyPendingRestore(mode: mode, context: context) {
                            message = summary.message
                        }
                        snapshots = Self.listSnapshots()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).font(.system(size: 13, weight: .semibold))
                            Text(mode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(role: .cancel) {
                    coordinator.clearPendingRestore()
                } label: {
                    Text("取消导入")
                }
            }
        } header: {
            Text("导入与恢复")
        } footer: {
            Text("导入前会校验 CRC 与归档指纹；智能增量合并会把同日冲突的备份画作转为后置拓展页，杜绝笔迹被覆盖。")
        }
    }

    private func fileSizeText(_ url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    static func listSnapshots() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.snapshots,
                                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "vcal" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left > right
            }
    }
}
