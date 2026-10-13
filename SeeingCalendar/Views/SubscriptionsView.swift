import SwiftData
import SwiftUI

/// ICS 订阅源与维度管理。
struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ICSSubscription.createdAt) private var subscriptions: [ICSSubscription]
    @Query(sort: \Workspace.sortIndex) private var workspaces: [Workspace]

    let eventStore: CalendarEventStore
    let onWorkspacesChanged: () -> Void

    @State private var newName = ""
    @State private var newURL = ""
    @State private var newScope: [UUID] = []
    @State private var isNewScopeExpanded = false
    @State private var newColor = SubscriptionPalette.color(at: 0)
    @State private var editingSubscription: ICSSubscription?
    @State private var workspaceName = ""
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""
    @State private var provider = BundledHolidayProvider.shared
    @State private var isRefreshingAll = false

    /// 展示顺序：用户自建在上、内置凭据恒定居底（规则见 `ICSSubscription.displayOrder`）。
    ///
    /// `ForEach` 与 `onDelete` 必须吃同一份数组 —— 两者错位时，滑动删掉的是**另一行**，
    /// 而列表上看不出任何异常，只会「莫名其妙少了一条」，所以这层绑定由门禁钉住。
    private var orderedSubscriptions: [ICSSubscription] {
        ICSSubscription.displayOrder(subscriptions)
    }

    /// 弹窗由「有没有待改名的维度」驱动：`.alert(isPresented:)` 要的是 Bool，
    /// 而真值来源是一个可选引用，只好包一层可写 Binding。
    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renamingWorkspace != nil },
                set: { if !$0 { renamingWorkspace = nil } })
    }

    private var coverageText: String {
        let offDay = provider.table(for: .offDay)
        let makeUp = provider.table(for: .makeUpWork)
        let years = Set(offDay.coveredYears).union(makeUp.coveredYears).sorted()
        guard !years.isEmpty else { return "未加载" }
        let span = years.count == 1 ? "\(years[0])" : "\(years.first ?? 0)–\(years.last ?? 0)"
        return "\(span)（放假 \(offDay.restCount) 天 · 补班 \(makeUp.workCount) 天）"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedSubscriptions) { subscription in
                        row(for: subscription)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("订阅源（\(subscriptions.count)）")
                } footer: {
                    Text("点按自建订阅可修改配置；关闭开关可停用内置节假日。")
                }

                // 内置假期凭据：本地优先（随包发行，冷启动零网络即可正确着色），随日程刷新自动同步。
                Section {
                    LabeledContent("数据来源") {
                        Text(provider.originText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("覆盖年份") {
                        Text(coverageText)
                            .foregroundStyle(.secondary)
                    }
                    if let stamp = provider.updatedAt {
                        LabeledContent("上游更新于") {
                            Text(stamp).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("中国节假日（内置）")
                } footer: {
                    Text("内置国家法定放假与调休补班数据，随日程刷新自动同步。")
                }

                Section("新增订阅") {
                    TextField("名称，例如 工作日历", text: $newName)
                    TextField("订阅地址", text: $newURL, prompt: Text(verbatim: "https://example.com/calendar.ics"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    subscriptionScopeRows(scope: $newScope,
                                         workspaces: workspaces,
                                         isExpanded: $isNewScopeExpanded)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(SubscriptionPalette.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(newColor == hex ? Color.primary : .clear, lineWidth: 2))
                                    .scaleEffect(newColor == hex ? 1.15 : 1.0)
                                    .animation(.spring(response: 0.22, dampingFraction: 0.75), value: newColor == hex)
                                    .onTapGesture { newColor = hex }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                    Button {
                        addSubscription()
                    } label: {
                        Label("添加订阅源", systemImage: "plus.circle")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("画板维度") {
                    ForEach(workspaces) { workspace in
                        Button {
                            beginRename(workspace)
                        } label: {
                            HStack {
                                Text(workspace.name)
                                Spacer()
                                Text("\(workspace.days.count) 天")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteWorkspace)
                    HStack {
                        TextField("新建维度名称", text: $workspaceName)
                        Button("创建") {
                            let name = workspaceName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            let repository = PageRepository(context: context)
                            _ = repository.createWorkspace(named: name)
                            workspaceName = ""
                            onWorkspacesChanged()
                        }
                        .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("维度与订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            isRefreshingAll = true
                            await eventStore.refresh(subscriptions: subscriptions, force: true)
                            await provider.syncFromUpstream()
                            try? context.save()
                            isRefreshingAll = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isRefreshingAll {
                                ProgressView().controlSize(.small)
                            }
                            Text("刷新日程")
                        }
                    }
                    .disabled(isRefreshingAll)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $editingSubscription) { target in
                SubscriptionEditorSheet(subscription: target, workspaces: workspaces) { name, url, scope in
                    applyEdit(target, name: name, urlString: url, scope: scope)
                }
            }
            .alert("重命名维度", isPresented: renameAlertPresented) {
                TextField("维度名称", text: $renameText)
                Button("取消", role: .cancel) { renamingWorkspace = nil }
                Button("保存") { commitRename() }
            } message: {
                Text("维度的身份记在 uuid 上，改名不会动画作与日程，也不会改变它在列表里的位置。")
            }
        }
    }

    /// 一行订阅源。
    ///
    /// 自建订阅可点按进入编辑（名称 + 作用域）；内置凭据不可编辑也不可删除，
    /// 开关是它唯一的可用操作 —— 所以 chevron 与点按只对自建订阅亮出。
    @ViewBuilder
    private func row(for subscription: ICSSubscription) -> some View {
        HStack(spacing: 12) {
            Button {
                editingSubscription = subscription
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color(hex: subscription.colorHex, fallback: .blue))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.name)
                            .font(.system(size: 14, weight: .medium))
                        Text(subscription.isBuiltIn
                             ? "内置本地凭据 · \(subscription.bundledSource?.fileName ?? "")"
                             : subscription.urlString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(scopeLabel(for: subscription))
                                .lineLimit(1)
                            let updateDate = subscription.lastFetched ?? subscription.createdAt
                            Text("· 更新于 \(CalendarUtils.shortDateTimeString(updateDate))")
                            if let error = subscription.lastError {
                                Text("· \(error)")
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if !subscription.isBuiltIn {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(subscription.isBuiltIn)
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { newValue in
                    subscription.isEnabled = newValue
                    try? context.save()
                }
            ))
            .labelsHidden()
        }
        // 内置凭据是本地班休数据的唯一来源，删掉它等于拿掉「放假 / 补班」的底层依据。
        // 用 `deleteDisabled` 而不是只在 `delete(at:)` 里 return：后者会让用户能滑出一个
        // Delete 按钮，点下去毫无反应 —— 比「压根不给删」更让人困惑。
        .deleteDisabled(subscription.isBuiltIn)
    }

    private func scopeLabel(for subscription: ICSSubscription) -> String {
        guard !subscription.workspaceUUIDs.isEmpty else { return "全局" }
        // 磁盘上的旧数据可能引用已经不存在的维度（例如从旧备份恢复、而备份里缺那块画板），
        // 所以这里保留「已删除维度」兜底，而不是直接干掉那一项。
        return subscription.workspaceUUIDs
            .map { uuid in workspaces.first { $0.uuid == uuid }?.name ?? "已删除维度" }
            .joined(separator: "、")
    }

    private func addSubscription() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return }
        let subscription = ICSSubscription(name: name,
                                           urlString: url,
                                           colorHex: newColor,
                                           scope: newScope,
                                           lastFetched: .now)
        context.insert(subscription)
        try? context.save()
        newName = ""
        newURL = ""
        newScope = []
        newColor = SubscriptionPalette.color(at: subscriptions.count + 1)
        Task { await eventStore.refresh(subscriptions: subscriptions, force: true) }
    }

    /// `offsets` 来自 `ForEach(orderedSubscriptions)`，所以下标必须落在**同一份**数组上。
    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let subscription = orderedSubscriptions[index]
            // 兜底：界面上已用 `deleteDisabled` 收掉内置行的删除手势，
            // 这里再挡一次，免得将来有别的入口绕过那一层。
            guard !subscription.isBuiltIn else { continue }
            context.delete(subscription)
        }
        try? context.save()
    }

    /// 保存订阅源的名称 / 地址 / 作用域改动。
    ///
    /// 作用域会改变 `applies(to:)` 的判定结果，改了就必须重取日程 —— 否则日格上
    /// 还挂着按旧作用域算出来的彩点。改地址同样需要重新拉取日历数据。
    private func applyEdit(_ subscription: ICSSubscription, name: String, urlString: String, scope: [UUID]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !trimmedURL.isEmpty else { return }
        let scopeChanged = Set(subscription.workspaceUUIDs) != Set(scope)
        let urlChanged = subscription.urlString != trimmedURL
        subscription.name = trimmed
        subscription.urlString = trimmedURL
        subscription.setScope(scope)
        try? context.save()
        guard scopeChanged || urlChanged else { return }
        Task { await eventStore.refresh(subscriptions: subscriptions, force: true) }
    }

    private func beginRename(_ workspace: Workspace) {
        renameText = workspace.name
        renamingWorkspace = workspace
    }

    /// 提交维度改名。
    ///
    /// 这里**不**调用 `onWorkspacesChanged()`：那个回调的语义是「维度集合变了，
    /// 重新选一个当前维度」（实现里会把选中项拨回第一个维度）。改名没有增删维度，
    /// 拨动选中项只会让用户突然跳到另一块画板上。名字是活模型字段，界面自己会更新。
    private func commitRename() {
        guard let workspace = renamingWorkspace else { return }
        renamingWorkspace = nil
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        let repository = PageRepository(context: context)
        repository.renameWorkspace(workspace, to: trimmed)
    }

    /// 联网取最新版假期数据；成功后同时刷新班休着色与抽屉事件列表。
    private func syncHolidays() async {
        await provider.syncFromUpstream()
        await eventStore.refresh(subscriptions: subscriptions, force: true)
    }

    private func deleteWorkspace(at offsets: IndexSet) {
        let repository = PageRepository(context: context)
        let targets = offsets.map { workspaces[$0] }
        guard workspaces.count > targets.count else { return }
        for workspace in targets {
            _ = repository.deleteWorkspace(workspace)
        }
        onWorkspacesChanged()
    }
}

// MARK: - 订阅源编辑器

/// 编辑自建订阅源的「名称」与「作用域」。
///
/// 只开这两个口子：`urlString` 决定这条订阅**是什么**（改掉它等于换一条订阅，请新建），
/// 颜色是创建时选定的识别色，两者都不在这里改。
/// 内置凭据也不进这个界面 —— 它的名字与来源绑定，改了会让「放假 / 补班」对不上号。
///
/// 编辑内容先落在本地 `@State`，点「保存」才回头调 `onSave`：
/// 中途退出（取消）不该已经把模型改了一半。
private struct SubscriptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let subscription: ICSSubscription
    let workspaces: [Workspace]
    let onSave: (String, String, [UUID]) -> Void

    @State private var name: String
    @State private var urlString: String
    @State private var scope: [UUID]
    /// 展开状态自己持有：新增区与编辑面板各自折叠，互不影响。
    @State private var isScopeExpanded = false

    init(subscription: ICSSubscription,
         workspaces: [Workspace],
         onSave: @escaping (String, String, [UUID]) -> Void) {
        self.subscription = subscription
        self.workspaces = workspaces
        self.onSave = onSave
        _name = State(initialValue: subscription.name)
        _urlString = State(initialValue: subscription.urlString)
        _scope = State(initialValue: subscription.workspaceUUIDs)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("订阅名称", text: $name)
                }
                Section("订阅地址") {
                    TextField("订阅地址", text: $urlString, prompt: Text(verbatim: "https://example.com/calendar.ics"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("作用域") {
                    subscriptionScopeRows(scope: $scope,
                                         workspaces: workspaces,
                                         isExpanded: $isScopeExpanded)
                }
            }
            .navigationTitle("编辑订阅源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(trimmedName, trimmedURL, scope)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || trimmedURL.isEmpty)
                }
            }
        }
    }
}
