import SwiftUI

/// 动态视觉细节分级：单格实际渲染宽度决定内部 UI 精度（spec 3.5）。
enum CellLODTier {
    case lod3Full
    case lod2Compact
    case lod1Minimal

    static func resolve(for width: CGFloat) -> CellLODTier {
        if width >= 120 { return .lod3Full }
        if width >= 70 { return .lod2Compact }
        return .lod1Minimal
    }
}

/// 日格三态配色。
///
/// 语义只有两套 + 一个降级态，这里用**显式色值**而不是 `.opacity(0.4)` 叠层：
/// 一张月历有 42 格，若给每格套 `opacity`，CoreAnimation 会为每格单独开一层离屏渲染，
/// 42 个离屏 pass / 帧 —— 这正是我们正在消灭的开销。平面内容用调暗后的等效色值即可，
/// 视觉上不可分辨，成本为零（缩略图是位图，仍用 opacity 降级）。
struct DayCellPalette {
    /// 格子底色
    let background: Color
    /// 日期数字
    let number: Color
    /// 边框
    let border: Color
    /// 角标底 / 角标字
    let badgeBackground: Color
    let badgeForeground: Color
    /// 日号胶囊底
    let numberPlate: Color

    /// 放假 / 周末：暖色（暖米底 + 焦橙数字）。
    static let warm = DayCellPalette(
        background: Color(red: 0.988, green: 0.937, blue: 0.906),
        number: Color(red: 0.776, green: 0.290, blue: 0.125),
        border: Color(red: 0.847, green: 0.549, blue: 0.412).opacity(0.38),
        badgeBackground: Color(red: 0.855, green: 0.357, blue: 0.180),
        badgeForeground: .white,
        numberPlate: Color(red: 1.0, green: 0.988, blue: 0.973).opacity(0.88)
    )

    /// 普通工作日 / 调休补班：中性（冷灰底 + 墨色数字）。
    static let neutral = DayCellPalette(
        background: Color(uiColor: .secondarySystemBackground),
        number: .primary,
        border: Color.primary.opacity(0.10),
        badgeBackground: Color(red: 0.184, green: 0.620, blue: 0.431),
        badgeForeground: .white,
        numberPlate: Color(uiColor: .systemBackground).opacity(0.78)
    )

    /// 非当月：整格降级为中性再压暗。
    static let dimmed = DayCellPalette(
        background: Color(uiColor: .systemGroupedBackground),
        number: Color.secondary.opacity(0.55),
        border: Color.primary.opacity(0.05),
        badgeBackground: Color.secondary.opacity(0.5),
        badgeForeground: Color.white.opacity(0.9),
        numberPlate: Color(uiColor: .systemBackground).opacity(0.45)
    )
}

/// 1:1 正方形日格：缩略图 + 日期 + 班休角标 + 节日名角标 + 分级 ICS 呈现 + 定位脉冲。
struct DayCellView: View {
    let date: Date
    let inCurrentMonth: Bool
    let thumbnail: UIImage?
    let pageCount: Int
    let events: [CalendarEvent]
    let holiday: WorkRestStatus
    /// 节日名（如 `国庆节`），仅放假日有值。
    let holidayName: String?
    let isPulsing: Bool
    /// 脉冲代次：每次「今天」定位都递增，保证动画可重复触发。
    let pulseID: Int
    let tier: CellLODTier

    @State private var pulseProgress: CGFloat = 0

    private var dayNumber: String {
        "\(CalendarUtils.calendar.component(.day, from: date))"
    }

    private var isToday: Bool { CalendarUtils.isToday(date) }
    private var isWeekend: Bool { CalendarUtils.isWeekend(date) }

    private var cornerRadius: CGFloat { tier == .lod1Minimal ? 4 : 7 }

    /// 放假 = 法定节假日；周末 = 自然休息日；调休上班日本身不是休息日。
    private var isRestDay: Bool { holiday == .rest || (isWeekend && holiday != .work) }

