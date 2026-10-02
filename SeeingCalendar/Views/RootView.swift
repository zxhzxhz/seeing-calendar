import SwiftData
import SwiftUI

struct EditorRequest: Identifiable {
    let day: DayRecord
    let pageIndex: Int
    /// 与 MonthGridView 的 `matchedTransitionSource` 一一对应（当前月键|日期键）。
    let sourceID: String
    var id: String { "\(day.key)-\(pageIndex)" }
}

/// 主界面：顶栏导航 + 1:1 月历矩阵（左右滑动翻月）；竖屏附加动态扩展区。
struct RootView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Workspace.sortIndex) private var workspaces: [Workspace]
    @Query private var allDays: [DayRecord]
    @Query(sort: \ICSSubscription.createdAt) private var subscriptions: [ICSSubscription]

    @AppStorage("fingerDrawingEnabled") private var fingerDrawingEnabled = false
    @AppStorage("lastAutoSnapshot") private var lastAutoSnapshot: Double = 0

    @Namespace private var zoomNamespace

    @State private var selectedWorkspaceUUID: UUID?
    @State private var month: Date = CalendarUtils.startOfMonth(Date())
    @State private var selectedDate: Date = Date()
    @State private var editorRequest: EditorRequest?
    @State private var eventStore = CalendarEventStore()
    @State private var backup = BackupCoordinator()
    @State private var holidayRegistry = HolidayRegistry.shared
    @State private var showSubscriptions = false
    @State private var showBackup = false
    @State private var showRestoreDialog = false
    /// 顶栏年月处的月份选择下拉面板是否展开。
    @State private var showMonthPicker = false
    @State private var toast: String?

    // 翻月手势状态（刻意不放在 RootView 的 @State 里，见 MonthPagerState 的注释）
    @State private var pager = MonthPagerState()
    // 「今天」定位脉冲
    @State private var pulseKey: String?
    @State private var pulseToken: Int = 0

    private var repository: PageRepository { PageRepository(context: context) }

    private var workspace: Workspace? {
        if let selectedWorkspaceUUID, let match = workspaces.first(where: { $0.uuid == selectedWorkspaceUUID }) {
            return match
        }
        return workspaces.first
    }

    private var dayRecords: [String: DayRecord] {
        guard let workspace else { return [:] }
        var result: [String: DayRecord] = [:]
        for day in allDays where day.workspaceUUID == workspace.uuid {
            result[day.dateKey] = day
        }
        return result
    }

    private var selectedRecord: DayRecord? {
        dayRecords[CalendarUtils.key(for: selectedDate)]
    }

    var body: some View {
        GeometryReader { proxy in
            let isPortrait = DeviceLayout.isPortrait
            VStack(spacing: 0) {
                headerBar(containerWidth: proxy.size.width)
                Divider()
                if isPortrait {
                    portraitLayout(width: proxy.size.width)
                } else {
                    landscapeLayout(width: proxy.size.width)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        // 月份选择下拉：先铺一层透明收口层（点面板以外任意处关闭），
        // 再在它上面挂面板 —— 后挂的在上层，所以面板点得到。
        .overlay { monthPickerDismissLayer }
        .overlay(alignment: .topLeading) {
            monthPickerLayer
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showMonthPicker)
        }
        .task { await bootstrap() }
        .onChange(of: subscriptions.map(\.urlString)) { _, _ in
            Task { await eventStore.refresh(subscriptions: subscriptions, force: true) }
        }
        // 订阅开关 / 启用状态变化 → 重建班休日表（只影响 O(1) 字典，不重建子树）。
        .onChange(of: subscriptions.map { "\($0.uuid.uuidString):\($0.isEnabled)" }) { _, _ in
            rebuildHolidays()
        }
        .onOpenURL { url in
            Task { await handleIncoming(url: url) }
        }
        // 画布编辑器整屏打开，并以被点选的日格作为缩放转场起点（iOS 18 zoom transition）。
        .fullScreenCover(item: $editorRequest) { request in
            DayEditorView(day: request.day,
                          workspace: workspace ?? request.day.workspace ?? repository.ensureDefaultWorkspace(),
                          context: context,
                          initialPageIndex: request.pageIndex,
                          isFingerDrawingEnabled: fingerDrawingEnabled,
                          onFingerDrawingChanged: { fingerDrawingEnabled = $0 })
                .navigationTransition(.zoom(sourceID: request.sourceID, in: zoomNamespace))
        }
        .sheet(isPresented: $showSubscriptions) {
            SubscriptionsView(eventStore: eventStore) {
                selectedWorkspaceUUID = workspaces.first?.uuid
            }
        }
        .sheet(isPresented: $showBackup) {
            BackupView(coordinator: backup)
        }
        .confirmationDialog("检测到 .vcal 归档，选择恢复策略", isPresented: $showRestoreDialog, titleVisibility: .visible) {
            ForEach(RestoreMode.allCases) { mode in
                Button(mode.title) { applyRestore(mode) }
            }
            Button("取消", role: .cancel) { backup.clearPendingRestore() }
        } message: {
            Text("完整覆写会清空当前库；智能增量合并会保留当前数据并把同日冲突的备份画作转为后置拓展页。")
        }
        .alert("提示", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
            Button("好", role: .cancel) { toast = nil }
        } message: {
            Text(toast ?? "")
        }
    }

    // MARK: - 布局

    private func portraitLayout(width: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                monthPager(availableSize: CGSize(width: width - 24, height: 1_000_000),
                           containerWidth: width)
                    .padding(.vertical, 10)
                Divider()
                ContextDrawerView(date: selectedDate,
                                  record: selectedRecord,
                                  events: eventStore.events(on: selectedDate),
                                  onOpenPage: { pageIndex in openDay(selectedDate, pageIndex: pageIndex) },
                                  onNoteCommit: { text in
                                      let target = workspace ?? repository.ensureDefaultWorkspace()
                                      guard let record = selectedRecord ?? repository.day(for: selectedDate, workspace: target, create: true) else { return }
                                      repository.updateNote(text, for: record)
                                  })
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    /// 横屏：月历在可视区里居中铺满，下方不留抽屉（抽屉只在竖屏出现）。
    ///
    /// **为什么高度要在这一层重新量一次**：容器高度会被键盘压缩
    /// （见 `DeviceLayout.isPortrait` 的注释 —— 这是本项目已经踩过一次的坑）。
    /// 而横屏主屏上根本没有任何可输入控件（便签抽屉只在竖屏渲染），键盘跟主屏毫无关系，
    /// 却会把外层 `proxy.size.height` 压掉，而横屏网格尺寸正是由这个高度算出来的
    /// —— 于是「在新建维度 / 新增日历的输入框里唤起键盘」时，主屏日历格子跟着缩。
    /// 修法：让这一层**忽略键盘安全区**并在此重新量高度，量到的就是键盘弹出前的真实高度。
    ///
    /// 刻意不在根部忽略键盘：竖屏的便签输入框依赖键盘避让把光标顶到可见区，
    /// 根部一旦忽略，竖屏就会退化成「键盘盖住输入框」。
    private func landscapeLayout(width: CGFloat) -> some View {
        GeometryReader { proxy in
            monthPager(availableSize: CGSize(width: width - 28, height: proxy.size.height - 120),
                       containerWidth: width)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // MARK: - 月历 + 左右滑动翻月（上/下月常驻预渲染）

    private func monthPager(availableSize: CGSize, containerWidth: CGFloat) -> some View {
        MonthPager(month: month,
                   selectedDate: selectedDate,
                   records: dayRecords,
                   eventsByDay: pagedEvents,
                   holidays: holidayRegistry.statuses,
                   holidayNames: holidayRegistry.names,
                   contentToken: monthContentToken,
                   thumbnailVersion: ThumbnailStore.shared.version,
                   availableSize: availableSize,
                   containerWidth: containerWidth,
                   pulseKey: pulseKey,
                   pulseID: pulseToken,
                   zoomNamespace: zoomNamespace,
                   state: pager,
                   onSelect: { date in
                       // 只更新选中日期：点中非本月日格也**不切换月视图**，
                       // 画布就在本页弹出（spec 交互诉求）。
                       selectedDate = date
                   },
                   onOpen: { date in openDay(date, pageIndex: 0) },
                   onMonthChange: { delta in
                       month = CalendarUtils.addMonths(delta, to: month)
                   })
    }

    // MARK: - 月份选择下拉面板

    /// 面板本体（挂在 `overlay(alignment: .topLeading)` 里，落在顶栏年月正下方）。
    @ViewBuilder
    private var monthPickerLayer: some View {
        if showMonthPicker {
            MonthPickerPanel(month: month, onPick: { target in pickMonth(target) })
                .padding(.leading, 16)
                .padding(.top, 52)
                .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
        }
    }

    /// 透明收口层：点面板以外任意处关闭（下拉菜单的常规语义）。
    ///
    /// 它是独立一层、挂在面板**下面**（`overlay` 后挂的在上层），
    /// 因此面板自己的点击不会被它吃掉。
    @ViewBuilder
    private var monthPickerDismissLayer: some View {
        if showMonthPicker {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { showMonthPicker = false }
        }
    }

    /// 三个可见月的网格日期（当月 ±1）上预建的事件索引。
    ///
    /// 只在 `RootView.body` 里算一次，翻页手势期间不再重算（手势状态不在 RootView 里）。
    private var pagedEvents: [String: [CalendarEvent]] {
        var index: [String: [CalendarEvent]] = [:]
        for delta in [-1, 0, 1] {
            for date in CalendarUtils.gridDates(forMonthContaining: CalendarUtils.addMonths(delta, to: month)) {
                let key = CalendarUtils.key(for: date)
                let events = eventStore.events(onDayKey: key).filter { !$0.isHoliday }
                if !events.isEmpty { index[key] = events }
            }
        }
        return index
    }

    /// O(1) 判定用的内容指纹：把「会影响月历外观的所有输入」压成一个整数。
    ///
    /// 为什么需要：`MonthGridView` 遵循 `Equatable`，翻月滑动时父层要把 126 个日格
    /// 整体短路掉。但 `DayRecord` 是引用类型、字典逐项比较是 O(n)，直接比较会让短路失效。
    /// 于是这里预扫一遍（约 126 次 O(1) 哈希查找，微秒级，且**只在 RootView.body 里发生一次**），
    /// 任何绘制相关输入变化都会让指纹自增 —— 视图侧就只需比一个 Int。
    private var monthContentToken: Int {
        var token = 0
        for record in dayRecords.values {
            token = token &* 31 &+ Int(record.updatedAt.timeIntervalSince1970 * 1_000) &+ record.pageCount
        }
        for events in pagedEvents.values {
            token = token &* 31 &+ events.count
        }
        token = token &* 31 &+ holidayRegistry.version
        token = token &* 31 &+ pagedEvents.count
        return token
    }

    // MARK: - 顶栏

    private func headerBar(containerWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button {
                    shiftMonth(-1, containerWidth: containerWidth)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("上个月")

                // 年月标题即月份选择器的入口（Drop Menu）：点一下弹出 3×4 月份面板。
                // 两侧的单箭头仍然是「前后各一月」的翻月按钮，两者不冲突。
                //
                // 标题旁边**不放**下拉小箭头：标题本身就是那唯一的东西，再挂一枚箭头
                // 只是陈述「这里能点」，而箭头又会随展开状态翻转，视觉噪音大于信息量。
                Button {
                    showMonthPicker.toggle()
                } label: {
                    Text(CalendarUtils.title(forMonth: month))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 118, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择月份")
                .accessibilityValue(CalendarUtils.title(forMonth: month))

                Button {
                    shiftMonth(1, containerWidth: containerWidth)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("下个月")
            }

            Button("今天") {
                goToToday(containerWidth: containerWidth)
            }
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.bordered)
            .controlSize(.small)

            if eventStore.isRefreshing {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 8)

            workspaceMenu

            Button {
                fingerDrawingEnabled.toggle()
            } label: {
                Image(systemName: fingerDrawingEnabled ? "hand.draw.fill" : "hand.draw")
                    .font(.system(size: 16))
                    .foregroundStyle(fingerDrawingEnabled ? Color.accentColor : .primary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(fingerDrawingEnabled ? Color.accentColor.opacity(0.15) : .clear)
                    )
            }
            .accessibilityLabel("手指书写开关")

            Button {
                showSubscriptions = true
            } label: {
                Image(systemName: "calendar.badge.plus").font(.system(size: 16))
            }
            .accessibilityLabel("订阅与维度")

            Button {
                showBackup = true
            } label: {
                Image(systemName: "externaldrive").font(.system(size: 16))
            }
            .accessibilityLabel("备份与恢复")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(workspaces) { item in
                Button {
                    selectedWorkspaceUUID = item.uuid
                } label: {
                    if item.uuid == workspace?.uuid {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            Divider()
            Button {
                showSubscriptions = true
            } label: {
                Label("管理维度与订阅…", systemImage: "slider.horizontal.3")
            }
            Divider()
            Text("版本 \(AppVersion.display)")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                Text(workspace?.name ?? "维度")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        }
    }

    // MARK: - 行为

    /// 箭头翻月走与手势翻月完全相同的平移动画，避免「硬切」观感。
    private func shiftMonth(_ delta: Int, containerWidth: CGFloat) {
        pager.settle(to: CGFloat(delta) * -containerWidth) {
            month = CalendarUtils.addMonths(delta, to: month)
        }
    }

    /// 「今天」定位：分「非本月」与「本月」两条动画路径。
    private func goToToday(containerWidth: CGFloat) {
        let today = Date()
        let todayMonth = CalendarUtils.startOfMonth(today)
        let key = CalendarUtils.key(for: today)

        if CalendarUtils.isSameDay(todayMonth, month) {
            // 情况 A：今天就在当前月 → 只做选中动画 + 脉冲高亮
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selectedDate = today
            }
            triggerPulse(key)
            return
        }

        // 情况 B：今天在其它月 → 若恰好是相邻月就用翻月平移动画；
        // 跨多个月时**不能**滑动（翻页器只渲染前后各一个月，滑过去会露出未渲染的空白），
        // 直接重定位 + 脉冲。
        let nextMonth = CalendarUtils.addMonths(1, to: month)
        if CalendarUtils.isSameDay(nextMonth, todayMonth) {
            pager.settle(to: -containerWidth) {
                month = todayMonth
                selectedDate = today
                triggerPulse(key)
            }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                month = todayMonth
                selectedDate = today
            }
            triggerPulse(key)
        }
    }

    /// 月份选择器选定某月。
    ///
    /// 走与「今天」跳月完全相同的那条路径：翻页器只常驻渲染前后各一个月，
    /// 跨多个月**不能**滑动（滑过去会露出未渲染的空白），因此直接重定位 + 隐式过渡动画。
    private func pickMonth(_ target: Date) {
        showMonthPicker = false
        guard !CalendarUtils.isSameMonth(target, month) else { return }
        withAnimation(.easeInOut(duration: 0.22)) { month = target }
    }

    private func triggerPulse(_ key: String) {
        pulseToken &+= 1
        pulseKey = key
        let token = pulseToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if pulseToken == token { pulseKey = nil }
        }
    }

    private func openDay(_ date: Date, pageIndex: Int) {
        let target = workspace ?? repository.ensureDefaultWorkspace()
        guard let record = repository.day(for: date, workspace: target, create: true) else { return }
        selectedDate = date
        // 注意：不切换月视图 —— 点选相邻月的日格时，画布应在**本页**弹出。
        let sourceID = "\(CalendarUtils.key(for: CalendarUtils.startOfMonth(month)))|\(CalendarUtils.key(for: date))"
        editorRequest = EditorRequest(day: record, pageIndex: pageIndex, sourceID: sourceID)
    }

    private func bootstrap() async {
        // 旧库升级：一次性回填冗余页数（此后渲染路径不再触碰 pages 关系）。
        repository.backfillPageCountsIfNeeded()
        // 幂等播种两条内置假期凭据（固定 UUID，已存在则只补齐字段；保存后 @Query 自动刷新）。
        repository.ensureBuiltInSubscriptions()
        let fallback = repository.ensureDefaultWorkspace()
        if selectedWorkspaceUUID == nil {
            selectedWorkspaceUUID = workspaces.first?.uuid ?? fallback.uuid
        }
        if !subscriptions.isEmpty {
            await eventStore.refresh(subscriptions: subscriptions)
        }
        rebuildHolidays()
        await performAutoSnapshotIfNeeded()
    }

    /// 由两条内置凭据的开关状态重建班休日表。
    ///
    /// 两条凭据互相独立：关掉「调休补班」只会让补班日退回周末语义，关掉「放假」则所有日期
    /// 退回纯自然周末着色 —— 用户自建的 ICS 订阅不参与。
    private func rebuildHolidays() {
        let offDay = subscriptions.first { $0.bundledSource == .offDay }?.isEnabled ?? false
        let makeUpWork = subscriptions.first { $0.bundledSource == .makeUpWork }?.isEnabled ?? false
        holidayRegistry.rebuild(offDayEnabled: offDay, makeUpWorkEnabled: makeUpWork)
    }

    private func performAutoSnapshotIfNeeded() async {
        let now = Date().timeIntervalSince1970
        let week: Double = 7 * 24 * 3600
        guard lastAutoSnapshot == 0 || now - lastAutoSnapshot > week else { return }
        lastAutoSnapshot = now
        await backup.performAutoSnapshot(context: context)
    }

    private func handleIncoming(url: URL) async {
        guard url.pathExtension.lowercased() == "vcal" else { return }
        let ready = await backup.prepareRestore(at: url)
        if ready {
            showRestoreDialog = true
        } else if let error = backup.lastError {
            toast = error
        }
    }

    private func applyRestore(_ mode: RestoreMode) {
        guard let summary = backup.applyPendingRestore(mode: mode, context: context) else { return }
        selectedWorkspaceUUID = workspaces.first?.uuid
        toast = summary.message
    }
}
