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
         isHoliday: Bool = false) {
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
    }

    // MARK: - Codable

    /// 手写解码：`isHoliday` 是后加的字段，老备份/老缓存里没有这个键。
    /// 合成解码器会直接抛 `keyNotFound`（不理会默认值），所以这里显式用 `decodeIfPresent`。
    private enum CodingKeys: String, CodingKey {
        case id, subscriptionUUID, subscriptionName, colorHex, title
        case location, start, end, isAllDay, isHoliday
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
    }
}

/// 节假日 / 调休状态（协议抽象层，业务数据待动态注入）。
enum WorkRestStatus: String, Codable, Sendable {
    case work = "班"
    case rest = "休"
    case normal = ""

    var isVisible: Bool { self != .normal }
}
