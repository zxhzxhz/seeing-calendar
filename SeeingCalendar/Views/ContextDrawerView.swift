import SwiftUI

/// 竖屏动态扩展区（spec 1.2）：ICS 时间轴 + 多页横向轮播 + 便签式快捷记录。
/// 外层由 RootView 的统一滚动视图承载，本视图自身不再嵌套纵向滚动，避免键盘避让时的布局抖动。
struct ContextDrawerView: View {
    let date: Date
    let record: DayRecord?
    let events: [CalendarEvent]
    let onOpenPage: (Int) -> Void
    let onNoteCommit: (String) -> Void

    /// 缩略图不再存在视图本地：图像表是 `ThumbnailStore.images`（单例、跨视图共享）。
    /// 视图 `.task` 被取消不会丢掉任何已经拿到的图，也不需要「读完再整表提交」这一跳。
    /// 单例在 `body` / `.task` 里直接取（二者都是 `@MainActor`），不做存储属性 ——
    /// 存储属性的默认值初始化发生在非隔离的 memberwise init 里，取 `@MainActor` 单例会报警。

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            timeline
            carousel
            noteSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 3)
        .padding(.horizontal, 16)
        .task(id: ThumbnailStore.shared.version) {
            await loadThumbnails()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(CalendarUtils.relativeLabel(for: date))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(record == nil ? "暂无画布内容 · 点按格子即可开始创作" : "共 \(record?.pages.count ?? 0) 页画布")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onOpenPage(0)
            } label: {
                Label("打开画布", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("当日日程", systemImage: "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text("无订阅日程")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: event.colorHex, fallback: .blue))
                            .frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(event.timeLabel + (event.location.map { " · \($0)" } ?? ""))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var carousel: some View {
        if let pages = record?.orderedPages, !pages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("画作轮播", systemImage: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(pages.enumerated()), id: \.element.uuid) { index, page in
                            Button {
                                onOpenPage(index)
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                                        if let image = ThumbnailStore.shared.image(page.pageSlot) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .aspectRatio(1, contentMode: .fill)
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        } else {
                                            Image(systemName: "scribble.variable")
                                                .font(.system(size: 24))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(width: 92, height: 92)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(index == 0 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06),
                                                          lineWidth: 1)
                                    )
                                    Text(index == 0 ? "Page 1 · 封面" : "Page \(index + 1)")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(BouncyCardButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("快捷记录", systemImage: "text.append")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            QuickNoteEditor(dayKey: record?.key ?? CalendarUtils.key(for: date),
                            initialText: record?.note ?? "",
                            onCommit: onNoteCommit)
                .id(record?.key ?? CalendarUtils.key(for: date))
        }
    }

    private func loadThumbnails() async {
        guard let pages = record?.orderedPages else { return }
        // 与月历同一套套路：先在主线程上批量把磁盘 PNG 扶入缓存（最多推进一次代次，
        // 于是 `.task(id:)` 最多只重启一次），剩下的缺口再逐页后台合成。
        let entries = pages.map { (slot: $0.pageSlot, page: $0) }
        for (slot, page) in ThumbnailStore.shared.primeFromDisk(entries) {
            if Task.isCancelled { return }
            await ThumbnailStore.shared.load(slot, page: page)
        }
    }
}

/// 便签式快捷记录：本地态 + 停止输入 0.7s 后才落库。
/// 这样键盘弹出/收起期间不会因为 SwiftData 写入引发的整树刷新而丢失第一响应者。
private struct QuickNoteEditor: View {
    let dayKey: String
    let initialText: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("写点什么…", text: $text, axis: .vertical)
            .lineLimit(2...6)
            .focused($isFocused)
            .textFieldStyle(.plain)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .onAppear {
                if text != initialText { text = initialText }
            }
            .onChange(of: text) { _, newValue in
                scheduleCommit(newValue)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitTask?.cancel()
                    onCommit(text)
                }
            }
            .onDisappear {
                commitTask?.cancel()
                onCommit(text)
            }
    }

    private func scheduleCommit(_ value: String) {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            onCommit(value)
        }
    }
}

/// Emil Kowalski & Apple Design 按压缩放微交互反馈
private struct BouncyCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.20, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
