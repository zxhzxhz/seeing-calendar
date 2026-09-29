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

/// 注入点：内存表覆盖实现（供后续动态配置 / 远端下发直接写入）。
@MainActor
@Observable
final class HolidayRegistry {
    static let shared = HolidayRegistry()

    private(set) var statuses: [String: WorkRestStatus] = [:]
    private var provider: any HolidayProviderProtocol = DeferredHolidayManager.shared

    func install(provider: any HolidayProviderProtocol) {
        self.provider = provider
    }

    func apply(schedule: [Date: WorkRestStatus]) {
        var updated = statuses
        for (date, status) in schedule {
            updated[CalendarUtils.key(for: date)] = status
        }
        statuses = updated
    }

    func status(for date: Date) -> WorkRestStatus {
        if let value = statuses[CalendarUtils.key(for: date)] { return value }
        return provider.queryStatus(for: date)
    }
}
