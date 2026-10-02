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

    /// 一次性迁移：把旧版单选作用域（`workspaceUUID`）搬进多选作用域（`workspaceUUIDs`）。
    ///
    /// 在 `App.init` 里调用，**早于任何视图读取模型**，所以升级后的第一帧就是正确作用域 ——
    /// 不存在「先全局显示一下、下次启动才收窄」的窗口。
    ///
    /// 迁移与写入隐式幂等：只处理「旧字段非空」的记录，而 `setScope` 会把旧字段腾空，
    /// 因此重复调用不会把已经被用户改成全局的订阅又拉回旧作用域。
    /// 不做 `#Predicate` 过滤：订阅表只有个位数行，全量取回再筛比风险更低。
    @MainActor
    static func migrateSubscriptionScopes(in container: ModelContainer) {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<ICSSubscription>())) ?? []
        let legacy = all.filter { $0.workspaceUUID != nil }
        guard !legacy.isEmpty else { return }
        for subscription in legacy {
            // 上面的过滤保证 `workspaceUUID` 非空；真解包失败也只清掉旧字段，
            // 不猜作用域（宁可退回全局，也不要凭空断定某个维度）。
            subscription.setScope(subscription.workspaceUUID.map { [$0] } ?? [])
        }
        try? context.save()
    }
}
