import Foundation

/// 日历计算的唯一真源：周一为每周首日、跟随系统时区、禁止使用 DateFormatter（线程安全 + 性能）。
enum CalendarUtils {
    static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2          // 周一
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// 中国大陆法定节假日一律以 **CST（UTC+8）** 为准，不得跟随设备时区。
    ///
    /// 原因：调休补班事件在 ICS 里是 `DTSTART:20260104T090000`（浮动时间、无 TZID），
    /// 语义是「北京时间 1 月 4 日早上 9 点上班」。若按设备时区解释，
    /// 夏威夷（UTC-10）等西部时区的用户会把它算到**前一天**，补班样式就贴错格了。
    static var holidayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    // MARK: - Key 转换

    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 按指定时区取日期键（仅供节假日数据使用，见 `holidayCalendar`）。
    static func key(for date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromKey key: String) -> Date? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))
    }

    // MARK: - 基本运算

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 按指定时区取日首（仅供节假日数据使用）。
    static func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? startOfDay(date)
    }

    /// 由「年 + 月」构造当月首日（月份选择器用）。日固定为 1 号，避开 2/30 之类的溢出。
    static func startOfMonth(year: Int, month: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = 1
        return calendar.date(from: parts) ?? startOfDay(Date())
    }

    static func addMonths(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: value, to: startOfMonth(date)) ?? date
    }

    static func addDays(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: value, to: date) ?? date
    }

    static func month(of date: Date) -> Int { calendar.component(.month, from: date) }
    static func year(of date: Date) -> Int { calendar.component(.year, from: date) }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool { calendar.isDate(lhs, inSameDayAs: rhs) }
    /// 同年同月（月份选择器判断「这格是不是当前正在显示的那个月」用）。
    static func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }
    static func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }

    static func isWeekend(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    // MARK: - 月历矩阵（固定 6 行 × 7 列 = 42 格，保证布局零抖动）

    static func gridDates(forMonthContaining date: Date) -> [Date] {
        let first = startOfMonth(date)
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let start = addDays(-leading, to: first)
        return (0..<42).map { addDays($0, to: start) }
    }

    static func title(forMonth date: Date) -> String {
        "\(year(of: date))年\(month(of: date))月"
    }

    static func dayTitle(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 1)月\(parts.day ?? 1)日 \(weekdayName(date))"
    }

    static func weekdayName(_ date: Date) -> String {
        let weekday = calendar.component(.weekday, from: date)
        let index = (weekday - calendar.firstWeekday + 7) % 7
        return "周" + weekdaySymbols[index]
    }

    static func timeString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func relativeLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        return dayTitle(date)
    }
}
