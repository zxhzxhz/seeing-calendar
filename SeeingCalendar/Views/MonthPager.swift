import SwiftData
import SwiftUI

/// 翻月状态容器：把「拖动偏移 / 落位中」从 `RootView` 里搬到独立对象上。
///
/// 为什么必须搬：拖动时每一帧都要改这个偏移量。若它是 `RootView` 的 `@State`，
/// `RootView.body` 就会逐帧重算 → 连带着把 3 个月 × 42 个日格（126 个 `DayCellView.body`）
/// 全部重新求值一遍，滑动必然掉帧。放到本对象后：
/// - 读 `offset` 的只有 `MonthPager` 自己 → 逐帧只重算 `MonthPager.body`；
/// - `RootView` 只持有对象引用、不读它的属性 → `RootView` 完全不参与逐帧刷新；
/// - 顶栏的箭头翻月 / 「今天」定位也能直接写同一份状态，行为与手势完全一致。
@MainActor
@Observable
final class MonthPagerState {
    /// 相对「当月居中」的像素偏移。
    var offset: CGFloat = 0
    /// 落位动画进行中：期间屏蔽新手势，避免动画被打断导致月序错乱。
    var isSettling = false

    /// 滑到指定偏移 → 提交新月份 → 复位。这是箭头 / 定位 / 手势共用的唯一落位路径。
    func settle(to target: CGFloat, commit: @escaping () -> Void) {
        guard !isSettling else { return }
        isSettling = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            offset = target
        } completion: {
            // 逃逸闭包必须显式 self（Swift 6）
            commit()
            self.offset = 0
            self.isSettling = false
        }
    }

    /// 未达翻页阈值：弹回原位。
    func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            offset = 0
        }
    }
}

/// 月历单页的等值短路壳。
///
/// `EquatableView` 是 **property wrapper**，只能以属性形式使用（`@EquatableView var grid: …`）。
/// 写成调用式的 `EquatableView { MonthGridView(…) }` 会被解析成「把闭包本身当作内容」：
/// `Content` 推断成 `() -> MonthGridView`，于是报
/// `type '() -> MonthGridView' cannot conform to 'Equatable' / 'View'`。
/// 所以用这层薄壳把属性形式包起来，语义不变：输入未变 → 整棵 42 格子树不重算。
private struct MonthPage: View {
    @EquatableView var grid: MonthGridView

    var body: some View { grid }
}

/// 月历翻页器：左右拖动切换月份，上/下月常驻预渲染。
///
/// 性能约定：
/// ① 逐帧只有 `.offset` 在变，三个 `MonthGridView` 被 `EquatableView` 短路，
///    子树不重算 → 实际开销只是一次 layer transform（GPU）；
/// ② 所有昂贵输入（日记录字典、按日事件索引、假期表、内容指纹）都在
///    `RootView` 里算好再传进来，翻页期间 `RootView` 不重算，因此这些准备成本为零。
struct MonthPager: View {
    let month: Date
    let selectedDate: Date
    let records: [String: DayRecord]
    /// 已按日预建的事件索引（覆盖前后各一个月的网格日期）。
    let eventsByDay: [String: [CalendarEvent]]
    let holidays: [String: WorkRestStatus]
    let holidayNames: [String: String]
    /// O(1) 内容指纹：父视图算好，用来让 `EquatableView` 做廉价判定。
    let contentToken: Int
    let availableSize: CGSize
    let containerWidth: CGFloat
    let pulseKey: String?
    let pulseID: Int
    let zoomNamespace: Namespace.ID
    let state: MonthPagerState
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void
    let onMonthChange: (Int) -> Void

    private var height: CGFloat {
        MonthGridView.gridHeight(cellWidth: MonthGridView.cellWidth(availableSize: availableSize))
    }

    var body: some View {
        HStack(spacing: 0) {
            page(offset: -1)
            page(offset: 0)
            page(offset: 1)
        }
        .frame(width: containerWidth * 3, height: height, alignment: .leading)
        .offset(x: -containerWidth + state.offset)
        .frame(width: containerWidth, height: height, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
    }

    private func page(offset delta: Int) -> some View {
        let target = CalendarUtils.addMonths(delta, to: month)
        return MonthPage(grid: MonthGridView(month: target,
                                             selectedDate: selectedDate,
                                             records: records,
                                             eventsByDay: eventsByDay,
                                             holidays: holidays,
                                             holidayNames: holidayNames,
                                             contentToken: contentToken,
                                             availableSize: availableSize,
                                             pulseKey: pulseKey,
                                             pulseID: pulseID,
                                             zoomNamespace: zoomNamespace,
                                             onSelect: onSelect,
                                             onOpen: onOpen))
            .frame(width: containerWidth)
    }

    /// 与 iOS 原生桌面翻页一致：位移阈值很低，主要判定依据是**速度**。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !state.isSettling else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }   // 只接管横向滑动
                state.offset = dx
            }
            .onEnded { value in
                guard !state.isSettling else { return }
                let velocity = value.velocity.width        // > 0 表示向右滑（看上一月）
                let distanceThreshold = containerWidth * 0.13
                var direction = 0                          // +1 → 下一月（内容左移）
                if velocity > 220 {
                    direction = -1
                } else if velocity < -220 {
                    direction = 1
                } else if state.offset > distanceThreshold {
                    direction = -1
                } else if state.offset < -distanceThreshold {
                    direction = 1
                }

                guard direction != 0 else {
                    state.springBack()
                    return
                }
                state.settle(to: CGFloat(direction) * -containerWidth) {
                    onMonthChange(direction)
                }
            }
    }
}
