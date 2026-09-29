import SwiftData
import SwiftUI

/// 竖屏动态扩展区（spec 1.2）：ICS 时间轴 + 多页横向轮播 + 便签式快捷记录。
struct ContextDrawerView: View {
    let date: Date
    let record: DayRecord?
    let events: [CalendarEvent]
    let onOpenPage: (Int) -> Void
    let onNoteCommit: (String) -> Void

    @State private var note: String = ""
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var loadedVersion: Int = -1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                timeline
                carousel
                noteEditor
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: ThumbnailStore.shared.version) {
            await loadThumbnails()
        }
        .onAppear { note = record?.note ?? "" }
        .onChange(of: record?.uuid) { _, _ in note = record?.note ?? "" }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarUtils.relativeLabel(for: date))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(record == nil ? "暂无画布内容 · 点按格子即可开始创作" : "共 \(record?.pages.count ?? 0) 页画布")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onOpenPage(0)
            } label: {
                Label("打开画布", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            VStack(alignment: .leading, spacing: 8) {
                Label("画作轮播", systemImage: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(pages.enumerated()), id: \.element.uuid) { index, page in
                            Button {
                                onOpenPage(index)
                            } label: {
                                VStack(spacing: 4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(uiColor: .secondarySystemBackground))
                                        if let image = thumbnails[page.uuid] {
                                            Image(uiImage: image)
                                                .resizable()
                                                .aspectRatio(1, contentMode: .fill)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        } else {
                                            Image(systemName: "scribble.variable")
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(width: 92, height: 92)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(index == 0 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                                          lineWidth: 1)
                                    )
                                    Text(index == 0 ? "Page 1 · 封面" : "Page \(index + 1)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("快捷记录", systemImage: "text.append")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("写点什么…", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .onChange(of: note) { _, newValue in
                    onNoteCommit(newValue)
                }
        }
    }

    private func loadThumbnails() async {
        guard let pages = record?.orderedPages else { return }
        var result: [UUID: UIImage] = [:]
        for page in pages {
            if let image = await ThumbnailStore.shared.thumbnail(for: page) {
                result[page.uuid] = image
            }
        }
        thumbnails = result
    }
}
