import Foundation
import Observation

/// 节假日 / 调休数据源协议。
/// 架构上与 UI 完全解耦：当前仅保留纯协议抽象与 UI 锚点，业务数据可由动态配置注入。
protocol HolidayProviderProtocol: Sendable {
    func fetchHolidaySchedule(year: Int, month: Int) async throws -> [Date: WorkRestStatus]
    func queryStatus(for date: Date) -> WorkRestStatus
}

/// 占位实现：无远端逻辑，恒返回空状态，可随时替换为远程 API Provider。
struct DeferredHolidayManager: HolidayProviderProtocol {
    static let shared = DeferredHolidayManager()

    func fetchHolidaySchedule(year: Int, month: Int) async throws -> [Date: WorkRestStatus] {
        [:]
    }

    func queryStatus(for date: Date) -> WorkRestStatus {
        .normal
    }
}

/// 注入点：内存表覆盖实现（供动态配置 / 远端下发直接写入）。
///
/// 本表是月历格的**唯一**着色依据：日格只做一次 O(1) 字典查询，
/// 因此翻月滑动时不会因为「按月拉取」而产生任何额外开销。
@MainActor
@Observable
final class HolidayRegistry {
    static let shared = HolidayRegistry()

    private(set) var statuses: [String: WorkRestStatus] = [:]
    private(set) var names: [String: String] = [:]
    /// 每次内容变化自增，供视图层做 O(1) 的失效判断（避免比较整张字典）。
    private(set) var version: Int = 0
    private var provider: any HolidayProviderProtocol = DeferredHolidayManager.shared

    func install(provider: any HolidayProviderProtocol) {
        self.provider = provider
    }

    /// 由订阅开关状态整体重算日表。
    /// - 两条内置凭据（放假 / 调休）互相独立，开关哪一个就只影响哪一张表；
    /// - 补班在最后合入，因此「本该上班」的调休日不会被放假表覆盖。
    func rebuild(offDayEnabled: Bool, makeUpWorkEnabled: Bool) {
        let source = BundledHolidayProvider.shared
        source.ensureLoaded()
        var merged: [String: WorkRestStatus] = offDayEnabled ? source.table(for: .offDay).statuses : [:]
        var labels: [String: String] = offDayEnabled ? source.table(for: .offDay).names : [:]
        if makeUpWorkEnabled {
            for (key, status) in source.table(for: .makeUpWork).statuses { merged[key] = status }
        }
        statuses = merged
        names = labels
        version &+= 1
    }

    /// 兼容入口：把按月调度结果合并进内存表。
    func apply(schedule: [Date: WorkRestStatus]) {
        var updated = statuses
        for (date, status) in schedule {
            updated[CalendarUtils.key(for: date)] = status
        }
        statuses = updated
        version &+= 1
    }

    func status(for date: Date) -> WorkRestStatus {
        statuses[CalendarUtils.key(for: date)] ?? provider.queryStatus(for: date)
    }

    /// 节日名（如「国庆节」），无则 nil。
    func name(for date: Date) -> String? {
        names[CalendarUtils.key(for: date)]
    }
}
