import Foundation
import Observation
import SwiftData

extension CalendarEvent {
    /// 半开区间重叠判定，天然支持跨天 / 全天日程。
    func overlaps(day: Date) -> Bool {
        let dayStart = CalendarUtils.startOfDay(day)
        let dayEnd = CalendarUtils.addDays(1, to: dayStart)
        return start < dayEnd && end > dayStart
    }
}

/// ICS 订阅源快照（SwiftData 模型不可跨隔离域，先降维为纯值类型）。
struct SubscriptionSnapshot: Sendable {
    let uuid: UUID
    let name: String
    let colorHex: String
    let url: URL
    let workspaceUUID: UUID?
    /// 内置节假日凭据：读包内资源（不走网络）、覆盖全部年份、且不画日格胶囊。
    let isHoliday: Bool
}

/// ICS 订阅聚合与按日索引。所有网络与解析都在非主线程完成，主线程只做索引与展示。
@MainActor
@Observable
final class CalendarEventStore {
    private(set) var events: [CalendarEvent] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?

    private var dayIndex: [String: [CalendarEvent]] = [:]
    private var cacheURL: URL { AppPaths.cacheRoot.appendingPathComponent("events.json") }

    init() {
        loadCache()
    }

    // MARK: - 查询

    func events(on date: Date) -> [CalendarEvent] {
        dayIndex[CalendarUtils.key(for: date)] ?? []
    }

    func events(onDayKey key: String) -> [CalendarEvent] {
        dayIndex[key] ?? []
    }

    func eventCount(on date: Date) -> Int {
        events(on: date).count
    }

    // MARK: - 缓存

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? BackupCoding.decoder.decode([CalendarEvent].self, from: data) else { return }
        events = decoded
        rebuildIndex()
    }

    private func persistCache() {
        guard let data = try? BackupCoding.encoder.encode(events) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - 刷新

    func refresh(subscriptions: [ICSSubscription], force: Bool = false) async {
        let snapshots: [SubscriptionSnapshot] = subscriptions
            .filter { $0.isEnabled && !$0.urlString.isEmpty }
            .compactMap { subscription in
                if let source = subscription.bundledSource {
                    return SubscriptionSnapshot(uuid: subscription.uuid,
                                                name: subscription.name,
                                                colorHex: subscription.colorHex,
                                                url: URL(string: "file:///\(source.fileName)")!,
                                                workspaceUUID: subscription.workspaceUUID,
                                                isHoliday: true)
                }
                guard let url = CalendarEventStore.normalizedURL(subscription.urlString) else { return nil }
                return SubscriptionSnapshot(uuid: subscription.uuid,
                                            name: subscription.name,
                                            colorHex: subscription.colorHex,
                                            url: url,
                                            workspaceUUID: subscription.workspaceUUID,
                                            isHoliday: false)
            }

        guard !snapshots.isEmpty else {
            events = []
            rebuildIndex()
            return
        }

        let now = Date()
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < 900, !events.isEmpty {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let window = DateInterval(start: CalendarUtils.addMonths(-2, to: now),
                                 end: CalendarUtils.addMonths(4, to: now))
        var collected: [CalendarEvent] = []
        var failures: [String] = []

        await withTaskGroup(of: Result<[CalendarEvent], Error>.self) { group in
            for snapshot in snapshots {
                group.addTask {
                    do {
                        let events = try await CalendarEventStore.fetch(snapshot: snapshot, window: window)
                        return .success(events)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let list): collected.append(contentsOf: list)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
        }
        collected.sort { $0.start < $1.start }
        events = collected
        lastRefresh = now
        lastError = failures.isEmpty ? nil : failures.joined(separator: "；")
        rebuildIndex()
        persistCache()
    }

    func clear() {
        events = []
        lastError = nil
        rebuildIndex()
        persistCache()
    }

    private func rebuildIndex() {
        var index: [String: [CalendarEvent]] = [:]
        // 假期事件用 CST 取日（与 BundledHolidayProvider 的着色日表同源），
        // 否则西部时区设备上「格子里染成补班的日期」与「抽屉里列出的日期」会差一天。
        let holidayZone = CalendarUtils.holidayCalendar.timeZone
        for event in events {
            let zone: TimeZone? = event.isHoliday ? holidayZone : nil
            var day = zone.map { CalendarUtils.startOfDay(event.start, timeZone: $0) }
                ?? CalendarUtils.startOfDay(event.start)
            let lastDay = zone.map { CalendarUtils.startOfDay(event.end.addingTimeInterval(-1), timeZone: $0) }
                ?? CalendarUtils.startOfDay(event.end.addingTimeInterval(-1))
            var guardCount = 0
            while day <= lastDay, guardCount < 400 {
                let key = zone.map { CalendarUtils.key(for: day, timeZone: $0) }
                    ?? CalendarUtils.key(for: day)
                index[key, default: []].append(event)
                day = CalendarUtils.addDays(1, to: day)
                guardCount += 1
            }
        }
        for key in index.keys {
            index[key]?.sort { $0.start < $1.start }
        }
        dayIndex = index
    }

    // MARK: - 网络

    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("webcal://") {
            text = "https://" + text.dropFirst("webcal://".count)
        }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        return URL(string: text)
    }

    nonisolated static func fetch(snapshot: SubscriptionSnapshot, window: DateInterval) async throws -> [CalendarEvent] {
        let text: String
        let range: DateInterval

        if snapshot.isHoliday {
            // 内置凭据：读包内资源，**不裁剪到「今天±N 月」**，
            // 否则回看 2023/2024 时抽屉里会空掉。全量仅 142 条，成本可忽略。
            let fileName = snapshot.url.lastPathComponent
            let source = BundledHolidaySource.allCases.first { $0.fileName == fileName }
            guard let source,
                  let url = BundledHolidayProvider.effectiveICSURL(for: source),
                  let data = try? Data(contentsOf: url) else {
                throw NSError(domain: "ICS", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "包内缺少 \(fileName)"])
            }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            // 内置数据已知覆盖 2022–2026，窗口开宽到 2020–2035 即可（142 条，内存可忽略）。
            range = DateInterval(start: CalendarUtils.date(fromKey: "20200101") ?? window.start,
                                 end: CalendarUtils.date(fromKey: "20351231") ?? window.end)
        } else {
            var request = URLRequest(url: snapshot.url)
            request.timeoutInterval = 20
            request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "ICS", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            range = window
        }
        guard !text.isEmpty else { return [] }

        // 假期数据的浮动时间按 CST 解释；用户自建订阅按设备时区。
        let parsed = ICSParser.parse(text,
                                     defaultTimeZone: snapshot.isHoliday
                                        ? CalendarUtils.holidayCalendar.timeZone
                                        : nil)
        var output: [CalendarEvent] = []
        for event in parsed {
            let occurrences = ICSParser.occurrences(of: event, in: range)
            for occurrence in occurrences {
                output.append(CalendarEvent(id: "\(snapshot.uuid.uuidString)|\(event.uid)|\(occurrence.start.timeIntervalSince1970)",
                                            subscriptionUUID: snapshot.uuid,
                                            subscriptionName: snapshot.name,
                                            colorHex: snapshot.colorHex,
                                            title: event.summary,
                                            location: event.location,
                                            start: occurrence.start,
                                            end: occurrence.end,
                                            isAllDay: event.isAllDay,
                                            isHoliday: snapshot.isHoliday))
            }
        }
        return output
    }
}
