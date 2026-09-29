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
    @State private var newScope: UUID?
    @State private var newColor = SubscriptionPalette.color(at: 0)
    @State private var editingSubscription: ICSSubscription?
    @State private var workspaceName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(subscriptions) { subscription in
                        row(for: subscription)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("订阅源（\(subscriptions.count)）")
                } footer: {
                    Text("订阅作用域可设为全局（所有维度可见）或仅绑定当前维度。ICS 内容只以微型胶囊/彩点呈现，不干扰手绘主视觉。")
                }

                Section("新增订阅") {
                    TextField("名称，例如 工作日历", text: $newName)
                    TextField("https://example.com/calendar.ics", text: $newURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker("作用域", selection: $newScope) {
                        Text("全局").tag(UUID?.none)
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(UUID?.some(workspace.uuid))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(SubscriptionPalette.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(newColor == hex ? Color.primary : .clear, lineWidth: 2))
                                    .onTapGesture { newColor = hex }
                            }
                        }
                        .padding(.vertical, 4)
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
                        HStack {
                            Text(workspace.name)
                            Spacer()
                            Text("\(workspace.days.count) 天")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
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
                    Button("刷新日程") {
                        Task {
                            await eventStore.refresh(subscriptions: subscriptions, force: true)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for subscription: ICSSubscription) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: subscription.colorHex, fallback: .blue))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.system(size: 14, weight: .medium))
                Text(subscription.urlString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(scopeLabel(for: subscription))
                    if let last = subscription.lastFetched {
                        Text("· 更新于 \(CalendarUtils.timeString(last))")
                    }
                    if let error = subscription.lastError {
                        Text("· \(error)")
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { newValue in
                    subscription.isEnabled = newValue
                    try? context.save()
                }
            ))
            .labelsHidden()
        }
    }

    private func scopeLabel(for subscription: ICSSubscription) -> String {
        guard let uuid = subscription.workspaceUUID else { return "全局" }
        return workspaces.first { $0.uuid == uuid }?.name ?? "已删除维度"
    }

    private func addSubscription() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return }
        let subscription = ICSSubscription(name: name,
                                           urlString: url,
                                           colorHex: newColor,
                                           workspaceUUID: newScope)
        context.insert(subscription)
        try? context.save()
        newName = ""
        newURL = ""
        newScope = nil
        newColor = SubscriptionPalette.color(at: subscriptions.count + 1)
        Task { await eventStore.refresh(subscriptions: subscriptions, force: true) }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(subscriptions[index])
        }
        try? context.save()
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
