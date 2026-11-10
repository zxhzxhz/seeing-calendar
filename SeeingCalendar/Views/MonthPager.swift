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
    /// 翻月相位：`idle` / `dragging` / `settling` 的**单一真值**。
    ///
    /// 为什么用相位而不是旧的两个字段（`offset` + `isSettling`）：旧实现靠「像素偏移」
    /// 与「落位旗标」共同涌现出三种状态，「落位期间屏蔽新手势」这条纪律只能手抄三遍。
    /// 相位把状态、转移（`PagerPolicy.reduce`）与能力（`phase.acceptsGesture`）集中到一处，
    /// 详见 `PagerPhasePolicy.swift` 的头注释。
    ///
    /// 性能上它仍是**单个存储属性**：逐帧只改它一次，投影出的 `offset` 也只让
    /// `MonthPager.body` 重算；`RootView` 不读本对象的任何属性，故逐帧刷新范围不变。
    private(set) var phase: PagerPhase = .idle

    /// 相对「当月居中」的像素偏移（只读投影，行为与旧的存储 `offset` 逐位一致）。
    var offset: CGFloat { phase.offset }
    /// 落位动画进行中（只读投影，兼容旧的 `isSettling` 读数）。
    var isSettling: Bool { phase.isSettling }

    /// 拖动中：把经阻尼换算后的偏移收敛进相位。
    ///
    /// 落位期间 `PagerPolicy.reduce` 会原样丢弃该事件 —— 这正是旧实现里三处手抄
    /// `guard !isSettling` 想表达、却容易漏抄的那条纪律。
    func dragChanged(offset: CGFloat) {
        phase = PagerPolicy.reduce(phase, event: .dragChanged(offset: offset))
    }

    /// 滑到指定偏移 → 提交新月份 → 复位。这是箭头 / 定位 / 手势共用的唯一落位路径。
    func settle(to target: CGFloat, commit: @escaping () -> Void) {
        guard phase.acceptsGesture else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            // 先经相位收敛点确认「可以落位」，再把落位目标写进相位（视觉上甩到相邻月）。
            let entered = PagerPolicy.reduce(phase, event: .dragEnded(committed: true))
            if case .settling = entered {
                phase = .settling(offset: target)
            }
        } completion: {
            // 逃逸闭包必须显式 self（Swift 6）
            commit()
            self.phase = PagerPolicy.reduce(self.phase, event: .settleFinished)
        }
    }

    /// 未达翻页阈值：弹回原位。与 `settle` 共用同一个相位收敛点。
    func springBack() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            phase = PagerPolicy.reduce(phase, event: .dragEnded(committed: false))
        }
    }
}

