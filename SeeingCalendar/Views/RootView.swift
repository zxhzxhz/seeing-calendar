import SwiftData
import SwiftUI

struct EditorRequest: Identifiable {
    let day: DayRecord
    let pageIndex: Int
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
    @State private var isMonthDragging = false

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
            let isPortrait = proxy.size.height > proxy.size.width
            VStack(spacing: 0) {
                headerBar
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
        // 画布编辑器默认整屏打开（这是创作态，不是辅助卡片）
        .fullScreenCover(item: $editorRequest) { request in
            DayEditorView(day: request.day,
                          workspace: workspace ?? request.day.workspace ?? repository.ensureDefaultWorkspace(),
                          context: context,
                          initialPageIndex: request.pageIndex,
                          isFingerDrawingEnabled: fingerDrawingEnabled,
                          onFingerDrawingChanged: { fingerDrawingEnabled = $0 })
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

    // MARK: - 月历 + 左右滑动翻月

    private func monthPager(availableSize: CGSize, containerWidth: CGFloat) -> some View {
        let cell = MonthGridView.cellWidth(availableSize: availableSize)
        let height = MonthGridView.gridHeight(cellWidth: cell)
        return ZStack {
            if isMonthDragging {
                HStack(spacing: 0) {
                    if monthDragOffset > 0 {
                        page(for: CalendarUtils.addMonths(-1, to: month), availableSize: availableSize, width: containerWidth)
                    }
                    page(for: month, availableSize: availableSize, width: containerWidth)
                    if monthDragOffset < 0 {
                        page(for: CalendarUtils.addMonths(1, to: month), availableSize: availableSize, width: containerWidth)
                    }
                }
                .offset(x: monthDragOffset > 0 ? -containerWidth + monthDragOffset : monthDragOffset)
            } else {
                page(for: month, availableSize: availableSize, width: containerWidth)
            }
        }
        .frame(width: containerWidth, height: height, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(monthSwipe(containerWidth: containerWidth))
    }

    private func page(for target: Date, availableSize: CGSize, width: CGFloat) -> some View {
        monthGrid(for: target, availableSize: availableSize)
            .frame(width: width)
    }

    private func monthSwipe(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }   // 只接管横向滑动
                if !isMonthDragging { isMonthDragging = true }
                monthDragOffset = dx
            }
            .onEnded { value in
                guard isMonthDragging else { return }
                let projected = value.predictedEndTranslation.width
                let threshold = containerWidth * 0.25
                if monthDragOffset > threshold || projected > containerWidth * 0.55 {
                    withAnimation(.easeOut(duration: 0.26)) {
                        monthDragOffset = containerWidth
                    } completion: {
                        month = CalendarUtils.addMonths(-1, to: month)
                        monthDragOffset = 0
                        isMonthDragging = false
                    }
                } else if monthDragOffset < -threshold || projected < -containerWidth * 0.55 {
                    withAnimation(.easeOut(duration: 0.26)) {
                        monthDragOffset = -containerWidth
                    } completion: {
                        month = CalendarUtils.addMonths(1, to: month)
                        monthDragOffset = 0
                        isMonthDragging = false
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        monthDragOffset = 0
                    } completion: {
                        isMonthDragging = false
                    }
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
                             onSelect: { date in
                                 selectedDate = date
                                 if !CalendarUtils.isSameDay(CalendarUtils.startOfMonth(date), CalendarUtils.startOfMonth(month)) {
                                     month = CalendarUtils.startOfMonth(date)
                                 }
                             },
                             onOpen: { date in openDay(date, pageIndex: 0) })
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button {
                    shiftMonth(-1)
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
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("下个月")
            }

            Button("今天") {
                let now = Date()
                month = CalendarUtils.startOfMonth(now)
                selectedDate = now
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

    private func shiftMonth(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.22)) {
            month = CalendarUtils.addMonths(delta, to: month)
        }
    }

    private func openDay(_ date: Date, pageIndex: Int) {
        let target = workspace ?? repository.ensureDefaultWorkspace()
        guard let record = repository.day(for: date, workspace: target, create: true) else { return }
        selectedDate = date
        if !CalendarUtils.isSameDay(CalendarUtils.startOfMonth(date), CalendarUtils.startOfMonth(month)) {
            month = CalendarUtils.startOfMonth(date)
        }
        editorRequest = EditorRequest(day: record, pageIndex: pageIndex)
    }

    private func bootstrap() async {
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
