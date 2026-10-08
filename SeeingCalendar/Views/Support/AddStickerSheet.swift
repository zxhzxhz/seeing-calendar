import SwiftUI
import UIKit

/// 添加贴纸弹窗（看齐 iOS 备忘录贴纸系统）
struct AddStickerSheet: View {
    let onCommit: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0

    // MARK: - 贴纸数据源

    struct PlannerBadge: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
        let color: Color
        let uiColor: UIColor
    }

    private let badges: [PlannerBadge] = [
        PlannerBadge(text: "TODO", icon: "checklist", color: .orange, uiColor: .systemOrange),
        PlannerBadge(text: "DONE", icon: "checkmark.circle.fill", color: .green, uiColor: .systemGreen),
        PlannerBadge(text: "重点", icon: "exclamationmark.triangle.fill", color: .red, uiColor: .systemRed),
        PlannerBadge(text: "目标", icon: "target", color: .blue, uiColor: .systemBlue),
        PlannerBadge(text: "打卡", icon: "flag.fill", color: .purple, uiColor: .systemPurple),
        PlannerBadge(text: "灵感", icon: "lightbulb.fill", color: .yellow, uiColor: UIColor(red: 0.95, green: 0.78, blue: 0.0, alpha: 1.0)),
        PlannerBadge(text: "会议", icon: "person.2.fill", color: .indigo, uiColor: .systemIndigo),
        PlannerBadge(text: "生日", icon: "birthday.cake.fill", color: .pink, uiColor: .systemPink),
        PlannerBadge(text: "纪念", icon: "heart.fill", color: .red, uiColor: .systemRed),
        PlannerBadge(text: "休息", icon: "cup.and.saucer.fill", color: .brown, uiColor: .systemBrown),
        PlannerBadge(text: "专注", icon: "timer", color: .teal, uiColor: .systemTeal),
        PlannerBadge(text: "学习", icon: "book.fill", color: .cyan, uiColor: .systemCyan),
    ]

    private let emojiCategories: [(name: String, emojis: [String])] = [
        ("情绪与日常", ["😊", "🥳", "🥰", "😎", "🤩", "😴", "🤔", "🥺", "😇", "🎉", "✨", "💯", "🐱", "🐶", "🐼", "🐨"]),
        ("自然与天气", ["☀️", "⛅", "🌧️", "❄️", "🌈", "🌸", "🍀", "🌻", "🍁", "🌙", "⭐", "🔥", "🌿", "🌊", "🍄", "🌷"]),
        ("生活与美食", ["☕", "🍵", "🧋", "🍰", "🍎", "🍕", "🍔", "🍳", "🍻", "🥐", "🍓", "🥑", "🍦", "🥪", "🍩", "🍣"]),
        ("效率与活动", ["✏️", "📅", "📌", "💡", "💻", "📚", "🎨", "🎵", "🏃", "✈️", "🎁", "🏆", "⏰", "🏷️", "💼", "🔔"])
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $selectedTab) {
                    Text("手帐徽章").tag(0)
                    Text("Emoji 贴纸").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    if selectedTab == 0 {
                        badgeGrid
                    } else {
                        emojiList
                    }
                }
            }
            .navigationTitle("添加贴纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 徽章网格

    private var badgeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 14) {
            ForEach(badges) { badge in
                Button {
                    commitBadge(badge)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: badge.icon)
                            .font(.system(size: 13, weight: .bold))
                        Text(badge.text)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule()
                            .fill(badge.color)
                            .shadow(color: badge.color.opacity(0.35), radius: 4, x: 0, y: 2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    // MARK: - Emoji 贴纸列表

    private var emojiList: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(emojiCategories, id: \.name) { cat in
                VStack(alignment: .leading, spacing: 10) {
                    Text(cat.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 12)], spacing: 12) {
                        ForEach(cat.emojis, id: \.self) { emoji in
                            Button {
                                commitEmoji(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 38))
                                    .frame(width: 52, height: 52)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - 渲染生成

    private func commitBadge(_ badge: PlannerBadge) {
        let size = CGSize(width: 220, height: 72)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            badge.uiColor.setFill()
            path.fill()

            let text = "\(badge.text)"
            let font = UIFont.systemFont(ofSize: 28, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }

        if let data = image.pngData() {
            onCommit(data)
            dismiss()
        }
    }

    private func commitEmoji(_ emoji: String) {
        let size = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let font = UIFont.systemFont(ofSize: 110)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = (emoji as NSString).size(withAttributes: attrs)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (emoji as NSString).draw(in: rect, withAttributes: attrs)
        }

        if let data = image.pngData() {
            onCommit(data)
            dismiss()
        }
    }
}
