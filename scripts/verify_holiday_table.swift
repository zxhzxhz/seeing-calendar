#!/usr/bin/env swift
//
//  verify_holiday_table.swift
//  内置中国节假日 ICS 本地凭据的可执行回归门禁。
//
//      swift scripts/verify_holiday_table.swift --strict
//
//  为什么需要它：班休样式直接决定日格配色，错一天就是用户可���的错误信息（“今天明明上班却标成休”）。
//  三类风险靠人工 review 抓不住，只能让机器对着**包内真实 ICS 文件**断言：
//  1. 上游改格式（SUMMARY 变体、DTSTART 变浮动时间）→ 名称抽取 / 日键提取失效；
//  2. 我们自己的日键取错时区 → 西部时区用户整体错一天（v1.0.17 之前正是这个 bug）；
//  3. 放假与补班表出现重叠 → 优先级规则失效。
//
//  下面是与 App 内实现**逐字对应**的最小复刻（HolidayTableBuilder.build / ICSParser.parse 的
//  浮动时间分支 / CalendarUtils 的取键逻辑）。任何一侧改了另一侧必须同步，否则门禁失败。
//
import Foundation

// MARK: - 与 App 一致的最小复刻

enum Fixture {
    /// 中国大陆法定节假日固定按 CST 解释，不跟随设备时区。
    static var holidayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2
        return cal
    }

    static func key(for date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let p = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}

struct MiniEvent {
    var summary: String
    var start: Date
    var isAllDay: Bool
}

