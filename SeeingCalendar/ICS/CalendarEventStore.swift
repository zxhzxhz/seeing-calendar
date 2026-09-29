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
                guard let url = CalendarEventStore.normalizedURL(subscription.urlString) else { return nil }
                return SubscriptionSnapshot(uuid: subscription.uuid,
                                            name: subscription.name,
                                            colorHex: subscription.colorHex,
                                            url: url,
                                            workspaceUUID: subscription.workspaceUUID)
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
        for event in events {
            var day = CalendarUtils.startOfDay(event.start)
            let lastDay = CalendarUtils.startOfDay(event.end.addingTimeInterval(-1))
            var guardCount = 0
            while day <= lastDay, guardCount < 400 {
                index[CalendarUtils.key(for: day), default: []].append(event)
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
        var request = URLRequest(url: snapshot.url)
        request.timeoutInterval = 20
        request.setValue("text/calendar, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "ICS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return [] }

        let parsed = ICSParser.parse(text)
        var output: [CalendarEvent] = []
        for event in parsed {
            let occurrences = ICSParser.occurrences(of: event, in: window)
            for occurrence in occurrences {
                output.append(CalendarEvent(id: "\(snapshot.uuid.uuidString)|\(event.uid)|\(occurrence.start.timeIntervalSince1970)",
                                            subscriptionUUID: snapshot.uuid,
                                            subscriptionName: snapshot.name,
                                            colorHex: snapshot.colorHex,
                                            title: event.summary,
                                            location: event.location,
                                            start: occurrence.start,
                                            end: occurrence.end,
                                            isAllDay: event.isAllDay))
            }
        }
        return output
    }
}
