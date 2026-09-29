import Foundation
import SwiftData

/// SwiftData 容器装配（带损坏自愈：损坏的落盘库会被移出并降级为内存库，避免启动即崩）。
enum AppDataStack {
    static let schema = Schema([
        Workspace.self,
        DayRecord.self,
        DrawingPage.self,
        ImageRecord.self,
        ICSSubscription.self
    ])

    static func makeContainer() -> ModelContainer {
        AppPaths.ensureDirectories()
        let diskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return container
        }
        let storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.moveItem(at: url,
                                              to: url.deletingLastPathComponent()
                                                .appendingPathComponent("corrupt-\(UUID().uuidString).store"))
        }
        if let container = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            return container
        }
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // 二次失败说明运行环境异常，内存库仍能保证 UI 可用性。
        return try! ModelContainer(for: schema, configurations: [memoryConfig])
    }
}
