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

    var dayKey: String { CalendarUtils.key(for: start) }

    var isSingleDay: Bool { CalendarUtils.isSameDay(start, end) }

    var timeLabel: String {
        if isAllDay { return "全天" }
        let startText = CalendarUtils.timeString(start)
        guard !isSingleDay else { return startText }
        return "\(startText) → \(CalendarUtils.timeString(end))"
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// 节假日 / 调休状态（协议抽象层，业务数据待动态注入）。
enum WorkRestStatus: String, Codable, Sendable {
    case work = "班"
    case rest = "休"
    case normal = ""

    var isVisible: Bool { self != .normal }
}
