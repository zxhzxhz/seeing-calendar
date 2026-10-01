import SwiftUI

/// 7×6 月历矩阵：固定 42 格，单元格严格 1:1，宽度自适应决定 LOD 分级。
///
/// 性能约定（真机实测：点选日期曾有十分明显的延迟）：
/// ① 单元格的输入不含「是否选中」——选中环由本视图单独一层绘制，点选时 126 个格子无需重算；
/// ② 页数取自 `DayRecord.pageCount` 冗余字段，渲染路径上不触碰 SwiftData 关系（避免 fault）；
/// ③ 单击/双击由本视图自己做时间判定，不再依赖 SwiftUI 单/双击手势仲裁（否则单击要等 ~300ms）。
/// ④ 本视图遵循 `Equatable` 且比较是 O(1)：翻月滑动时由父层的 `EquatableView` 整体短路，
///    126 个日格的 body 一次都不会重跑。
struct MonthGridView: View, Equatable {
    let month: Date
    let selectedDate: Date
    let records: [String: DayRecord]
    let eventsByDay: [String: [CalendarEvent]]
    let holidays: [String: WorkRestStatus]
    /// 日期键 → 节日名（`国庆节`），仅放假日有值。
    let holidayNames: [String: String]
    /// 父层预计算的内容指纹（已含日记录 / 事件 / 假期 / 缩略图版本）。
    let contentToken: Int
    /// 缩略图内容代次（`ThumbnailStore.shared.version`，由父层读出传入）。
    ///
    /// **必须参与等值判定**：缩略图渲染结果存在本视图的 `@State` 里，父层看不到，
    /// 「缓存已补齐」这件事只能靠这个代次传进来。若它不参与比较，`EquatableView`
    /// 短路会把补齐所需的那次重算直接吃掉 —— 格子就一直停在空图上（1.0.18 的 bug）。
    let thumbnailVersion: Int
    let availableSize: CGSize
    /// 「今天」定位脉冲高亮的日期键与代次。
    let pulseKey: String?
    let pulseID: Int
    /// 与全屏画布共享的缩放转场命名空间（iOS 18 zoom transition）。
    let zoomNamespace: Namespace.ID
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void

    /// O(1) 等价判定。
    ///
    /// 刻意不比 `records` / `eventsByDay` / `holidays`：`DayRecord` 是类、非 `Equatable`，
    /// 字典逐项比较也是 O(n)；而这些内容的任何变化都会反映在父层给的 `contentToken` 里。
    /// 闭包与 `zoomNamespace` 同理不参与比较（前者每次重建，后者生命周期内恒定）。
    /// `pulseKey` / `pulseID` 必须参与：脉冲环 900ms 后要把 `pulseKey` 置回 nil 来收尾，
    /// 只比 `pulseID` 会让环永远留在格子上。
    nonisolated static func == (lhs: MonthGridView, rhs: MonthGridView) -> Bool {
        lhs.contentToken == rhs.contentToken
            && lhs.month == rhs.month
            && lhs.selectedDate == rhs.selectedDate
            && lhs.availableSize == rhs.availableSize
            && lhs.pulseID == rhs.pulseID
            && lhs.pulseKey == rhs.pulseKey
            && lhs.thumbnailVersion == rhs.thumbnailVersion
    }

    @State private var thumbnails: [String: UIImage] = [:]
    /// 本地表是按哪个内容代次校验过的。
    @State private var loadedVersion: Int = -1
    @State private var lastTapKey: String?
    @State private var lastTapDate: Date?

    static let spacing: CGFloat = 6
    static let weekdayHeaderHeight: CGFloat = 22
    static let minimumCellWidth: CGFloat = 28
    /// 双击判定窗口（秒）。
    static let doubleTapWindow: TimeInterval = 0.32

    private let spacing = MonthGridView.spacing
    private let weekdayHeaderHeight = MonthGridView.weekdayHeaderHeight

    private var gridDates: [Date] { CalendarUtils.gridDates(forMonthContaining: month) }

    /// 单格 1:1 边长：取「横向可用宽」与「纵向可用高」的较小者。
    static func cellWidth(availableSize: CGSize) -> CGFloat {
        let byWidth = (availableSize.width - spacing * 6) / 7
        let byHeight = (availableSize.height - spacing * 6 - weekdayHeaderHeight) / 6
        return max(minimumCellWidth, floor(min(byWidth, byHeight)))
    }

    /// 整块月历高度：7 行（1 行表头 + 6 行日期）之间的 6 道间距。
    static func gridHeight(cellWidth: CGFloat) -> CGFloat {
        cellWidth * 6 + spacing * 6 + weekdayHeaderHeight
    }

    private var cellWidth: CGFloat {
        MonthGridView.cellWidth(availableSize: availableSize)
    }

