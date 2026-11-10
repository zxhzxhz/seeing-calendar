import Foundation

/// 订阅作用域：**把「空数组 = 全局」这个哨兵变成类型**。
///
/// 设计要点：
/// - 持久化仍是 `ICSSubscription.workspaceUUIDs: [UUID]`（**不改 schema**），
///   本类型只是它的**类型化视图**：哨兵（空数组）只在持久化边界出现
///   （`init(persisted:)` / `persisted`），业务逻辑一律走枚举。
/// - 空数组 ↔ `.global`，非空 ↔ `.scoped(Set)`。**迁移期数据（legacy `workspaceUUID`）
///   的合成规则**也集中在这里（`migrating`），不再散落在迁移 / 恢复调用点。
///
/// 为什么需要它：`[UUID]` 的值域里混着「空 = 全局」与「非空 = 单选几个维度」两种含义，
/// 类型上没有任何约束 —— 任何一处忘了判空就会把「全局」当成「谁都不选」。
/// 把哨兵收进 `init(persisted:)` 这一个地点，其余代码就不再有解读哨兵的机会。
enum SubscriptionScopeValue: Equatable, Sendable {
    case global
    case scoped(Set<UUID>)

    /// 从持久化形态读取。**空数组 → `.global`**（哨兵解读的唯一地点）。
    init(persisted: [UUID]) {
        self = persisted.isEmpty ? .global : .scoped(Set(persisted))
    }

    /// 写回持久化形态。`.global` 恒为空数组。
    ///
    /// 注意：`.scoped` 由 `Set` 支撑，**不保证保留原始顺序**。展示层若依赖顺序
    /// （例如按勾选顺序拼维度名），应直接读模型上的 `workspaceUUIDs`。
    var persisted: [UUID] {
        switch self {
        case .global:
            return []
        case .scoped(let set):
            return Array(set)
        }
    }

    /// 该作用域是否覆盖某个维度。
    func applies(to workspaceUUID: UUID) -> Bool {
        switch self {
        case .global:
            return true
        case .scoped(let set):
            return set.contains(workspaceUUID)
        }
    }

    /// 合并两个作用域（多选编辑用）：**任一方为全局则结果为全局**。
    ///
    /// 「全局」语义上是全集，与任何集合的并集仍是全集。若错误地实现成「取并集」，
    /// 全局（空集合）与 A 合并会退化成 A —— 用户会看到「全局」莫名其妙收窄成单个维度。
    static func merge(_ a: SubscriptionScopeValue,
                      _ b: SubscriptionScopeValue) -> SubscriptionScopeValue {
        switch (a, b) {
        case (.global, _), (_, .global):
            return .global
        case (.scoped(let x), .scoped(let y)):
            return .scoped(x.union(y))
        }
    }

    /// 迁移：由 legacy 单一维度 + 既有数组合成。
    ///
    /// legacy 非空即「还没迁移」，此时以它为唯一作用域（与旧写法 `[legacy]` 一致，
    /// `existing` 被忽略 —— 迁移前 `workspaceUUIDs` 恒为默认空数组）；
    /// legacy 为空则沿用既有数组（空数组仍解读为全局）。
    static func migrating(legacy: UUID?, existing: [UUID]) -> SubscriptionScopeValue {
        if let legacy { return .scoped([legacy]) }
        return SubscriptionScopeValue(persisted: existing)
    }
}