/// 月历翻页器：左右拖动切换月份，上/下月常驻预渲染。
///
/// 结构约定 —— **翻月位移必须是整个翻月流程里唯一逐帧变化的东西**：
///
/// ```
/// ZStack {                                  // 两棵并列子树，都不读翻月偏移
///     MonthPagerGrids(...).equatable()      // ① 内容树：三页网格
///     MonthSelectionRingLayer(...).equatable()  // ② 选中环层（唯一读 selectedDate 的）
/// }
/// .offset(x: -containerWidth + state.offset)   // ③ 唯一的位移：一次容器变换
/// ```
///
/// 为什么必须这样切：`state.offset` 每帧变化会让 `body` 重算。若三页网格与选中环直接
/// 铺在 `body` 里（旧写法就是），每帧都要**重新构造** 3 个 `MonthGridView` 与 3 个
/// `MonthSelectionRingOverlay`（各自在 `init` 里算 42 个网格日期 = 每帧 252 次算日），
/// 而挂在每页 `.overlay` 里的环又不受外层短路保护、逐帧重求值。后果是：
/// 任何让等值判定翻转的输入都会**在落位弹簧的动画事务内**重建 126 个日格 ——
/// 视觉上就是「每一格各自在动」而不是整页平移。
///
/// 切成两棵 `Equatable` 子树后：
/// ① 位移帧里两次值比较就短路掉全部内容重算，开销只剩一次 layer transform（GPU）；
/// ② 点选日期时内容树 `==` 为真、环层 `==` 为假 → **只有环层重算**，126 格零重算；
/// ③ 落位期间缩略图代次被冻结（`PagerPolicy.updatedFrozenVersion`），动画事务内
///    内容树绝不可能重建；
/// ④ 所有昂贵输入（日记录字典、按日事件索引、假期表、内容指纹）都在 `RootView` 里
///    算好再传进来，翻页期间 `RootView` 不重算，这些准备成本为零。
///
/// 对应的结构护栏在 `scripts/verify_pager_phase.swift` 的 `verifyContentTreeIsolation`。
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
    /// 缩略图内容代次（`ThumbnailStore.shared.version`）。
    ///
    /// 在这里而不是在 `MonthGridView` 内部读：等值判定 `==` 是 `nonisolated` 的，
    /// 不能碰 `@MainActor` 的单例；而月历的缩略图状态存在子视图的 `@State` 里，
    /// 父层必须显式把代次传下去，短路才不会被“看不见的状态”坑到。
    let thumbnailVersion: Int
    let availableSize: CGSize
    let containerWidth: CGFloat
    let pulseKey: String?
    let pulseID: Int
    let zoomNamespace: Namespace.ID
    let state: MonthPagerState
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void
    let onMonthChange: (Int) -> Void

    /// 落位动画期间冻结的缩略图代次（`nil` = 未冻结）。
    ///
    /// 见 `PagerPolicy.updatedFrozenVersion` 的注释：不冻结的话，动画事务内的一次
    /// 缩略图代次推进就会重建 126 个日格 —— 视觉上就是「每一格各自在动」。
    @State private var frozenThumbnailVersion: Int?

    /// 内容树实际使用的缩略图代次（落位期间钉住不动的那个）。
    private var effectiveThumbnailVersion: Int {
        frozenThumbnailVersion ?? thumbnailVersion
    }

    private var height: CGFloat {
        MonthGridView.gridHeight(cellWidth: MonthGridView.cellWidth(availableSize: availableSize))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ① 内容树：三页网格。**唯一**承载内容的部分，与翻月位移完全解耦 ——
            //    位移帧里它被 `.equatable()` 整体短路，连三次 `MonthGridView.init`
            //    （各自在 init 里算 42 个网格日期）都不会跑。
            MonthPagerGrids(month: month,
                            selectedDate: selectedDate,
                            records: records,
                            eventsByDay: eventsByDay,
                            holidays: holidays,
                            holidayNames: holidayNames,
                            contentToken: contentToken,
                            thumbnailVersion: effectiveThumbnailVersion,
                            availableSize: availableSize,
                            containerWidth: containerWidth,
                            pulseKey: pulseKey,
                            pulseID: pulseID,
                            zoomNamespace: zoomNamespace,
                            onSelect: onSelect,
                            onOpen: onOpen)
                .equatable()

            // ② 选中环层：与内容树**并列**的独立层，也是整个翻页器里唯一读 `selectedDate` 的东西。
            //    刻意留在 `MonthPagerGrids` 之外：一旦并进内容树，内容树的等值判定就必须比较
            //    `selectedDate`，而那会让**点选日期**击穿短路、126 格全量重算
            //    （这正是 `MonthGridView.==` 刻意不比 `selectedDate` 的原因，见该文件注释）。
            MonthSelectionRingLayer(month: month,
                                    selectedDate: selectedDate,
                                    availableSize: availableSize,
                                    containerWidth: containerWidth)
                .equatable()
        }
        .frame(width: containerWidth * 3, height: height, alignment: .topLeading)
        // ③ 唯一的翻月位移：一次容器变换。上面两棵子树都不参与逐帧重算。
        .offset(x: -containerWidth + state.offset)
        .frame(width: containerWidth, height: height, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        // 落位开始即冻结、结束即解冻；只在这两个边界写状态，绝不逐帧写。
        .onChange(of: state.isSettling) { _, settling in
            frozenThumbnailVersion = PagerPolicy.updatedFrozenVersion(current: frozenThumbnailVersion,
                                                                      isSettling: settling,
                                                                      live: thumbnailVersion)
        }
    }

    /// 与 iOS 原生桌面翻页一致：位移阈值很低，主要判定依据是**速度**。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard state.phase.acceptsGesture else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) else { return }   // 只接管横向滑动

                // 阻尼处理（含超界 0.45 阻尼）收敛在 `PagerPolicy.dampedOffset`，逐位等价于旧内联实现。
                state.dragChanged(offset: PagerPolicy.dampedOffset(translation: dx, limit: containerWidth, overdamp: 0.45))
            }
            .onEnded { value in
                guard state.phase.acceptsGesture else { return }
                let velocity = value.velocity.width        // > 0 表示向右滑（看上一月）
                let distanceThreshold = PagerPolicy.swipeDistanceThreshold(containerWidth: containerWidth)
                // +1 → 下一月（内容左移），-1 → 上一月，0 → 弹回；判定收敛在 `PagerPolicy.swipeDirection`。
                let direction = PagerPolicy.swipeDirection(velocityX: velocity,
                                                           offset: state.offset,
                                                           threshold: distanceThreshold)

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
/// 翻页器内容树：三个月的网格，仅此而已。
///
/// **为什么单独成类型**：`state.offset` 每帧变化会让 `MonthPager.body` 重算。
/// 把三页封成一个 `Equatable` 值之后，位移帧里 SwiftUI 只做一次值比较就短路掉整棵子树 ——
/// 包括三次 `MonthGridView.init`（各含 42 次网格日期计算）、三次 `.compositingGroup()`
/// 与三处 `.frame()`。旧写法把这些直接铺在 `MonthPager.body` 里，于是每帧都要重建一遍。
///
/// 等值判定刻意**不含 `selectedDate`**（与 `MonthGridView.==` 保持一致）：选中环已拆到
/// `MonthSelectionRingLayer`，点选日期时 126 格内容毫无变化。
struct MonthPagerGrids: View, Equatable {
    let month: Date
    let selectedDate: Date
    let records: [String: DayRecord]
    let eventsByDay: [String: [CalendarEvent]]
    let holidays: [String: WorkRestStatus]
    let holidayNames: [String: String]
    let contentToken: Int
    let thumbnailVersion: Int
    let availableSize: CGSize
    let containerWidth: CGFloat
    let pulseKey: String?
    let pulseID: Int
    let zoomNamespace: Namespace.ID
    let onSelect: (Date) -> Void
    let onOpen: (Date) -> Void

    nonisolated static func == (lhs: MonthPagerGrids, rhs: MonthPagerGrids) -> Bool {
        lhs.contentToken == rhs.contentToken
            && lhs.month == rhs.month
            && lhs.availableSize == rhs.availableSize
            && lhs.pulseID == rhs.pulseID
            && lhs.pulseKey == rhs.pulseKey
            && lhs.thumbnailVersion == rhs.thumbnailVersion
    }

    private var height: CGFloat {
        MonthGridView.gridHeight(cellWidth: MonthGridView.cellWidth(availableSize: availableSize))
    }

    var body: some View {
        HStack(spacing: 0) {
            page(delta: -1)
            page(delta: 0)
            page(delta: 1)
        }
        .frame(width: containerWidth * 3, height: height, alignment: .leading)
    }

    private func page(delta: Int) -> some View {
        let target = CalendarUtils.addMonths(delta, to: month)
        // `.frame` 必须接在 `.equatable()` **之后**：反过来内容类型会变成 ModifiedContent，
        // 那不是 Equatable，短路就失效了。
        return MonthGridView(month: target,
                             selectedDate: selectedDate,
                             records: records,
                             eventsByDay: eventsByDay,
                             holidays: holidays,
                             holidayNames: holidayNames,
                             contentToken: contentToken,
                             thumbnailVersion: thumbnailVersion,
                             availableSize: availableSize,
                             pulseKey: pulseKey,
                             pulseID: pulseID,
                             zoomNamespace: zoomNamespace,
                             onSelect: onSelect,
                             onOpen: onOpen)
            .equatable()
            .compositingGroup()
            .frame(width: containerWidth)
    }
}

/// 选中环层：三页各自的 `MonthSelectionRingOverlay` 并排成**一层**。
///
/// 与 `MonthPagerGrids` 并列挂载（而不是塞进它的 `.overlay`），因此：
/// - 翻月位移帧里它同样被 `.equatable()` 短路 → 环不参与逐帧重算；
/// - 点选日期时它 `==` 为假、内容树 `==` 为真 → **只有环层重算**，126 格零重算。
///
/// 顺带修好一处旧行为：环以前挂在每页的 `.overlay` 里，而 overlay 内容不受外层
/// `.equatable()` 保护，于是 `MonthSelectionRingOverlay.body` 会随位移逐帧重求值 ——
/// 它身上的 `.transition(.opacity)` 因此永远拿不到稳定的前后两帧、退化成瞬切。
/// 现在环层只在 `selectedDate` 变化时重算，过渡动画才真正生效。
struct MonthSelectionRingLayer: View, Equatable {
    let month: Date
    let selectedDate: Date
    let availableSize: CGSize
    let containerWidth: CGFloat

    nonisolated static func == (lhs: MonthSelectionRingLayer, rhs: MonthSelectionRingLayer) -> Bool {
        lhs.month == rhs.month
            && lhs.selectedDate == rhs.selectedDate
            && lhs.availableSize == rhs.availableSize
            && lhs.containerWidth == rhs.containerWidth
    }

    private var height: CGFloat {
        MonthGridView.gridHeight(cellWidth: MonthGridView.cellWidth(availableSize: availableSize))
    }

    var body: some View {
        HStack(spacing: 0) {
            ring(delta: -1)
            ring(delta: 0)
            ring(delta: 1)
        }
        .frame(width: containerWidth * 3, height: height, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func ring(delta: Int) -> some View {
        MonthSelectionRingOverlay(month: CalendarUtils.addMonths(delta, to: month),
                                  selectedDate: selectedDate,
                                  availableSize: availableSize)
            .frame(width: containerWidth)
    }
}
