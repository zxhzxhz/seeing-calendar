import Foundation
import Observation

/// 内置节假日数据源：把「放假(HO) / 补班(CO)」两份 ICS 本地凭据编译成 O(1) 可查的日表。
///
/// 设计要点（第一性原理）：
/// 1. **表驱动**：月历格在滑动时每帧都会问「这天休还是班」，因此必须是 O(1) 字典查表，
///    而不是每月按需拉取（`HolidayProviderProtocol` 的月度接口保留给远端 Provider）。
/// 2. **本地优先**：随包内置 2023–2026 全量数据，冷启动零网络即可正确着色。
/// 3. **联网可更新**：用户可主动同步上游最新版；失败时静默回落到内置数据，绝不让日历变空。
/// 4. **语义抽取**：ICS 的 SUMMARY 形如 `国庆节 假期 第1天/共7天`，
///    这里抽出节日名 `国庆节` 供日格角标显示，并保留原始整串供抽屉展示。
struct BundledHolidayTable: Sendable {
    /// 日期键 → 班休状态（`.rest` 放假 / `.work` 补班）。
    var statuses: [String: WorkRestStatus] = [:]
    /// 日期键 → 节日名（`国庆节`），仅放假日有值。
    var names: [String: String] = [:]

    var isEmpty: Bool { statuses.isEmpty }
    var restCount: Int { statuses.values.filter { $0 == .rest }.count }
    var workCount: Int { statuses.values.filter { $0 == .work }.count }
    var coveredYears: [Int] {
        var years = Set<Int>()
        for key in statuses.keys {
            if let date = CalendarUtils.date(fromKey: key) { years.insert(CalendarUtils.year(of: date)) }
        }
        return years.sorted()
    }
}

/// 内置 ICS 本地凭据的描述符：文件名 / 订阅名 / 对应状态 / 稳定 UUID。
enum BundledHolidaySource: String, CaseIterable, Sendable {
    case offDay
    case makeUpWork

    /// 上游 china-holiday-calender 提供的原始文件名（同时是包内资源名）。
    var resourceName: String {
        switch self {
        case .offDay: return "holidayCal-HO"
        case .makeUpWork: return "holidayCal-CO"
        }
    }
    var fileName: String { "\(resourceName).ics" }

    var status: WorkRestStatus {
        switch self {
        case .offDay: return .rest
        case .makeUpWork: return .work
        }
    }

    /// 订阅在 UI 中展示的名称。
    var subscriptionName: String {
        switch self {
        case .offDay: return "中国节假日 · 放假"
        case .makeUpWork: return "中国节假日 · 调休补班"
        }
    }

    var colorHex: String {
        switch self {
        case .offDay: return "E8613C"
        case .makeUpWork: return "2F9E6E"
        }
    }

    /// 固定 UUID：保证每次启动都能幂等地找回同一条订阅记录，不会重复播种。
    var stableUUID: UUID {
        switch self {
        case .offDay: return UUID(uuidString: "6C1E7A10-0001-4C7A-9E01-0000000000A1")!
        case .makeUpWork: return UUID(uuidString: "6C1E7A10-0002-4C7A-9E01-0000000000A2")!
        }
    }

    /// 订阅 URL 使用自定义 scheme 标记「读包内资源」，避免与网络订阅混淆。
    var urlString: String { "bundled://\(fileName)" }

    /// 上游地址（联网更新用）。jsDelivr 为主，GitHub raw 为备。
    var remoteURLs: [URL] {
        let path = "lanceliao/china-holiday-calender@master/\(fileName)"
        let urls = [
            "https://cdn.jsdelivr.net/gh/\(path)",
            "https://raw.githubusercontent.com/\(path)",
        ]
        return urls.compactMap { URL(string: $0) }
    }

