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

    /// 最近一次切年的方向（+1 = 下一年，-1 = 上一年），只用来决定滑动动画从哪边进来。
    @State private var slideDirection: Int = 0

    // MARK: - 尺寸与阈值

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private static let panelWidth: CGFloat = 296
    private static let panelCornerRadius: CGFloat = 22

    /// 手势「什么时候算开始拖动」。取一个明显大于点击抖动、又远小于一次真实滑动的值：
    /// 12pt 以内一律当点击交给月份格，免得用户点月份时被误判成滑动。
    private static let swipeRecognitionDistance: CGFloat = 12

    /// 手势「什么时候算切年」。必须明显大于识别距离，否则轻微横向抖动就会跳年；
    /// 又必须小于一个月份格的宽度（约 87pt），否则拇指够不到的短滑就失效了。
    private static let swipeCommitDistance: CGFloat = 44

    init(month: Date, onPick: @escaping (Date) -> Void) {
        self.month = month
        self.onPick = onPick
        _browsingYear = State(initialValue: CalendarUtils.year(of: month))
    }

    var body: some View {
        VStack(spacing: 0) {
            yearHeader
            Divider().opacity(0.5)
            monthGridArea
        }
        .frame(width: Self.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        // 滑动切年时新旧两份网格会同时存在并横向平移；裁一刀把动画关在面板内，
        // 否则平移中的月份格会溢出到面板外面。
        .clipShape(RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    }

    // MARK: - 年份行

    private var yearHeader: some View {
        HStack(spacing: 0) {
            yearStepButton(delta: -1, label: "上一年")
            Spacer(minLength: 0)
            // 用 `Text(verbatim:)` 而不是 `Text("\(browsingYear)年")`：
            // 后者是**带插值的字符串字面量**，会被当成 `LocalizedStringKey`，
            // 其中的 Int 走本地化数字格式化，于是年份被加上千位分隔符，渲染成「2,026年」。
            // 年份不是需要按语言分组的数字量，走 String 插值（verbatim）才是对的。
            Text(verbatim: "\(browsingYear)年")
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
    /// 「chevron 后面带序号」的编号字形（`chevron.left.2` / `chevron.right.2`）：
    /// 那类字形在不同 SF Symbols 版本里不一定存在，缺字形时 SwiftUI 会静默渲染空白，
    /// 界面上就会出现两个点不动的隐形按钮。
    /// （这行注释里写了那两个被禁的字形名也不要紧 —— 门禁比对源码前会先剥掉行注释，
    ///   见 verify_ui_regressions.swift 的 `code(of:)`。）
    private func yearStepButton(delta: Int, label: String) -> some View {
        let chevron = delta < 0 ? "chevron.left" : "chevron.right"
        return Button {
            stepYear(delta)
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

    // MARK: - 月份网格（兼滑动切年落点）

    /// 下部月份区域：既是 3 列 × 4 行网格，也是左右滑动手势的落点。
    ///
    /// 手势**只挂在这里**、不挂整个面板（用户明确要求只在月份区域响应）：
    /// 上半部是年份行，那里已经有翻年箭头，再叠一层滑动手势只会和用户的意图打架。
    private var monthGridArea: some View {
        ZStack {
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(1...12, id: \.self) { value in
                    monthCell(value)
                }
            }
            // 换年时给网格换一个身份，才有「翻过去」的插入 / 移除动画。
            .id(browsingYear)
            .transition(slideTransition)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(yearSwipeGesture)
    }

    /// 切年动画：往哪边翻，新网格就从哪边进来。
    ///
    /// **离场那半刻意不带方向**，只做淡出。原因是离场动画的方向捕获自**上一帧**的状态
    /// （旧的网格是在上一次 body 求值时建好的，那时还不知道接下来往哪边翻），
    /// 一旦方向相同就会新旧两张卡片朝同一边走，反向滑动时更明显。
    /// 进场那半的方向则来自本次求值，是确定的 —— 所以把方向只押在进场侧。
    ///
    /// 承载它的必须是 `ZStack` 而不是 `VStack`：新旧两份网格会在动画期间同时存在，
    /// 在 ZStack 里它们重叠、容器尺寸不变；放在 VStack 里面板高度会先翻倍再回落。
    private var slideTransition: AnyTransition {
        let forward = slideDirection >= 0
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// 下部月份区域上的左右滑动切年。
    private var yearSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeRecognitionDistance)
            .onEnded { value in
                let delta = Self.yearStep(forSwipeX: value.translation.width,
                                          y: value.translation.height)
                guard delta != 0 else { return }
                stepYear(delta)
            }
    }

    /// 一次拖拽应当切换几年（0 = 不算滑动切年）。
    ///
    /// 判定顺序是有讲究的：**先看主方向，再看距离**。
    /// 斜着拖（横向分量够长、但竖向更长）说明用户想竖着动，不能因为横向恰好超线就跳年。
    ///
    /// 返回值恒为 ±1，不按滑动距离放大 —— 面板宽度只够铺下 3 列月份，
    /// 一次快手滑就飞出去好几年的话，用户还得再滑回来，反而是负担。
    static func yearStep(forSwipeX dx: CGFloat, y dy: CGFloat) -> Int {
        guard abs(dx) > abs(dy) else { return 0 }               // 主方向必须是横向
        guard abs(dx) >= swipeCommitDistance else { return 0 }  // 距离必须够，免得点击 / 抖动误触发
        return dx < 0 ? 1 : -1                                  // 往左滑 = 下一年（与右侧翻年箭头同向）
    }

    /// 切年的唯一入口：箭头与滑动手势都走这里，两条路径的动画与方向语义因此不会分叉。
    private func stepYear(_ delta: Int) {
        slideDirection = delta
        withAnimation(.easeInOut(duration: 0.20)) { browsingYear += delta }
    }

    // MARK: - 月份格

    private func monthCell(_ value: Int) -> some View {
        let isCurrent = browsingYear == CalendarUtils.year(of: month)
            && value == CalendarUtils.month(of: month)
        return Button {
            onPick(CalendarUtils.startOfMonth(year: browsingYear, month: value))
        } label: {
            // 同 `yearHeader`：`Text("\(value)月")` 会走 LocalizedStringKey 的数字格式化，
            // 虽然 1…12 撞不上千位分隔符，但没有理由让两处标签走两套渲染路径。
            Text(verbatim: "\(value)月")
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
        // 无障碍朗读同样不能走本地化数字格式化，否则会念成「2,026 年 1 月」。
        .accessibilityLabel(Text(verbatim: "\(browsingYear)年\(value)月"))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}