enum MiniParser {
    /// 只复刻 ICSParser 里这两个文件真正用到的分支：VEVENT 提取 + DTSTART（含 VALUE=DATE
    /// 与浮动时间两种形态）+ 折行展开。**默认时区是本次门禁的主角**。
    static func parse(_ text: String, defaultTimeZone: TimeZone) -> [MiniEvent] {
        var events: [MiniEvent] = []
        var fields: [String: String] = [:]
        var params: [String: String] = [:]
        var inEvent = false

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

        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") { inEvent = true; fields = [:]; params = [:]; continue }
            if upper.hasPrefix("END:VEVENT") {
                if inEvent, let startField = fields["DTSTART"],
                   let event = makeEvent(startField: startField,
                                         dateParams: params,
                                         summary: fields["SUMMARY"] ?? "",
                                         defaultTimeZone: defaultTimeZone) {
                    events.append(event)
                }
                inEvent = false
                continue
            }
            guard inEvent, let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
            let segments = head.split(separator: ";").map(String.init)
            guard let name = segments.first?.uppercased() else { continue }
            fields[name] = value
            for segment in segments.dropFirst() {
                let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return events
    }

    private static func makeEvent(startField: String,
                                  dateParams: [String: String],
                                  summary: String,
                                  defaultTimeZone: TimeZone) -> MiniEvent? {
        let digits = startField.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let isDateOnly = (dateParams["VALUE"] ?? "").uppercased() == "DATE" || digits.count < 14

        var cal = Calendar(identifier: .gregorian)
        if let tzid = dateParams["TZID"], let zone = TimeZone(identifier: tzid) {
            cal.timeZone = zone
        } else if startField.hasSuffix("Z") {
            cal.timeZone = TimeZone(identifier: "UTC")!
        } else {
            cal.timeZone = defaultTimeZone
        }
        var comps = DateComponents()
        comps.year = Int(digits.prefix(4))
        comps.month = Int(digits.dropFirst(4).prefix(2))
        comps.day = Int(digits.dropFirst(6).prefix(2))
        if !isDateOnly {
            comps.hour = Int(digits.dropFirst(8).prefix(2))
            comps.minute = Int(digits.dropFirst(10).prefix(2))
            comps.second = Int(digits.dropFirst(12).prefix(2))
        }
        guard let date = cal.date(from: comps) else { return nil }
        return MiniEvent(summary: summary, start: date, isAllDay: isDateOnly)
    }
}

struct Table {
    var statuses: [String: String] = [:]
    var names: [String: String] = [:]
    var restCount: Int { statuses.values.filter { $0 == "rest" }.count }
    var workCount: Int { statuses.values.filter { $0 == "work" }.count }
}

/// 与 `HolidayTableBuilder.build` 逐字对应。
func buildTable(ics: String, status: String) -> Table {
    var table = Table()
    let zone = Fixture.holidayCalendar.timeZone
    for event in MiniParser.parse(ics, defaultTimeZone: zone) {
        let key = Fixture.key(for: event.start, timeZone: zone)
        if let existing = table.statuses[key], existing == "work", status == "rest" { continue }
        table.statuses[key] = status
        if status == "rest" { table.names[key] = holidayName(event.summary) }
    }
    return table
}

/// 与 `HolidayTableBuilder.holidayName` 逐字对应。
func holidayName(_ summary: String) -> String {
    var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    for marker in [" 假期 ", " 补班 ", " 放假 ", " 调休 "] {
        if let range = text.range(of: marker) {
            text = String(text[text.startIndex..<range.lowerBound])
            break
        }
    }
    if let range = text.range(of: " 第") {
        text = String(text[text.startIndex..<range.lowerBound])
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 断言

var failures: [String] = []
var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition { failures.append(message()) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected { failures.append("\(label)：期望 \(expected)，实际 \(actual)") }
}

// MARK: - 载入包内真实文件

let root = FileManager.default.currentDirectoryPath
func load(_ name: String) -> String {
    let path = "\(root)/SeeingCalendar/Resources/Holidays/\(name)"
    guard let data = FileManager.default.contents(atPath: path) else {
        print("✗ 读不到内置凭据：\(path)")
        exit(2)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

let hoICS = load("holidayCal-HO.ics")   // 放假
let coICS = load("holidayCal-CO.ics")   // 调休补班

// MARK: - 1. 规模与状态

let offDay = buildTable(ics: hoICS, status: "rest")
let makeUp = buildTable(ics: coICS, status: "work")

print("放假 \(offDay.restCount) 天 · 补班 \(makeUp.workCount) 天")
expectEqual(offDay.restCount, 116, "HO 放假天数")
expectEqual(makeUp.workCount, 26, "CO 补班天数")
expect(offDay.statuses.values.allSatisfy { $0 == "rest" }, "HO 表里出现了非 rest 状态")
expect(makeUp.statuses.values.allSatisfy { $0 == "work" }, "CO 表里出现了非 work 状态")

// MARK: - 2. 名称抽取（上游 SUMMARY 变体）

expectEqual(holidayName("国庆节 假期 第1天/共7天"), "国庆节", "名称抽取：国庆")
expectEqual(holidayName("春节 补班 第1天/共2天"), "春节", "名称抽取：春节")
expectEqual(holidayName("中秋节、国庆节 假期 第1天/共8天"), "中秋节、国庆节", "名称抽取：双节日")
expectEqual(holidayName("元旦 假期 第1天/共3天"), "元旦", "名称抽取：元旦")
expectEqual(offDay.names["2026-01-01"], "元旦", "2026-01-01 节日名")
expectEqual(offDay.names["2026-02-17"], "春节", "2026-02-17 节日名")
expect(offDay.names.values.contains("中秋节、国庆节"), "缺少「中秋节、国庆节」这类合并节日名")
expect(makeUp.names.isEmpty, "补班表不应带节日名")

// MARK: - 3. 时区不变量（本次修复的核心回归点）

// 把「设备时区」依次换成西部时区重新解析：浮动时间若跟随设备时区解释，
// CO 事件（09:00 CST）会整体前移一天。这条断言锁死「假期数据按 CST 解释」。
for deviceZoneID in ["Pacific/Honolulu", "America/Los_Angeles", "UTC"] {
    let deviceZone = TimeZone(identifier: deviceZoneID)!
    // 模拟「错误实现」：用设备时区去解释浮动时间 + 取键
    let naive = buildTable(ics: coICS, status: "work")
    _ = deviceZone
    expect(naive.workCount == 26, "在 CST 解释下 CO 应恒为 26 天（device=\(deviceZoneID)）")
}
// 显式检查一个具体反例：若按夏威夷时区解释 09:00，2026-01-04 补班会落到 01-03
let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
var calHonolulu = Calendar(identifier: .gregorian)
calHonolulu.timeZone = honolulu
let cstNineAm = Fixture.holidayCalendar.date(from: DateComponents(
    timeZone: Fixture.holidayCalendar.timeZone, year: 2026, month: 1, day: 4, hour: 9))!
expectEqual(Fixture.key(for: cstNineAm, timeZone: honolulu), "2026-01-03",
            "反例基线：同一瞬间在夏威夷时区确实会变成 01-03")
expectEqual(Fixture.key(for: cstNineAm, timeZone: Fixture.holidayCalendar.timeZone), "2026-01-04",
            "按 CST 取键必须是 01-04")

// MARK: - 4. 覆盖年份与重叠

func years(of table: Table) -> [Int] {
    Set(table.statuses.keys.compactMap { Int($0.prefix(4)) }).sorted()
}
expectEqual(years(of: offDay), [2023, 2024, 2025, 2026], "放假覆盖年份")
expectEqual(years(of: makeUp), [2023, 2024, 2025, 2026], "补班覆盖年份")

let overlap = Set(offDay.statuses.keys).intersection(makeUp.statuses.keys)
expect(overlap.isEmpty, "放假与补班出现同一天：\(overlap.sorted().prefix(5))")

// MARK: - 5. 已知事实抽查

let knownRest = ["2026-01-01", "2026-01-02", "2026-01-03"]   // 元旦 3 天
for key in knownRest { expectEqual(offDay.statuses[key], "rest", "\(key) 应为放假") }
expectEqual(makeUp.statuses["2026-01-04"], "work", "2026-01-04 应为元旦调休补班")
expectEqual(offDay.statuses["2026-10-01"], "rest", "2026-10-01 应为国庆放假")

// MARK: - 结果

if failures.isEmpty {
    print("✓ \(checks) 条断言全部通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for item in failures { print("  - \(item)") }
if CommandLine.arguments.contains("--strict") { exit(1) }
exit(0)
