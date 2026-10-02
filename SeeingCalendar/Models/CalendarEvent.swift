import Foundation

/// 一条已展开为具体时间点的日程（ICS 的最小可视单元）。
/// 月历格内以“微型胶囊 / 彩点”非侵入式呈现，绝不与手绘争抢视觉焦点。
struct CalendarEvent: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var subscriptionUUID: UUID
    var subscriptionName: String
    var colorHex: String
    var title: String
    var location: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// 来自内置节假日凭据（放假 / 调休）。这类事件不画日格胶囊，只驱动班休样式与角标。
    var isHoliday: Bool = false
    /// 作用域快照：来源订阅绑在哪些维度上（**空 = 全局**）。
    ///
    /// 为什么要随事件一起落缓存：显示层是在月历渲染那一刻按**当前维度**筛的，
    /// 而那一刻没有订阅模型可用（缓存可能比订阅列表还新）。作用域跟着事件走，
    /// 离线也不会把维度归属算错。
    var scope: [UUID] = []

    var dayKey: String { CalendarUtils.key(for: start) }

    var isSingleDay: Bool { CalendarUtils.isSameDay(start, end) }

    var timeLabel: String {
        if isAllDay { return "全天" }
        let startText = CalendarUtils.timeString(start)
        guard !isSingleDay else { return startText }
        return "\(startText) → \(CalendarUtils.timeString(end))"
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// 显式成员初始化。
    ///
    /// 为什么必须手写：本类型在下方声明了 `init(from:)`，而**只要结构体体内出现过任何
    /// 自定义初始化，Swift 合成的成员初始化就不会生成**。不写这里，构造调用会被解析到
    /// `init(from:)` 上，报出与真实原因毫无关系的 `missing argument for parameter 'from'`
    /// 加上 `extra arguments at positions #1…#10`（v1.0.17 首次 CI 编译就是这么炸的）。
    /// `isHoliday` 保留默认值，老调用点无需修改。
    init(id: String,
         subscriptionUUID: UUID,
         subscriptionName: String,
         colorHex: String,
         title: String,
         location: String?,
         start: Date,
         end: Date,
         isAllDay: Bool,
         isHoliday: Bool = false,
         scope: [UUID] = []) {
        self.id = id
        self.subscriptionUUID = subscriptionUUID
        self.subscriptionName = subscriptionName
        self.colorHex = colorHex
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isHoliday = isHoliday
        self.scope = scope
    }

    // MARK: - Codable

    /// 手写解码：`isHoliday` 是后加的字段，老备份/老缓存里没有这个键。
    /// 合成解码器会直接抛 `keyNotFound`（不理会默认值），所以这里显式用 `decodeIfPresent`。
    private enum CodingKeys: String, CodingKey {
        case id, subscriptionUUID, subscriptionName, colorHex, title
        case location, start, end, isAllDay, isHoliday, scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subscriptionUUID = try container.decode(UUID.self, forKey: .subscriptionUUID)
        subscriptionName = try container.decode(String.self, forKey: .subscriptionName)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        title = try container.decode(String.self, forKey: .title)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        isHoliday = try container.decodeIfPresent(Bool.self, forKey: .isHoliday) ?? false
        // 全量重取会覆盖缓存，旧缓存里没有作用域 —— 缺字段按「全局」，
        // 顶多在下一次刷新前多显示几个维度，不会把事件藏起来。
        scope = try container.decodeIfPresent([UUID].self, forKey: .scope) ?? []
    }
}

/// 订阅作用域判定（**空 = 全局**）。
///
/// 单独抽出来的理由很实在：订阅模型（`ICSSubscription`）与事件快照（`CalendarEvent`）
/// 都要判定同一件事，两边各写一遍迟早会漂移 —— 一边改了另一边没改，
/// 表现是「设置页写着 2 个维度，月历上却在别的维度也显示」，最难查的一种 bug。
enum SubscriptionScope {
    /// 空作用域 = 全局，任何维度都命中。
    static func applies(_ scope: [UUID], to workspaceUUID: UUID) -> Bool {
        scope.isEmpty || scope.contains(workspaceUUID)
    }

    /// 摘要：**空 = 全局，非空只报数量**。
    ///
    /// 只报数量、不拼维度名：用户自建的维度名可能很长，拼进来会让那一行的高度
    /// 随名字变化，列表看起来在抖。
    static func summary(_ scope: [UUID]) -> String {
        scope.isEmpty ? "全局（所有维度）" : "\(scope.count) 个维度"
    }

    /// 作用于行的勾选切换。
    ///
    /// 全局态（空作用域）下的第一次勾选不是「追加」而是「脱离全局」——
    /// 空数组不含任何 uuid，`scope + [uuid]` 天然给出「只选这一个」，无需特判。
    /// 反向也成立：取消到最后一个维度时回到空数组 = 全局，
    /// 界面上表现为「全局」那行重新亮起，是可见的，不是静默漂移。
    static func toggling(_ scope: [UUID], _ workspaceUUID: UUID) -> [UUID] {
        scope.contains(workspaceUUID) ? scope.filter { $0 != workspaceUUID } : scope + [workspaceUUID]
    }
}

/// 节假日 / 调休状态（协议抽象层，业务数据待动态注入）。
enum WorkRestStatus: String, Codable, Sendable {
    case work = "班"
    case rest = "休"
    case normal = ""

    var isVisible: Bool { self != .normal }
}
