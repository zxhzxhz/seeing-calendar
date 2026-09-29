import SwiftUI

/// 7×6 月历矩阵：固定 42 格，单元格严格 1:1，宽度自适应决定 LOD 分级。
struct MonthGridView: View {
    let month: Date
    let selectedDate: Date
    let records: [String: DayRecord]
    let eventsByDay: [String: [CalendarEvent]]
    let holidays: [String: WorkRestStatus]
    let availableSize: CGSize
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void

    @State private var thumbnails: [String: UIImage] = [:]

    static let spacing: CGFloat = 6
    static let weekdayHeaderHeight: CGFloat = 22
    static let minimumCellWidth: CGFloat = 28

    private let spacing = MonthGridView.spacing
    private let weekdayHeaderHeight = MonthGridView.weekdayHeaderHeight

    private var gridDates: [Date] { CalendarUtils.gridDates(forMonthContaining: month) }

    /// 单格 1:1 边长：取「横向可用宽」与「纵向可用高」的较小者。
    static func cellWidth(availableSize: CGSize) -> CGFloat {
        let byWidth = (availableSize.width - spacing * 6) / 7
        let byHeight = (availableSize.height - spacing * 5 - weekdayHeaderHeight) / 6
        return max(minimumCellWidth, floor(min(byWidth, byHeight)))
    }

    /// 整块月历（含星期表头）的高度。
    static func gridHeight(cellWidth: CGFloat) -> CGFloat {
        cellWidth * 6 + spacing * 5 + weekdayHeaderHeight
    }

    private var cellWidth: CGFloat {
        MonthGridView.cellWidth(availableSize: availableSize)
    }

    private var tier: CellLODTier { CellLODTier.resolve(for: cellWidth) }

    var body: some View {
        VStack(spacing: spacing) {
            weekdayHeader
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column
                        let date = gridDates[index]
                        cell(for: date)
                    }
                }
            }
        }
        .frame(width: cellWidth * 7 + spacing * 6,
               height: cellWidth * 6 + spacing * 5 + weekdayHeaderHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: token) {
            await loadThumbnails()
        }
    }

    private var token: ThumbToken {
        ThumbToken(month: CalendarUtils.key(for: CalendarUtils.startOfMonth(month)),
                   version: ThumbnailStore.shared.version)
    }

    private struct ThumbToken: Hashable {
        let month: String
        let version: Int
    }

    private var weekdayHeader: some View {
        HStack(spacing: spacing) {
            ForEach(CalendarUtils.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: cellWidth, height: weekdayHeaderHeight - spacing)
            }
        }
        .frame(height: weekdayHeaderHeight)
    }

    private func cell(for date: Date) -> some View {
        let key = CalendarUtils.key(for: date)
        let record = records[key]
        let inMonth = CalendarUtils.month(of: date) == CalendarUtils.month(of: month)
        return DayCellView(date: date,
                           inCurrentMonth: inMonth,
                           thumbnail: thumbnails[key],
                           pageCount: record?.pages.count ?? 0,
                           events: eventsByDay[key] ?? [],
                           holiday: holidays[key] ?? .normal,
                           isSelected: CalendarUtils.isSameDay(date, selectedDate),
                           tier: tier)
            .frame(width: cellWidth, height: cellWidth)
            .onTapGesture(count: 2) { onOpen(date) }
            .onTapGesture { onSelect(date) }
            .accessibilityLabel(CalendarUtils.dayTitle(date))
    }

    private func loadThumbnails() async {
        var result: [String: UIImage] = [:]
        for date in gridDates {
            let key = CalendarUtils.key(for: date)
            guard let page = records[key]?.coverPage else { continue }
            if let image = await ThumbnailStore.shared.thumbnail(for: page) {
                result[key] = image
            }
        }
        thumbnails = result
    }
}