    private var tier: CellLODTier { CellLODTier.resolve(for: cellWidth) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: spacing) {
                weekdayHeader
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { column in
                            let index = row * 7 + column
                            cell(for: gridDates[index])
                        }
                    }
                }
            }
            selectionRing
        }
        .frame(width: cellWidth * 7 + spacing * 6,
               height: MonthGridView.gridHeight(cellWidth: cellWidth))
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: token) {
            await loadThumbnails()
        }
    }

    private var token: ThumbToken {
        ThumbToken(month: CalendarUtils.key(for: CalendarUtils.startOfMonth(month)),
                   version: thumbnailVersion)
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
                    .frame(width: cellWidth, height: weekdayHeaderHeight)
            }
        }
        .frame(height: weekdayHeaderHeight)
    }

    /// 选中环：独立一层，位置由选中日期算出，不改变任何格子的输入。
    @ViewBuilder
    private var selectionRing: some View {
        if let index = gridDates.firstIndex(where: { CalendarUtils.isSameDay($0, selectedDate) }) {
            let row = index / 7
            let column = index % 7
            RoundedRectangle(cornerRadius: tier == .lod1Minimal ? 4 : 7, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .frame(width: cellWidth, height: cellWidth)
                .offset(x: CGFloat(column) * (cellWidth + spacing),
                        y: weekdayHeaderHeight + spacing + CGFloat(row) * (cellWidth + spacing))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func cell(for date: Date) -> some View {
        let key = CalendarUtils.key(for: date)
        let record = records[key]
        let inMonth = CalendarUtils.month(of: date) == CalendarUtils.month(of: month)
        // 内置假期事件不画胶囊（班休样式 + 节日名角标已经表达了它），避免与手绘争焦点。
        let capsuleEvents = (eventsByDay[key] ?? []).filter { !$0.isHoliday }
        return DayCellView(date: date,
                           inCurrentMonth: inMonth,
                           thumbnail: thumbnails[key],
                           pageCount: record?.pageCount ?? 0,   // 冗余字段，不触发关系 fault
                           events: capsuleEvents,
                           holiday: holidays[key] ?? .normal,
                           holidayName: holidayNames[key],
                           isPulsing: pulseKey == key,
                           pulseID: pulseID,
                           tier: tier)
            .frame(width: cellWidth, height: cellWidth)
            .matchedTransitionSource(id: transitionID(for: key), in: zoomNamespace)
            .onTapGesture { handleTap(date: date, key: key) }
            .accessibilityLabel(CalendarUtils.dayTitle(date))
    }

    /// 自行判定单击/双击：单击立即生效（不再等待系统双击超时），双击进入画布。
    private func handleTap(date: Date, key: String) {
        let now = Date()
        if let lastKey = lastTapKey, lastKey == key,
           let lastDate = lastTapDate, now.timeIntervalSince(lastDate) < Self.doubleTapWindow {
            lastTapKey = nil
            lastTapDate = nil
            onOpen(date)
            return
        }
        lastTapKey = key
        lastTapDate = now
        onSelect(date)
    }

    /// 转场源 ID 必须全局唯一：相邻月份的网格会包含同一天，
    /// 因此用「当前月键|日期键」组合，避免同屏出现重复 source。
    private func transitionID(for key: String) -> String {
        "\(CalendarUtils.key(for: CalendarUtils.startOfMonth(month)))|\(key)"
    }

    /// 装载缩略图：**分批增量提交，绝不整表覆盖**。
    ///
    /// 旧实现最后一句 `thumbnails = result` 是这个 bug 的另一半原因：
    /// 只要某一格在本次结果里缺失（并发合并抢输、封面关系读空），本来已经显示着的图
    /// 就会被一起抹掉；而 `records` 是整个工作区的全量字典、`coverPage` 又是延迟加载关系，
    /// 「缺失」并不是异常状态。现在缺失只会让该格保持原样，其它格的更新照常落地。
    private func loadThumbnails() async {
        let versionChanged = loadedVersion != thumbnailVersion
        var resolved: [String: UIImage] = [:]
        var dropped: Set<String> = []
        var pending = 0

        func flush() {
            guard !resolved.isEmpty || !dropped.isEmpty else { return }
            ThumbnailLoadPolicy.merge(&thumbnails, resolved: resolved, dropped: dropped)
            resolved.removeAll()
            dropped.removeAll()
            pending = 0
        }

        for date in gridDates {
            if Task.isCancelled { flush(); return }
            let key = CalendarUtils.key(for: date)
            let page = records[key]?.coverPage
            switch ThumbnailLoadPolicy.resolution(hasImage: thumbnails[key] != nil,
                                                  versionChanged: versionChanged,
                                                  coverExists: page != nil) {
            case .keep:
                continue
            case .drop:
                dropped.insert(key)
            case .resolve:
                guard let page else { continue }
                // 同页并发在 store 内部合并：两个月的网格同时要 9/30 时两边都拿得到图。
                guard let image = await ThumbnailStore.shared.thumbnail(for: page) else { continue }
                resolved[key] = image
            }
            pending += 1
            if pending >= ThumbnailLoadPolicy.batchSize { flush() }
        }
        flush()
        loadedVersion = thumbnailVersion
    }
}
