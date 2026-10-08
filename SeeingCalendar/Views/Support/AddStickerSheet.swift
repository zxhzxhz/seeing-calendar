import PhotosUI
import SwiftUI
import UIKit

/// 添加贴纸弹窗（支持系统 Emoji 分类库、系统贴纸与剪贴板粘贴、手帐徽章）
struct AddStickerSheet: View {
    let onCommit: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0
    @State private var selectedEmojiCategoryIndex: Int = 0
    @State private var clipboardImage: UIImage?
    @State private var photosPickerItem: PhotosPickerItem?

    // MARK: - Emoji 分类库（标准系统 Emoji 库）

    struct EmojiCategory: Identifiable {
        let id: String
        let name: String
        let icon: String
        let emojis: [String]
    }

    private let emojiCategories: [EmojiCategory] = [
        EmojiCategory(
            id: "smiley",
            name: "笑脸与情绪",
            icon: "face.smiling",
            emojis: [
                "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🥲", "🥹", "☺️", "😊", "😇", "🙂", "🙃", "😉",
                "😌", "😍", "🥰", "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎",
                "🥸", "🤩", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩", "🥺",
                "😢", "😭", "😮‍💨", "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓",
                "🫣", "🤗", "🫡", "🤔", "🫢", "🤫", "🤥", "😶", "😶‍🌫️", "😐", "😑", "😬", "🫨", "🫠", "🙄", "😯",
                "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵", "😵‍💫", "🫥", "🤐", "🥴", "🤢", "🤮", "🤧",
                "😷", "🤒", "🤕", "🤑", "🤠", "😈", "👿", "👹", "👺", "🤡", "💩", "👻", "💀", "☠️", "👽", "👾"
            ]
        ),
        EmojiCategory(
            id: "gestures",
            name: "手势与身体",
            icon: "hand.raised",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "🖖", "🫱", "🫲", "🫳", "🫴", "🫷", "🫸", "👌", "🤌", "🤏", "✌️", "🤞",
                "🫰", "🤟", "🤘", "🤙", "👈", "👉", "👆", "🖕", "👇", "☝️", "🫵", "👍", "👎", "✊", "👊", "🤛",
                "🤜", "👏", "🙌", "🫶", "👐", "🤲", "🤝", "🙏", "✍️", "💅", "🤳", "💪", "🦾", "🦿", "🦵", "🦶",
                "👂", "🦻", "👃", "🫀", "🫁", "🧠", "🦷", "🦴", "👀", "👁️", "👅", "👄", "🫦"
            ]
        ),
        EmojiCategory(
            id: "people",
            name: "人物与角色",
            icon: "person.crop.circle",
            emojis: [
                "👶", "👧", "🧒", "👦", "👩", "🧑", "👨", "👩‍🦱", "🧑‍🦱", "👨‍🦱", "👩‍🦰", "🧑‍🦰", "👨‍🦰", "👱‍♀️", "👱", "👱‍♂️",
                "👩‍🦳", "🧑‍🦳", "👨‍🦳", "👩‍🦲", "🧑‍🦲", "👨‍🦲", "🧔", "👵", "🧓", "👴", "👲", "👳‍♀️", "👳", "👳‍♂️", "🧕", "👮‍♀️",
                "👮", "👮‍♂️", "👷‍♀️", "👷", "👷‍♂️", "💂‍♀️", "💂", "💂‍♂️", "🕵️‍♀️", "🕵️", "🕵️‍♂️", "👩‍⚕️", "🧑‍⚕️", "👨‍⚕️", "👩‍🌾", "🧑‍🌾",
                "👨‍🌾", "👩‍🍳", "🧑‍🍳", "👨‍🍳", "👩‍🎓", "🧑‍🎓", "👨‍🎓", "👩‍🎤", "🧑‍🎤", "👨‍🎤", "👩‍🏫", "🧑‍🏫", "👨‍🏫", "👩‍🏭", "🧑‍🏭", "👨‍🏭",
                "👩‍💻", "🧑‍💻", "👨‍💻", "👩‍💼", "🧑‍💼", "👨‍💼", "👩‍🔧", "🧑‍🔧", "👨‍🔧", "👩‍🔬", "🧑‍🔬", "👨‍🔬", "👩‍🎨", "🧑‍🎨", "👨‍🎨", "👩‍🚒",
                "🧑‍🚒", "👨‍🚒", "👩‍✈️", "🧑‍✈️", "👨‍✈️", "👩‍🚀", "🧑‍🚀", "👨‍🚀", "👩‍⚖️", "🧑‍⚖️", "👨‍⚖️", "👰‍♀️", "👰", "👰‍♂️", "🤵‍♀️", "🤵",
                "🤵‍♂️", "👸", "🫅", "🤴", "🥷", "🦸‍♀️", "🦸", "🦸‍♂️", "🦹‍♀️", "🦹", "🦹‍♂️", "🤶", "🧑‍🎄", "🎅", "🧙‍♀️", "🧙"
            ]
        ),
        EmojiCategory(
            id: "hearts",
            name: "爱心与情感",
            icon: "heart.fill",
            emojis: [
                "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "💕", "💞", "💓", "💗",
                "💖", "💘", "💝", "💟", "💌", "🫶", "🫀", "💋", "🫂", "💍", "💎", "💐", "🌹", "🥀", "🌺", "🌸"
            ]
        ),
        EmojiCategory(
            id: "nature",
            name: "动物与自然",
            icon: "leaf",
            emojis: [
                "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐻‍❄️", "🐨", "🐯", "🦁", "🐮", "🐷", "🐽", "🐸",
                "🐵", "🙈", "🙉", "🙊", "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉", "🦇", "🐺",
                "🐗", "🐴", "🦄", "🐝", "🪱", "🐛", "🦋", "🐌", "🐞", "🐜", "🪰", "🪲", "🪳", "🦟", "🦗", "🕷️",
                "🌲", "🌳", "🌴", "🪵", "🌱", "🌿", "☘️", "🍀", "🎍", "🪴", "🎋", "🍃", "🍂", "🍁", "🍄", "🌾",
                "🌞", "🌝", "🌛", "🌜", "🌚", "🌕", "🌖", "🌗", "🌘", "🌑", "🌒", "🌓", "🌔", "🌙", "🌎", "🌍",
                "🪐", "💫", "⭐️", "🌟", "✨", "⚡️", "☄️", "💥", "🔥", "🌪️", "🌈", "☀️", "🌤️", "⛅️", "🌥️", "☁️",
                "🌦️", "🌧️", "⛈️", "🌩️", "🌨️", "❄️", "☃️", "⛄️", "🌬️", "💨", "💧", "💦", "🫧", "☔️", "☂️", "🌊"
            ]
        ),
        EmojiCategory(
            id: "food",
            name: "美食与饮品",
            icon: "fork.knife",
            emojis: [
                "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥",
                "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶️", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅", "🥔", "🍠",
                "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈", "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🦴",
                "🌭", "🍔", "🍟", "🍕", "🫓", "🥪", "🥙", "🧆", "🌮", "🌯", "🫔", "🥗", "🥘", "🫕", "🥫", "🍝",
                "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🦪", "🍤", "🍙", "🍚", "🍘", "🍥", "🥠", "🥮", "🍢", "🍡",
                "🍧", "🍨", "🍦", "🥧", "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪", "🌰", "🥜",
                "🥛", "🍼", "🫖", "☕️", "🍵", "🧃", "🥤", "🧋", "🍶", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸", "🍹"
            ]
        ),
        EmojiCategory(
            id: "activities",
            name: "活动与运动",
            icon: "sportscourt",
            emojis: [
                "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🏑", "🥍",
                "🏏", "🪃", "🥅", "⛳️", "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛼", "🛷", "⛸️", "🥌",
                "🎿", "⛷️", "🏂", "🪂", "🏋️‍♀️", "🏋️", "🏋️‍♂️", "🤸‍♀️", "🤸", "🤸‍♂️", "⛹️‍♀️", "⛹️", "⛹️‍♂️", "🤺", "🤾‍♀️", "🤾",
                "🏄‍♀️", "🏄", "🏄‍♂️", "🏊‍♀️", "🏊", "🏊‍♂️", "🚴‍♀️", "🚴", "🚴‍♂️", "🏆", "🥇", "🥈", "🥉", "🏅", "🎖️", "🎫",
                "🎟️", "🎪", "🤹", "🎭", "🩰", "🎨", "🎬", "🎤", "🎧", "🎼", "🎹", "🥁", "🎷", "🎺", "🎸", "🎮"
            ]
        ),
        EmojiCategory(
            id: "objects",
            name: "物品与生活",
            icon: "lightbulb",
            emojis: [
                "⌚️", "📱", "📲", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🕹️", "💽", "💾", "💿", "📀", "📷", "📸", "📹",
                "🎥", "📽️", "🎞️", "📞", "☎️", "📟", "📠", "📺", "📻", "🎙️", "🧭", "⏱️", "⏲️", "⏰", "🕰️", "⌛️",
                "⏳", "📡", "🔋", "🪫", "🔌", "💡", "🔦", "🕯️", "💸", "💵", "💴", "💶", "💷", "🪙", "💰", "💳",
                "💎", "⚖️", "🪜", "🧰", "🪛", "🔧", "🔨", "⚒️", "🛠️", "⛏️", "🪚", "🔩", "⚙️", "🧱", "⛓️", "🧲",
                "🩹", "🩺", "💊", "💉", "🩸", "🧬", "🧪", "🌡️", "🧹", "🧺", "🧻", "🧼", "🪥", "🔑", "🗝️", "🚪",
                "🎁", "🎈", "🎉", "✉️", "📩", "📦", "📜", "📑", "🧾", "📊", "📈", "📉", "📅", "📆", "🗓️", "📌",
                "📍", "✂️", "🖊️", "🖋️", "✒️", "🖌️", "🖍️", "📝", "✏️", "🔍", "🔎", "🔒", "🔓", "🔏", "🔐"
            ]
        ),
        EmojiCategory(
            id: "symbols",
            name: "符号与标记",
            icon: "number",
            emojis: [
                "⚠️", "⛔️", "🚫", "🚳", "🚭", "🚯", "⬆️", "↗️", "➡️", "↘️", "⬇️", "↙️", "⬅️", "↖️", "↕️", "↔️",
                "↩️", "↪️", "⤴️", "⤵️", "🔃", "🔄", "🔙", "🔚", "🔛", "🔜", "🔝", "▶️", "⏩", "⏭️", "⏯️", "◀️",
                "⏪", "⏮️", "🔼", "⏫", "🔽", "⏬", "⏸️", "⏹️", "⏺️", "📶", "🛜", "📳", "📴", "✖️", "➕", "➖",
                "➗", "🟰", "♾️", "‼️", "⁉️", "❓", "❔", "❕", "❗️", "〰️", "💲", "♻️", "⭕️", "✅", "☑️", "✔️",
                "❌", "❎", "➰", "➿", "✳️", "✴️", "❇️", "©️", "®️", "™️", "🔟", "🔴", "🟠", "🟡", "🟢", "🔵",
                "🟣", "🟤", "⚫️", "⚪️", "🟥", "🟧", "🟨", "🟩", "🟪", "🟫", "⬛️", "⬜️", "🔷", "🔶", "🔹", "🔸"
            ]
        ),
        EmojiCategory(
            id: "flags",
            name: "旗帜",
            icon: "flag",
            emojis: [
                "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇨🇳", "🇭🇰", "🇲🇴", "🇹🇼", "🇯🇵", "🇰🇷", "🇺🇸", "🇬🇧",
                "🇫🇷", "🇩🇪", "🇮🇹", "🇪🇸", "🇷🇺", "🇦🇺", "🇨🇦", "🇧🇷", "🇮🇳"
            ]
        )
    ]

    // MARK: - 手帐徽章数据源

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
        PlannerBadge(text: "学习", icon: "book.fill", color: .cyan, uiColor: .systemCyan)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分类", selection: $selectedTab) {
                    Text("系统 Emoji").tag(0)
                    Text("系统贴纸").tag(1)
                    Text("手帐徽章").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    emojiCategorizedView
                } else if selectedTab == 1 {
                    systemStickerView
                } else {
                    badgeView
                }
            }
            .navigationTitle("添加贴纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                checkClipboardForSticker()
            }
        }
    }

    // MARK: - 1. 系统 Emoji 库视图

    private var emojiCategorizedView: some View {
        VStack(spacing: 0) {
            // 水平分类选择栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(emojiCategories.enumerated()), id: \.element.id) { index, cat in
                        Button {
                            selectedEmojiCategoryIndex = index
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 12))
                                Text(cat.name)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selectedEmojiCategoryIndex == index ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                            )
                            .foregroundColor(selectedEmojiCategoryIndex == index ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            // Emoji 网格
            ScrollView {
                let currentCategory = emojiCategories[selectedEmojiCategoryIndex]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 10)], spacing: 10) {
                    ForEach(currentCategory.emojis, id: \.self) { emoji in
                        Button {
                            commitEmoji(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 34))
                                .frame(width: 48, height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - 2. 系统贴纸与剪贴板视图

    private var systemStickerView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 剪贴板中检测到的贴纸
                if let image = clipboardImage {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("检测到剪贴板贴纸", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        HStack {
                            Spacer()
                            ZStack {
                                CheckerboardBackground()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(8)
                            }
                            .frame(width: 140, height: 140)
                            Spacer()
                        }

                        Button {
                            if let data = image.pngData() {
                                onCommit(data)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                Text("将剪贴板贴纸放入画布")
                                Spacer()
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal)
                }

                // 系统键盘贴纸接收区说明
                VStack(alignment: .leading, spacing: 12) {
                    Label("从系统贴纸键盘输入", systemImage: "keyboard")
                        .font(.headline)

                    Text("在 iOS 17 及以上系统中，点击下方输入框唤起键盘，轻点键盘左下角的【贴纸】图标，即可直接选取并粘贴您的个人贴纸。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)

                    StickerKeyboardDropField { image in
                        if let data = image.pngData() {
                            onCommit(data)
                            dismiss()
                        }
                    }
                    .frame(height: 50)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.horizontal)

                // 从系统照片图库导入
                VStack(alignment: .leading, spacing: 12) {
                    Label("从相册导入透明贴纸", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)

                    PhotosPicker(selection: $photosPickerItem, matching: .images) {
                        HStack {
                            Spacer()
                            Image(systemName: "photo.badge.plus")
                            Text("浏览系统照片图库选取贴纸")
                            Spacer()
                        }
                        .font(.system(size: 15, weight: .medium))
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .onChange(of: photosPickerItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                await MainActor.run {
                                    onCommit(data)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    // MARK: - 3. 手帐徽章视图

    private var badgeView: some View {
        ScrollView {
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
            .padding()
        }
    }

    // MARK: - 辅助与提交

    private func checkClipboardForSticker() {
        if let image = UIPasteboard.general.image {
            clipboardImage = image
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
}

/// 支持接收系统键盘贴纸输入的专用文本输入视图
private struct StickerKeyboardDropField: UIViewRepresentable {
    let onReceiveImage: (UIImage) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = StickerCatchingTextField()
        field.placeholder = "点此激活键盘，轻点贴纸图标输入..."
        field.font = UIFont.systemFont(ofSize: 14)
        field.borderStyle = .roundedRect
        field.backgroundColor = UIColor.tertiarySystemFill
        field.onImageReceived = onReceiveImage
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
}

/// 拦截系统键盘贴纸/图片粘贴的 UITextField
private final class StickerCatchingTextField: UITextField {
    var onImageReceived: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onImageReceived?(image)
            resignFirstResponder()
            return
        }
        super.paste(sender)
    }

    override func insertText(_ text: String) {
        // 如果系统键盘以贴纸方式触发并放入剪贴板
        if let image = UIPasteboard.general.image {
            onImageReceived?(image)
            resignFirstResponder()
            return
        }
        super.insertText(text)
    }
}