    static func source(forURLString raw: String) -> BundledHolidaySource? {
        guard raw.lowercased().hasPrefix("bundled://") else { return nil }
        let name = String(raw.dropFirst("bundled://".count)).lowercased()
        return allCases.first { $0.fileName.lowercased() == name }
    }
}

/// 解析器：ICS 文本 → `BundledHolidayTable`。
enum HolidayTableBuilder {
    /// 从 ICS 文本构建日表。`status` 决定整份文件是「放假」还是「补班」。
    ///
    /// 解析与取键都固定在 CST（见 `CalendarUtils.holidayCalendar`）：调休事件在 ICS 里是
    /// 浮动时间 09:00，若跟随设备时区解释，西部时区用户会把补班样式贴到前一天。
    static func build(ics text: String, status: WorkRestStatus) -> BundledHolidayTable {
        var table = BundledHolidayTable()
        let zone = CalendarUtils.holidayCalendar.timeZone
        for event in ICSParser.parse(text, defaultTimeZone: zone) {
            // HO 是全天事件（VALUE=DATE），CO 是 09:00–18:00 的定时事件；
            // 两种都以「开始日」为准落到日表上。
            let key = CalendarUtils.key(for: event.start, timeZone: zone)
            // 补班优先级高于放假：同一天同时出现时，以「要上班」为准。
            if let existing = table.statuses[key], existing == .work, status == .rest { continue }
            table.statuses[key] = status
            if status == .rest, let name = holidayName(from: event.summary) {
                table.names[key] = name
            }
        }
        return table
    }

