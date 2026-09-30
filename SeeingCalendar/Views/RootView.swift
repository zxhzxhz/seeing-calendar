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
    @State private var toast: String?

    // 翻月手势
    @State private var monthDragOffset: CGFloat = 0
    @State private var isSettling = false
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
                    landscapeLayout(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .task { await bootstrap() }
        .onChange(of: subscriptions.map(\.urlString)) { _, _ in
            Task { await eventStore.refresh(subscriptions: subscriptions, force: true) }
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

    private func landscapeLayout(width: CGFloat, height: CGFloat) -> some View {
        monthPager(availableSize: CGSize(width: width - 28, height: height - 120),
                   containerWidth: width)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - 月历 + 左右滑动翻月（上/下月常驻预渲染）

    private func monthPager(availableSize: CGSize, containerWidth: CGFloat) -> some View {
        let cell = MonthGridView.cellWidth(availableSize: availableSize)
        let height = MonthGridView.gridHeight(cellWidth: cell)
        return HStack(spacing: 0) {
            page(for: CalendarUtils.addMonths(-1, to: month), availableSize: availableSize, width: containerWidth)
            page(for: month, availableSize: availableSize, width: containerWidth)
            page(for: CalendarUtils.addMonths(1, to: month), availableSize: availableSize, width: containerWidth)
        }
        .frame(width: containerWidth * 3, height: height, alignment: .leading)
        .offset(x: -containerWidth + monthDragOffset)
        .frame(width: containerWidth, height: height, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(monthSwipe(containerWidth: containerWidth))
    }

    private func page(for target: Date, availableSize: CGSize, width: CGFloat) -> some View {
        monthGrid(for: target, availableSize: availableSize)
            .frame(width: width)
    }

    /// 与 iOS 原生桌面翻页一致：位移阈值很低，主要判定依据是**速度**。
    private func monthSwipe(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isSettling else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }   // 只接管横向滑动
                monthDragOffset = dx
            }
            .onEnded { value in
                guard !isSettling else { return }
                let velocity = value.velocity.width        // > 0 表示向右滑（看上一月）
                let distanceThreshold = containerWidth * 0.13
                var direction = 0                          // +1 → 下一月（内容左移）
                if velocity > 220 {
                    direction = -1
                } else if velocity < -220 {
                    direction = 1
                } else if monthDragOffset > distanceThreshold {
                    direction = -1
                } else if monthDragOffset < -distanceThreshold {
                    direction = 1
                }

                guard direction != 0 else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        monthDragOffset = 0
                    }
                    return
                }

                isSettling = true
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    monthDragOffset = CGFloat(direction) * -containerWidth
                } completion: {
                    month = CalendarUtils.addMonths(direction, to: month)
                    monthDragOffset = 0
                    isSettling = false
                }
            }
    }

    private func monthGrid(for target: Date, availableSize: CGSize) -> some View {
        var eventsByDay: [String: [CalendarEvent]] = [:]
        for date in CalendarUtils.gridDates(forMonthContaining: target) {
            let key = CalendarUtils.key(for: date)
            let events = eventStore.events(onDayKey: key)
            if !events.isEmpty { eventsByDay[key] = events }
        }
        return MonthGridView(month: target,
                             selectedDate: selectedDate,
                             records: dayRecords,
                             eventsByDay: eventsByDay,
                             holidays: holidayRegistry.statuses,
                             availableSize: availableSize,
                             pulseKey: pulseKey,
                             pulseID: pulseToken,
                             zoomNamespace: zoomNamespace,
                             onSelect: { date in
                                 // 只更新选中日期：点中非本月日格也**不切换月视图**，
                                 // 画布就在本页弹出（spec 交互诉求）。
                                 selectedDate = date
                             },
                             onOpen: { date in openDay(date, pageIndex: 0) })
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

                Text(CalendarUtils.title(forMonth: month))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .frame(minWidth: 118, alignment: .center)

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
        guard !isSettling else { return }
        isSettling = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            monthDragOffset = CGFloat(delta) * -containerWidth
        } completion: {
            month = CalendarUtils.addMonths(delta, to: month)
            monthDragOffset = 0
            isSettling = false
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

        // 情况 B：今天在其它月 → 用翻月平移动画切过去，落位后高亮
        guard !isSettling else { return }
        let forward = todayMonth > month
        isSettling = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            monthDragOffset = forward ? -containerWidth : containerWidth
        } completion: {
            month = todayMonth
            monthDragOffset = 0
            isSettling = false
            selectedDate = today
            triggerPulse(key)
        }
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
        let fallback = repository.ensureDefaultWorkspace()
        if selectedWorkspaceUUID == nil {
            selectedWorkspaceUUID = workspaces.first?.uuid ?? fallback.uuid
        }
        if !subscriptions.isEmpty {
            await eventStore.refresh(subscriptions: subscriptions)
        }
        await performAutoSnapshotIfNeeded()
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