    private var palette: DayCellPalette {
        guard inCurrentMonth else { return .dimmed }
        return isRestDay ? .warm : .neutral
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                backgroundLayer(size: size)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(inCurrentMonth ? (tier == .lod1Minimal ? 0.88 : 1) : 0.45)
                }
                topBar
                icsOverlay
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .overlay {
                if isPulsing {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .scaleEffect(1 + 0.45 * pulseProgress)
                        .opacity(Double(1 - pulseProgress))
                        .id(pulseID)
                        .onAppear {
                            pulseProgress = 0
                            withAnimation(.easeOut(duration: 0.62)) {
                                pulseProgress = 1
                            }
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 选中环不在这里绘制（由 MonthGridView 单独成层，避免点选时重算 126 个格子）。
    private var borderColor: Color {
        if isToday { return .accentColor.opacity(0.55) }
        return palette.border
    }

    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if thumbnail == nil {
            Rectangle().fill(palette.background)
        } else {
            Rectangle().fill(thumbnail == nil ? palette.background : .white)
        }
    }

    /// 右上角角标：放假显示节日名，调休补班显示「班」。
    /// 普通周末不出角标 —— 暖色底已经表达了「休」，再堆一个字只会变噪。
    private var badgeText: String? {
        switch holiday {
        case .work: return "班"
        case .rest: return tier == .lod3Full ? (holidayName?.isEmpty == false ? holidayName : "休") : nil
        case .normal: return nil
        }
    }

    private var topBar: some View {
        HStack(spacing: tier == .lod1Minimal ? 1 : 3) {
            Text(dayNumber)
                .font(.system(size: numberFontSize, weight: isToday ? .bold : .semibold, design: .rounded))
                .foregroundStyle(numberColor)
                .padding(.horizontal, tier == .lod1Minimal ? 2 : 4)
                .padding(.vertical, tier == .lod1Minimal ? 0.5 : 1.5)
                .background(Capsule().fill(palette.numberPlate))

            if let badge = badgeText, tier != .lod1Minimal {
                Text(badge)
                    .font(.system(size: tier == .lod3Full ? 8 : 8, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, badge.count > 1 ? 3 : 2.5)
                    .padding(.vertical, 0.5)
                    .background(palette.badgeBackground, in: Capsule())
                    .foregroundStyle(palette.badgeForeground)
            }

            Spacer(minLength: 0)

            if pageCount > 1, tier == .lod3Full {
                Text("+\(pageCount - 1)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.75)))
            }
        }
        .padding(tier == .lod1Minimal ? 2.5 : 5)
    }

    private var numberFontSize: CGFloat {
        switch tier {
        case .lod1Minimal: return 10
        case .lod2Compact: return 12
        case .lod3Full: return 14
        }
    }

    /// 非当月统一降级；当月里「放假 / 周末」用暖色，调休补班（周六上班）用墨色 —— 两者同属「要干活」语义。
    private var numberColor: Color {
        guard inCurrentMonth else { return .secondary.opacity(0.55) }
        return isRestDay ? palette.number : .primary
    }

    @ViewBuilder
    private var icsOverlay: some View {
        VStack {
            Spacer()
            switch tier {
            case .lod3Full:
                if !events.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(events.prefix(2)) { event in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color(hex: event.colorHex, fallback: .blue))
                                    .frame(width: 4.5, height: 4.5)
                                Text(event.title)
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            // 刻意不用 .ultraThinMaterial：实时背景模糊要读回 backdrop，
                            // 一格两个胶囊 × 126 格 = 每帧上百次 GPU 读回。半透明纯色观感几乎一致。
                            .background(Color(uiColor: .systemBackground).opacity(0.82), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 3)
                }
            case .lod2Compact:
                if !events.isEmpty {
                    HStack(spacing: 2.5) {
                        ForEach(events.prefix(3)) { event in
                            Circle()
                                .fill(Color(hex: event.colorHex, fallback: .blue))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .systemBackground).opacity(0.82), in: Capsule())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 3)
                }
            case .lod1Minimal:
                if !events.isEmpty {
                    Circle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 3, height: 3)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 2.5)
                }
            }
        }
    }
}