    /// `国庆节 假期 第1天/共7天` → `国庆节`；`春节 补班 第1天/共2天` → `春节`。
    static func holidayName(from summary: String) -> String? {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in [" 假期 ", " 补班 ", " 放假 ", " 调休 "] {
            if let range = text.range(of: marker) {
                text = String(text[text.startIndex..<range.lowerBound])
                break
            }
        }
        // 兜底：若仍带「第N天/共M天」尾巴，截掉。
        if let range = text.range(of: " 第") {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// 节假日数据源：内置数据 + 可选的联网更新缓存。
///
/// 生命周期：`HolidayRegistry` 在首次 `rebuild` 时触发一次 `ensureLoaded()`（同步读包，< 5 ms）。
@MainActor
@Observable
final class BundledHolidayProvider: HolidayProviderProtocol {
    static let shared = BundledHolidayProvider()

    private(set) var offDayTable = BundledHolidayTable()
    private(set) var makeUpWorkTable = BundledHolidayTable()
    /// 数据来源说明，展示在订阅页里。
    private(set) var originText = "内置"
    /// 上游描述文件的更新时间（`X-WR-CALDESC` 里的时间戳）。
    private(set) var updatedAt: String?
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?

    private var hasLoaded = false

    func table(for source: BundledHolidaySource) -> BundledHolidayTable {
        switch source {
        case .offDay: return offDayTable
        case .makeUpWork: return makeUpWorkTable
        }
    }

    // MARK: - 加载

    /// 同步加载：优先使用上次联网更新落盘的缓存，缺失时读包内资源。
    func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        var usedCache = false
        for source in BundledHolidaySource.allCases {
            if let cached = Self.cachedText(for: source), !cached.isEmpty {
                set(table: HolidayTableBuilder.build(ics: cached, status: source.status), for: source)
                usedCache = true
            } else if let bundled = Self.bundledText(for: source) {
                set(table: HolidayTableBuilder.build(ics: bundled, status: source.status), for: source)
            } else {
                set(table: BundledHolidayTable(), for: source)
            }
        }
        originText = usedCache ? "内置 + 已更新" : "内置"
    }

    private func set(table: BundledHolidayTable, for source: BundledHolidaySource) {
        switch source {
        case .offDay:
            offDayTable = table
        case .makeUpWork:
            makeUpWorkTable = table
        }
    }

    private static func bundledText(for source: BundledHolidaySource) -> String? {
        guard let url = Bundle.main.url(forResource: source.resourceName,
                                       withExtension: "ics",
                                       subdirectory: "Holidays")
                ?? Bundle.main.url(forResource: source.resourceName, withExtension: "ics") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func cachedText(for source: BundledHolidaySource) -> String? {
        let url = AppPaths.cacheRoot.appendingPathComponent("holiday-\(source.resourceName).ics")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
        return text.isEmpty ? nil : text
    }

    /// **唯一**的 ICS 取源入口：优先上次联网更新落盘的缓存，否则读包内资源。
    ///
    /// `ensureLoaded()`（着色日表）与 `CalendarEventStore.fetch`（抽屉事件列表）必须走同一条取源逻辑，
    /// 否则会出现「格子上色是新版、抽屉里还是旧版」的自相矛盾。
    nonisolated static func effectiveICSURL(for source: BundledHolidaySource) -> URL? {
        let cached = AppPaths.cacheRoot.appendingPathComponent("holiday-\(source.resourceName).ics")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let size = attributes[.size] as? Int, size > 0 {
            return cached
        }
        return Bundle.main.url(forResource: source.resourceName, withExtension: "ics", subdirectory: "Holidays")
            ?? Bundle.main.url(forResource: source.resourceName, withExtension: "ics")
    }

    // MARK: - 联网更新

    /// 依次尝试各镜像地址；任一成功即落盘并替换表，全部失败则保留内置数据。
    func syncFromUpstream() async {
        ensureLoaded()
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        var failures: [String] = []
        for source in BundledHolidaySource.allCases {
            var text: String?
            for url in source.remoteURLs {
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw NSError(domain: "Holiday", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                    }
                    let decoded = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                    guard decoded.contains("BEGIN:VEVENT") else {
                        throw NSError(domain: "Holiday", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "响应不含 VEVENT"])
                    }
                    text = decoded
                    break
                } catch {
                    failures.append("\(source.fileName)：\(error.localizedDescription)")
                }
            }
            guard let text else { continue }
            let url = AppPaths.cacheRoot.appendingPathComponent("holiday-\(source.resourceName).ics")
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            set(table: HolidayTableBuilder.build(ics: text, status: source.status), for: source)
            updatedAt = Self.stamp(in: text) ?? updatedAt
        }

        originText = "内置 + 已更新"
        if failures.count == BundledHolidaySource.allCases.count {
            lastSyncError = failures.first
        }
    }

    /// 从 `X-WR-CALDESC` 里抠出「更新时间2025-11-04 23:59:04」。
    private static func stamp(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let upper = line.uppercased()
            guard upper.hasPrefix("X-WR-CALDESC:") else { continue }
            let value = String(line.dropFirst("X-WR-CALDESC:".count))
            guard let range = value.range(of: "更新时间") else { return value }
            return String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - HolidayProviderProtocol

    func fetchHolidaySchedule(year: Int, month: Int) async throws -> [Date: WorkRestStatus] {
        ensureLoaded()
        var result: [Date: WorkRestStatus] = [:]
        for (key, status) in mergedStatuses() {
            guard let date = CalendarUtils.date(fromKey: key) else { continue }
            if CalendarUtils.year(of: date) == year, CalendarUtils.month(of: date) == month {
                result[date] = status
            }
        }
        return result
    }

    func queryStatus(for date: Date) -> WorkRestStatus {
        ensureLoaded()
        return mergedStatuses()[CalendarUtils.key(for: date)] ?? .normal
    }

    func queryName(for date: Date) -> String? {
        ensureLoaded()
        return offDayTable.names[CalendarUtils.key(for: date)]
    }

    /// 合并后的完整日表（放假在前，补班覆盖）。
    private func mergedStatuses() -> [String: WorkRestStatus] {
        var merged = offDayTable.statuses
        for (key, status) in makeUpWorkTable.statuses { merged[key] = status }
        return merged
    }
}
