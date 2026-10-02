import SwiftUI

/// 月份选择下拉面板（顶栏年月处点开的 Drop Menu）。
///
/// 形态对齐参考图：顶部「YYYY年」加左右各一组双箭头翻年，一条分隔线，
/// 下方 3 列 × 4 行的月份网格，当前正在显示的月份用强调色圆角块高亮。
///
/// 为什么自绘而不用 `.popover`：iPad 的 popover 自带指针箭头且没有公开 API 可以关掉，
/// 而参考图里没有箭头。自绘面板配一层透明收口层（在 `RootView` 里挂），
/// 形态可控、样式也和 APP 其余部分一致。
///
/// 样式 token 全部沿用既有取值（`.rounded` 粗体标题、连续圆角、`accentColor` 高亮、
/// `systemGroupedBackground` 体系），不引入任何新配色。
struct MonthPickerPanel: View {
    /// 月历当前正在显示的月：决定哪一格高亮，也决定面板初次打开落在哪一年。
    let month: Date
    /// 选定某月（入参已归一化为该月 1 号 00:00）。
    let onPick: (Date) -> Void

    /// 面板自己浏览的年份：翻年箭头只改它、不动月历，直到用户真的点中某个月。
    /// 这样「翻到明年看一眼再关掉」不会把月历也带着跑。
    @State private var browsingYear: Int

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    init(month: Date, onPick: @escaping (Date) -> Void) {
        self.month = month
        self.onPick = onPick
        _browsingYear = State(initialValue: CalendarUtils.year(of: month))
    }

    var body: some View {
        VStack(spacing: 0) {
            yearHeader
            Divider().opacity(0.5)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(1...12, id: \.self) { value in
                    monthCell(value)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 296)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    }

    // MARK: - 年份行

    private var yearHeader: some View {
        HStack(spacing: 0) {
            yearStepButton(delta: -1, label: "上一年")
            Spacer(minLength: 0)
            Text("\(browsingYear)年")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            Spacer(minLength: 0)
            yearStepButton(delta: 1, label: "下一年")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    /// 翻年按钮。
    ///
    /// 双箭头是用**两枚同向 chevron 叠出来**的，而不是用 SF Symbols 里那种
    /// 「chevron 后面带序号」的编号字形：那类字形在不同 SF Symbols 版本里不一定存在，
    /// 缺字形时 SwiftUI 会静默渲染空白，界面上就会出现两个点不动的隐形按钮。
    /// （门禁会盯着这行注释别把那个字形名字再写回来，见 verify_ui_regressions.swift）
    private func yearStepButton(delta: Int, label: String) -> some View {
        let chevron = delta < 0 ? "chevron.left" : "chevron.right"
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { browsingYear += delta }
        } label: {
            HStack(spacing: -3) {
                Image(systemName: chevron)
                Image(systemName: chevron)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 月份格

    private func monthCell(_ value: Int) -> some View {
        let isCurrent = browsingYear == CalendarUtils.year(of: month)
            && value == CalendarUtils.month(of: month)
        return Button {
            onPick(CalendarUtils.startOfMonth(year: browsingYear, month: value))
        } label: {
            Text("\(value)月")
                .font(.system(size: 16, weight: isCurrent ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(browsingYear)年\(value)月")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
