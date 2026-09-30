import Foundation

// MARK: - 解析产物

struct ICSEvent: Sendable {
    var uid: String
    var summary: String
    var location: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var rrule: RecurrenceRule?
    var exdates: Set<Date>
}

struct RecurrenceRule: Sendable {
    enum Frequency: String, Sendable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    var frequency: Frequency
    var interval: Int = 1
    var count: Int?
    var until: Date?
    /// 1 = 周一 … 7 = 周日
    var byDay: [Int] = []
}

// MARK: - RFC 5545 子集解析器（无第三方依赖）

enum ICSParser {
    private struct Field {
        var params: [String: String]
        var value: String
    }

    /// 展开折行、逐事件解析。
    ///
    /// - Parameter defaultTimeZone: 无 `TZID`、无 `Z` 后缀的浮动时间的解释时区。
    ///   中国节假日数据必须传 `CalendarUtils.holidayCalendar.timeZone`（CST）；
    ///   用户自建的普通订阅传 nil 即可（跟随设备时区）。
    static func parse(_ text: String, defaultTimeZone: TimeZone? = nil) -> [ICSEvent] {
        var events: [ICSEvent] = []
        var fields: [String: Field] = [:]
        var inEvent = false

        for line in unfold(text) {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                inEvent = true
                fields = [:]
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                if inEvent, let event = makeEvent(fields, defaultTimeZone: defaultTimeZone) {
                    events.append(event)
                }
                inEvent = false
                continue
            }
            guard inEvent, let (name, field) = split(line) else { continue }
            fields[name] = field
        }
        return events
    }

    /// 将含 RRULE 的事件展开到给定窗口内的所有具体发生点。
    static func occurrences(of event: ICSEvent, in range: DateInterval, limit: Int = 300) -> [DateInterval] {
        let duration = max(event.end.timeIntervalSince(event.start), 0)
        var results: [DateInterval] = []

        func emit(_ start: Date) {
            guard results.count < limit else { return }
            guard !event.exdates.contains(start) else { return }
            let end = start.addingTimeInterval(duration)
            guard start < range.end, end > range.start else { return }
            results.append(DateInterval(start: start, end: end))
        }

        guard let rule = event.rrule else {
            emit(event.start)
            return results
        }

        let calendar = CalendarUtils.calendar
        var produced = 0
        var iterations = 0

        func reachedLimit(_ date: Date) -> Bool {
            if let count = rule.count, produced >= count { return true }
            if let until = rule.until, date > until { return true }
            if date >= range.end { return true }
            return false
        }

        if rule.frequency == .weekly, !rule.byDay.isEmpty {
            let timeOfDay = calendar.dateComponents([.hour, .minute, .second], from: event.start)
            let weekStart = startOfWeek(event.start)
            var week = 0
            while iterations < 3_000 {
                iterations += 1
                let base = calendar.date(byAdding: .weekOfYear, value: week * max(1, rule.interval), to: weekStart) ?? weekStart
                if reachedLimit(base) { break }
                var weekHasCandidate = false
                for weekday in rule.byDay.sorted() {
                    let dayOffset = weekday - 1
                    guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: base) else { continue }
                    var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
                    components.hour = timeOfDay.hour
                    components.minute = timeOfDay.minute
                    components.second = timeOfDay.second
                    guard let candidate = calendar.date(from: components), candidate >= event.start else { continue }
                    weekHasCandidate = true
                    produced += 1
                    if reachedLimit(candidate) { break }
                    emit(candidate)
                }
                if !weekHasCandidate && week > 0 && produced == 0 && week > 208 { break }
                week += 1
                if week > 520 { break }
            }
            return results
        }

        var cursor = event.start
        while iterations < 3_000 {
            iterations += 1
            if reachedLimit(cursor) { break }
            produced += 1
            emit(cursor)

            switch rule.frequency {
            case .daily:
                guard let next = calendar.date(byAdding: .day, value: max(1, rule.interval), to: cursor) else { break }
                cursor = next
            case .weekly:
                guard let next = calendar.date(byAdding: .weekOfYear, value: max(1, rule.interval), to: cursor) else { break }
                cursor = next
            case .monthly:
                guard let next = calendar.date(byAdding: .month, value: max(1, rule.interval), to: cursor) else { break }
                cursor = next
            case .yearly:
                guard let next = calendar.date(byAdding: .year, value: max(1, rule.interval), to: cursor) else { break }
                cursor = next
            }
        }
        return results
    }

    // MARK: - 内部工具

    private static func startOfWeek(_ date: Date) -> Date {
        let calendar = CalendarUtils.calendar
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    private static func unfold(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let last = lines.popLast() {
                lines.append(last + String(line.dropFirst()))
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    private static func split(_ line: String) -> (String, Field)? {
        var insideQuotes = false
        var colonIndex: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == ":" && !insideQuotes {
                colonIndex = index
                break
            }
        }
        guard let colon = colonIndex else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = head.split(separator: ";").map(String.init)
        guard let name = segments.first?.uppercased(), !name.isEmpty else { return nil }

        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (name, Field(params: params, value: value))
    }

    private static func makeEvent(_ fields: [String: Field], defaultTimeZone: TimeZone?) -> ICSEvent? {
        guard let startField = fields["DTSTART"], let start = parseDate(startField, defaultTimeZone: defaultTimeZone) else { return nil }

        var end = start.date
        var isAllDay = start.isDateOnly
        if let endField = fields["DTEND"], let parsed = parseDate(endField) {
            end = parsed.date
            isAllDay = isAllDay || parsed.isDateOnly
        } else if let durationField = fields["DURATION"], let seconds = parseDuration(durationField.value) {
            end = start.date.addingTimeInterval(seconds)
        }

        if isAllDay {
            let startOfDay = CalendarUtils.startOfDay(start.date, timeZone: defaultTimeZone ?? CalendarUtils.calendar.timeZone)
            let endOfDay = CalendarUtils.startOfDay(end, timeZone: defaultTimeZone ?? CalendarUtils.calendar.timeZone)
            if endOfDay <= startOfDay {
                end = CalendarUtils.addDays(1, to: startOfDay)
            } else {
                end = endOfDay
            }
        } else if end < start.date {
            end = start.date.addingTimeInterval(60)
        }

        var exdates: Set<Date> = []
        if let exdateField = fields["EXDATE"] {
            for chunk in exdateField.value.split(separator: ",") {
                if let parsed = parseDate(Field(params: exdateField.params, value: String(chunk))) {
                    exdates.insert(parsed.date)
                }
            }
        }

        return ICSEvent(uid: fields["UID"]?.value ?? UUID().uuidString,
                        summary: unescape(fields["SUMMARY"]?.value ?? "未命名日程"),
                        location: fields["LOCATION"].map { unescape($0.value) },
                        start: isAllDay
                            ? CalendarUtils.startOfDay(start.date, timeZone: defaultTimeZone ?? CalendarUtils.calendar.timeZone)
                            : start.date,
                        end: end,
                        isAllDay: isAllDay,
                        rrule: fields["RRULE"].flatMap { parseRule($0.value) },
                        exdates: exdates)
    }

    private static func parseDate(_ field: Field, defaultTimeZone: TimeZone? = nil) -> (date: Date, isDateOnly: Bool)? {
        let raw = field.value.trimmingCharacters(in: .whitespaces)
        let digits = raw.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let isDateOnly = (field.params["VALUE"] ?? "").uppercased() == "DATE" || digits.count < 14

        var calendar = Calendar(identifier: .gregorian)
        if let tzid = field.params["TZID"], let zone = TimeZone(identifier: tzid) {
            calendar.timeZone = zone
        } else if raw.hasSuffix("Z") {
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        } else {
            calendar.timeZone = defaultTimeZone ?? .current
        }

        var components = DateComponents()
        components.year = Int(digits.prefix(4)) ?? 0
        components.month = Int(digits.dropFirst(4).prefix(2)) ?? 1
        components.day = Int(digits.dropFirst(6).prefix(2)) ?? 1
        if !isDateOnly {
            components.hour = Int(digits.dropFirst(8).prefix(2)) ?? 0
            components.minute = Int(digits.dropFirst(10).prefix(2)) ?? 0
            components.second = Int(digits.dropFirst(12).prefix(2)) ?? 0
        }
        guard let date = calendar.date(from: components) else { return nil }
        return (date, isDateOnly)
    }

    private static func parseDuration(_ value: String) -> TimeInterval? {
        var text = value.uppercased()
        let negative = text.hasPrefix("-")
        if negative || text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()
        var seconds: Double = 0
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            let amount = Double(digits) ?? 0
            digits = ""
            switch character {
            case "W": seconds += amount * 7 * 86_400
            case "D": seconds += amount * 86_400
            case "H": seconds += amount * 3_600
            case "M": seconds += amount * 60
            case "S": seconds += amount
            default: break
            }
        }
        return negative ? -seconds : seconds
    }

    private static func parseRule(_ value: String) -> RecurrenceRule? {
        var rule: RecurrenceRule?
        for segment in value.split(separator: ";") {
            let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].uppercased()
            let raw = pair[1].uppercased()

            if key == "FREQ" {
                guard let frequency = RecurrenceRule.Frequency(rawValue: raw) else { return nil }
                rule = RecurrenceRule(frequency: frequency)
                continue
            }
            guard rule != nil else { continue }

            switch key {
            case "INTERVAL":
                rule?.interval = max(1, Int(raw) ?? 1)
            case "COUNT":
                rule?.count = Int(raw)
            case "UNTIL":
                if let parsed = parseDate(Field(params: [:], value: raw)) {
                    rule?.until = parsed.date
                }
            case "BYDAY":
                let map: [String: Int] = ["MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7]
                let days = raw.split(separator: ",").compactMap { token -> Int? in
                    let key = token.suffix(2).uppercased()
                    return map[String(key)]
                }
                rule?.byDay = days
            default:
                break
            }
        }
        return rule
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
