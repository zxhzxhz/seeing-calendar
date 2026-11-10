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
    /// 作用域：**空 = 全局**（与 `SubscriptionScope` 同一约定）。
    let scope: [UUID]
    /// 内置节假日凭据：读包内资源（不走网络）、覆盖全部年份、且不画日格胶囊。
    let isHoliday: Bool
}

/// 一趟刷新在后台得到的结论。
///
/// **Sendable 值类型**：只装代次 / 事件数组 / 逐订阅错误，**绝不装 SwiftData 模型对象**
/// （`ICSSubscription` 非 Sendable，不能跨隔离域）。
/// `generation` 让落地侧能执行代次纪律；逐订阅失败以 `UUID → 信息` 的字典返回，
/// 模型上的 `lastFetched` / `lastError` 写回留给 MainActor 侧完成。
struct RefreshOutcome: Sendable {
    let generation: Int
    let events: [CalendarEvent]
    let subscriptionErrors: [UUID: String]
}

/// ICS 订阅聚合与按日索引。所有网络与解析都在非主线程完成，主线程只做索引与展示。
@MainActor
@Observable
final class CalendarEventStore {
    private(set) var events: [CalendarEvent] = []

    /// 刷新生命周期的**单一真值**。
    ///
    /// 旧实现用三个隐式旗标拼出这套状态（存储式刷新旗标、时间谓词式新鲜度、
    /// 混装失败信息），并发时会互相拆台；相位机把它们收拢成一个显式枚举，
    /// 写入口只有 `emit(_:)`。
    private(set) var phase: RefreshPhase = .idle

    /// 界面上的「刷新中」—— `phase` 的只读投影。
    /// 所有既有调用点（RootView 的进度圈）零改动、行为不变。
    var isRefreshing: Bool { phase.isRefreshing }

    /// 失败信息（全局）—— `phase` 的只读投影。
    var lastError: String? { phase.failureMessage }

    /// 上次成功刷新时刻 —— 由 `.coolingDown(until:)` 反推为 `until - cooldown`。
    /// 冷却窗口是**状态**，这里只是把它投影回旧调用点认识的形状。
    var lastRefresh: Date? {
        if case .coolingDown(let until, _) = phase {
            return until.addingTimeInterval(-RefreshPolicy.cooldown)
        }
        return nil
    }

    /// 当前活跃刷新的代次。每次真正开新一趟都推进它，迟到的结论据此被丢弃。
    private var refreshGeneration = 0

    /// 在途合并用的句柄：已有一趟非强制的刷新在飞时，后来的调用直接等它，
    /// 不重复跑同一批网络请求。
    private var inflight: Task<RefreshOutcome, Never>?

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
                                                scope: subscription.workspaceUUIDs,
                                                isHoliday: true)
                }
                guard let url = CalendarEventStore.normalizedURL(subscription.urlString) else { return nil }
                return SubscriptionSnapshot(uuid: subscription.uuid,
                                            name: subscription.name,
                                            colorHex: subscription.colorHex,
                                            url: url,
                                            scope: subscription.workspaceUUIDs,
                                            isHoliday: false)
            }

        guard !snapshots.isEmpty else {
            events = []
            rebuildIndex()
            return
        }

        let now = Date()
        // 冷却窗口是状态，不再每次现算 —— 逐位保留旧的「!force && 窗口内 && 有事件」。
        if RefreshPolicy.shouldSkip(phase: phase, now: now,
                                    force: force, hasEvents: !events.isEmpty) {
            return
        }

        // 在途合并：已有一趟在飞且本次非强制 → 等它的结论，不重复跑同一批网络请求。
        // 强制刷新则照常开新一趟并推进代次 —— 旧那趟的结论由代次纪律丢弃。
        if !force, let inflight {
            await inflight.value
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let startedAt = now
        emit(.began(startedAt: startedAt, generation: generation))

        let window = DateInterval(start: CalendarUtils.addMonths(-2, to: now),
                                 end: CalendarUtils.addMonths(4, to: now))

        // Swift 6 并发纪律：`Task` 闭包只捕获 Sendable 值
        // （snapshots / window / generation），绝不捕获 `[ICSSubscription]`
        // （SwiftData 模型非 Sendable）。逐订阅的簿记回到 MainActor 侧、
        // 在 `await` 之后用 `subscriptions` 数组完成。
        let task = Task<RefreshOutcome, Never> { [snapshots, window, generation] in
            var collected: [CalendarEvent] = []
            var errors: [UUID: String] = [:]
            await withTaskGroup(of: (UUID, Result<[CalendarEvent], Error>).self) { group in
                for snapshot in snapshots {
                    group.addTask {
                        do {
                            let list = try await CalendarEventStore.fetch(snapshot: snapshot, window: window)
                            return (snapshot.uuid, .success(list))
                        } catch {
                            return (snapshot.uuid, .failure(error))
                        }
                    }
                }
                for await (uuid, result) in group {
                    switch result {
                    case .success(let list): collected.append(contentsOf: list)
                    case .failure(let error): errors[uuid] = error.localizedDescription
                    }
                }
            }
            collected.sort { $0.start < $1.start }
            return RefreshOutcome(generation: generation, events: collected, subscriptionErrors: errors)
        }
        inflight = task
        let outcome = await task.value

        // 结果落地前必须过代次纪律：迟到的结论直接丢弃，
        // 绝不把新结果覆盖回旧结果，也不熄火掉仍在飞行的那一趟。
        guard RefreshPolicy.accepts(generation: outcome.generation, latest: refreshGeneration) else {
            return
        }
        inflight = nil

        events = outcome.events
        let newIndex = await Task.detached { CalendarEventStore.buildIndex(from: outcome.events) }.value
        dayIndex = newIndex
        persistCache()

        // 逐订阅簿记：网络阶段只处理 snapshots，模型写回在 MainActor 侧完成。
        for snapshot in snapshots {
            guard let subscription = subscriptions.first(where: { $0.uuid == snapshot.uuid }) else { continue }
            if let message = outcome.subscriptionErrors[snapshot.uuid] {
                subscription.lastError = message
            } else {
                subscription.lastFetched = startedAt
                subscription.lastError = nil
            }
        }

        let failures = snapshots.compactMap { outcome.subscriptionErrors[$0.uuid] }
        if failures.isEmpty {
            emit(.succeeded(at: startedAt, generation: outcome.generation))
        } else {
            emit(.failed(message: failures.joined(separator: "；"),
                         at: startedAt, generation: outcome.generation))
        }
    }

    /// 唯一的刷新相位写入点。
    ///
    /// 事件自带的代次早于 `refreshGeneration` 时，`reduce` 会原样返回旧相位 ——
    /// 不写、不清、不熄火。这就是「先返回者提前熄火」的修法。
    private func emit(_ event: RefreshEvent) {
        phase = RefreshPolicy.reduce(phase, event: event, latestGeneration: refreshGeneration)
    }

    func clear() {
        events = []
        emit(.cleared)
        rebuildIndex()
        persistCache()
    }

    private func rebuildIndex() {
        dayIndex = Self.buildIndex(from: events)
    }

    nonisolated static func buildIndex(from events: [CalendarEvent]) -> [String: [CalendarEvent]] {
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
        return index
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
                                            isHoliday: snapshot.isHoliday,
                                            scope: snapshot.scope))
            }
        }
        return output
    }
}
