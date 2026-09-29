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

/// 1:1 正方形日格：缩略图 + 日期 + 班休角标 + 分级 ICS 呈现 + 定位脉冲。
struct DayCellView: View {
    let date: Date
    let inCurrentMonth: Bool
    let thumbnail: UIImage?
    let pageCount: Int
    let events: [CalendarEvent]
    let holiday: WorkRestStatus
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
        return Color.primary.opacity(inCurrentMonth ? 0.10 : 0.05)
    }

    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if thumbnail == nil {
            Rectangle()
                .fill(inCurrentMonth ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemGroupedBackground))
        } else {
            Rectangle().fill(Color.white)
        }
    }

    private var topBar: some View {
        HStack(spacing: tier == .lod1Minimal ? 1 : 3) {
            Text(dayNumber)
                .font(.system(size: numberFontSize, weight: isToday ? .bold : .semibold, design: .rounded))
                .foregroundStyle(numberColor)
                .padding(.horizontal, tier == .lod1Minimal ? 2 : 4)
                .padding(.vertical, tier == .lod1Minimal ? 0.5 : 1.5)
                .background(
                    Capsule().fill(Color(uiColor: .systemBackground).opacity(inCurrentMonth ? 0.78 : 0.5))
                )

            if holiday.isVisible, tier != .lod1Minimal {
                Text(holiday.rawValue)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 2.5)
                    .padding(.vertical, 0.5)
                    .background(holiday == .rest ? Color.red.opacity(0.85) : Color.gray.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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

    private var numberColor: Color {
        if !inCurrentMonth { return .secondary }
        if isWeekend { return .orange }
        return .primary
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
                            .background(.ultraThinMaterial, in: Capsule())
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
                    .background(.ultraThinMaterial, in: Capsule())
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
