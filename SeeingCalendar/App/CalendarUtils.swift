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

    // MARK: - Key 转换

    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
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

    static func startOfMonth(_ date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? startOfDay(date)
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
