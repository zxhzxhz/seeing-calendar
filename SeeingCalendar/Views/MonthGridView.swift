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
    /// **必须参与等值判定**：图像表住在 `ThumbnailStore`（`@Observable` 单例），
    /// 而 `EquatableView` 的短路是按**存储属性**逐项比对的 —— 父层不把这个代次传进来，
    /// 「缓存已变」这个事实就跨不过 `MonthPager` 的那道短路，格子会一直停在空图上。
    let thumbnailVersion: Int
    let availableSize: CGSize
    /// 「今天」定位脉冲高亮的日期键与代次。
    let pulseKey: String?
    let pulseID: Int
    /// 与全屏画布共享的缩放转场命名空间（iOS 18 zoom transition）。
    let zoomNamespace: Namespace.ID
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void
    /// 预计算的当月 42 个网格日期。固化为存储属性，彻底消除单次渲染评估 42 次重复算日的 O(N^2) 风暴。
    let gridDates: [Date]

    init(month: Date,
         selectedDate: Date,
         records: [String: DayRecord],
         eventsByDay: [String: [CalendarEvent]],
         holidays: [String: WorkRestStatus],
         holidayNames: [String: String],
         contentToken: Int,
         thumbnailVersion: Int,
         availableSize: CGSize,
         pulseKey: String?,
         pulseID: Int,
         zoomNamespace: Namespace.ID,
         onSelect: @escaping (Date) -> Void,
         onOpen: @escaping (Date) -> Void) {
        self.month = month
        self.selectedDate = selectedDate
        self.records = records
        self.eventsByDay = eventsByDay
        self.holidays = holidays
        self.holidayNames = holidayNames
        self.contentToken = contentToken
        self.thumbnailVersion = thumbnailVersion
        self.availableSize = availableSize
        self.pulseKey = pulseKey
        self.pulseID = pulseID
        self.zoomNamespace = zoomNamespace
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.gridDates = CalendarUtils.gridDates(forMonthContaining: month)
    }

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

    /// 本地只有两个时间戳类的点按状态，**不再持有缩略图**。
    ///
    /// 1.0.20 之前的教训：把图像表放在视图的 `@State` 里，装载结果就活在任务栈上，
    /// `.task(id:)` 一被父层指纹取消就全丢 —— 表现为冷启动空白、点一下才出现。
    /// 现在图像表是 `ThumbnailStore.images`（单例、跨视图共享、跨取消存活），
    /// 本视图只**读**不**存**。
    @State private var lastTapKey: String?
    @State private var lastTapDate: Date?

    static let spacing: CGFloat = 6
    static let weekdayHeaderHeight: CGFloat = 22
    static let minimumCellWidth: CGFloat = 28
    /// 双击判定窗口（秒）。
    static let doubleTapWindow: TimeInterval = 0.32

    private let spacing = MonthGridView.spacing
    private let weekdayHeaderHeight = MonthGridView.weekdayHeaderHeight

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

    /// 缩略图装载的触发指纹。
    ///
    /// 为什么必须带 `contentToken`：启动首帧 `RootView.bootstrap()` 还没跑完，
    /// `RootView.workspace` 为 nil → `records` 是个空字典。此时 `.task(id:)` 已经跑过一轮
    /// （每一格都无从解析），而**只要 id 不变它就不会再启动** —— 随后 `@Query` 把记录送进来、
    /// 父层指纹变了、view 也重算了，缩略图却永远停在"未加载"。
    /// 把父层那个 O(1) 指纹并进 id，数据一到就重启；已经画好的格子会被
    /// `ThumbnailLoadPolicy` 判成 `.keep`，重启本身是廉价的。
    private var token: ThumbToken {
        ThumbToken(month: CalendarUtils.key(for: CalendarUtils.startOfMonth(month)),
                   version: thumbnailVersion,
                   contentToken: contentToken)
    }

    private struct ThumbToken: Hashable {
        let month: String
        let version: Int
        let contentToken: Int
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
        // 纯字典查找：不碰 SwiftData、不做 IO。`coverSlot` 只读 `DayRecord.key` 这个存储属性。
        let thumbnail = record.map { ThumbnailStore.shared.image($0.coverSlot) } ?? nil
        return DayCellView(date: date,
                           inCurrentMonth: inMonth,
                           thumbnail: thumbnail,
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

    /// 装载缩略图：**磁盘批量补齐（单次代次推进）→ 缓冲区外才后台合成**。
    ///
    /// 本方法只负责「把 store 补齐」，图形结果不经过本方法的调用栈 ——
    /// 所以它被取消不会丢任何东西，重跑也会因为 store 已有图而立刻收敛。
    ///
    /// 为什么磁盘命中要单独批量处理：冷启动时月历上有几十格都有既存 PNG，
    /// 逐格提交会让代次跳几十下、根视图白重算几十轮。合成只发生在「这一页从未出过图」
    /// 的少数页码上，逐格异步提交没有关系。
    private func loadThumbnails() async {
        var entries: [(slot: ThumbnailSlot, page: DrawingPage)] = []
        for date in gridDates {
            let key = CalendarUtils.key(for: date)
            guard let record = records[key], let page = record.coverPage else { continue }
            let slot = record.coverSlot
            if ThumbnailStore.shared.image(slot) != nil { continue }
            entries.append((slot, page))
        }
        let misses = ThumbnailStore.shared.primeFromDisk(entries)
        for (slot, page) in misses {
            if Task.isCancelled { return }
            await ThumbnailStore.shared.load(slot, page: page)
        }
    }
}
