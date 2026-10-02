#!/usr/bin/env swift
//
//  verify_ui_regressions.swift
//  界面回归门禁（CI 以 --strict 执行）。
//
//  钉三类用户实测报回来的界面回退：
//
//  ① 月份选择下拉面板（顶栏年月处点开）：3 列 × 4 行网格、年月归一化、高亮唯一性。
//  ② 锁定贴图不得再画小锁角标：那枚锁会一直压在用户的画作上，骚扰大于信息量。
//  ③ 横屏主屏不得随键盘压缩：在「新建维度 / 新增日历」的输入框里唤起键盘时，
//     键盘安全区压掉了容器高度，而横屏网格尺寸正是由这个高度算出来的，
//     于是主屏日历格子跟着缩（竖屏是 ScrollView，所以看不出来）。
//
//  ③ 这类问题没法在 macOS 上真摆一台 iPad 出来量，所以走**文本护栏**：
//  断言的是「键盘安全区有且只有一处被忽略，就在横屏分支里」这个结构事实。
//  它拦不住所有写法，但拦得住最可能发生的那种回退 —— 顺手在根部也加一个。
//
//      swift scripts/verify_ui_regressions.swift --strict
//
import Foundation

// MARK: - 迷你断言框架

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    checks += 1
    if lhs != rhs { failures.append("\(label)：期望 \(rhs)，实际 \(lhs)") }
}

// MARK: - 被测逻辑（生产代码的镜像）

private let gateCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return cal
}()

/// 镜像 `CalendarUtils.startOfMonth(year:month:)`。
func monthStart(year: Int, month: Int) -> Date {
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = 1
    return gateCalendar.date(from: parts)!
}

/// 镜像 `CalendarUtils.isSameMonth(_:_:)`。
func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
    gateCalendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
}

func stamp(_ date: Date) -> String {
    let parts = gateCalendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

/// 镜像面板的月份格子：3 列、行优先填充。
func monthRows() -> [[Int]] {
    let values = Array(1...12)
    let perRow = 3
    return stride(from: 0, to: values.count, by: perRow)
        .map { Array(values[$0..<min($0 + perRow, values.count)]) }
}

/// 高亮判定，与 `MonthPickerPanel.monthCell(_:)` 的 `isCurrent` 逐字对应。
func isHighlighted(month value: Int, browsingYear: Int, current: Date) -> Bool {
    browsingYear == gateCalendar.component(.year, from: current)
        && value == gateCalendar.component(.month, from: current)
}

// MARK: - 文本护栏工具

func productionSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

/// 把换行 / 连续空白压成单个空格，让文本护栏不受排版影响。
func normalizeWhitespace(_ source: String) -> String {
    source.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .joined(separator: " ")
}

func occurrenceCount(_ haystack: String, _ needle: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

// MARK: - 断言 1：月份选择面板的网格与高亮

func verifyMonthPickerLogic() {
    checkEqual(monthRows().count, 4, "月份网格必须是 4 行（12 ÷ 3）")
    check(monthRows().allSatisfy { $0.count == 3 }, "月份网格每行必须是 3 格")
    checkEqual(monthRows().flatMap { $0 }, Array(1...12), "月份必须按 1…12 行优先铺满")

    checkEqual(stamp(monthStart(year: 2026, month: 1)), "2026-01-01", "1 月归一化到当月首日")
    checkEqual(stamp(monthStart(year: 2026, month: 2)), "2026-02-01", "2 月归一化到 1 号（不得溢出到 3/2）")
    checkEqual(stamp(monthStart(year: 2024, month: 2)), "2024-02-01", "闰年 2 月同样归一化到 1 号")
    checkEqual(stamp(monthStart(year: 2026, month: 12)), "2026-12-01", "12 月归一化到 1 号（不得溢出到下一年）")

    check(isSameMonth(monthStart(year: 2026, month: 3), monthStart(year: 2026, month: 3)), "同月判定必须为真")
    check(!isSameMonth(monthStart(year: 2026, month: 1), monthStart(year: 2025, month: 1)),
          "跨年的同月号不算同月（否则跳月会被误判成没变化）")
    check(!isSameMonth(monthStart(year: 2025, month: 12), monthStart(year: 2026, month: 1)),
          "相邻月不算同月")

    // 高亮唯一性：扫遍 12 个月 × 两个浏览年份。
    for value in 1...12 {
        let current = monthStart(year: 2026, month: value)
        let hits = (1...12).filter { isHighlighted(month: $0, browsingYear: 2026, current: current) }
        checkEqual(hits, [value], "2026 年浏览时应当只有 \(value) 月高亮")
        let stray = (1...12).filter { isHighlighted(month: $0, browsingYear: 2027, current: current) }
        check(stray.isEmpty, "\(value) 月：浏览别的年份时不得有任何格子高亮（否则用户会以为月历已经跳到那一年）")
    }
}

// MARK: - 断言 2：面板源码的形态护栏

func verifyMonthPickerSource() {
    guard let panel = productionSource("SeeingCalendar/Views/MonthPickerPanel.swift") else {
        check(false, "读不到 SeeingCalendar/Views/MonthPickerPanel.swift（门禁必须在仓库根运行）")
        return
    }
    check(panel.contains("count: 3"), "面板必须是 3 列网格")
    check(panel.contains("ForEach(1...12"), "面板必须铺满 1…12 月")
    check(panel.contains("Color.accentColor"), "当前月高亮必须沿用 accentColor（不得引入新配色）")
    check(panel.contains("design: .rounded"), "字体必须沿用 APP 的 rounded 体系")
    check(panel.contains("browsingYear"), "翻年必须只改面板自己的年份，不得直接改动月历")
    // 编号字形（chevron.left.2 之类）在不同 SF Symbols 版本里不一定存在，
    // 缺字形时 SwiftUI 静默渲染空白 —— 界面上会出现两个点不动的隐形按钮。
    check(!panel.contains("chevron.left.2") && !panel.contains("chevron.right.2"),
          "★ 双箭头不得用编号字形，必须由两枚 chevron 叠出")
}

// MARK: - 断言 3：弹簧锁角标与键盘压缩的文本护栏

func verifyUIDefaultsAgainstRegression() {
    // ── ② 锁定贴图不得再画角标 ─────────────────────────────────────────────
    guard let entity = productionSource("SeeingCalendar/Canvas/ImageEntityView.swift") else {
        check(false, "读不到 ImageEntityView.swift")
        return
    }
    check(!entity.contains("lock.fill"), "★ 锁定贴图不得再画锁图标（角标会一直压在用户画作上）")
    check(!entity.contains("lockBadge"), "锁角标连同它的布局代码都要清掉，不留死代码")
    check(entity.contains("private(set) var isLocked"), "锁定语义本身必须保留（不可选中 / 不可拖动）")
    check(entity.contains("if locked { setHighlighted(false) }"), "锁定仍应清掉选中高亮")

    // 去掉角标之后，锁定状态必须仍然可查、可解 —— 否则用户锁了贴图就再也解不回来。
    if let dayEditor = productionSource("SeeingCalendar/Views/DayEditorView.swift") {
        check(dayEditor.contains("解锁全部贴图"), "编辑器菜单必须仍有「解锁全部贴图（N）」入口")
    } else {
        check(false, "读不到 DayEditorView.swift")
    }
    if let selection = productionSource("SeeingCalendar/Canvas/SelectionOverlayView.swift") {
        check(selection.contains(".lock"), "贴图菜单必须仍有「锁定贴图」入口")
    } else {
        check(false, "读不到 SelectionOverlayView.swift")
    }

    // ── ③ 横屏主屏不得随键盘压缩 ───────────────────────────────────────────
    guard let root = productionSource("SeeingCalendar/Views/RootView.swift") else {
        check(false, "读不到 RootView.swift")
        return
    }
    let flat = normalizeWhitespace(root)
    check(flat.contains("private func landscapeLayout(width: CGFloat) -> some View"),
          "横屏布局不得再接收外部传入的（会被键盘压缩的）高度")
    check(flat.contains("height: proxy.size.height - 120"),
          "横屏网格高度必须在忽略键盘安全区的那一层重新量")
    checkEqual(occurrenceCount(flat, "ignoresSafeArea(.keyboard"), 1,
               "★ 键盘安全区只能被忽略一次（就在横屏分支里）：根部一旦也忽略，竖屏的便签输入框会被键盘盖住")
    check(flat.contains("ignoresSafeArea(.keyboard, edges: .bottom)"), "忽略的必须是底部键盘安全区")
    check(flat.contains("scrollDismissesKeyboard(.interactively)"), "竖屏的键盘避让不得被摘掉")

    // ── ① 面板的入口与收口 ────────────────────────────────────────────────
    check(flat.contains("MonthPickerPanel(month: month"), "顶栏年月必须能开面板")
    check(flat.contains("showMonthPicker.toggle()"), "年月标题本身必须是面板入口")
    check(flat.contains("private var monthPickerDismissLayer"), "面板必须有点面板以外关闭的收口层")
    check(flat.contains("private func pickMonth(_ target: Date)"), "必须有一个统一的跳月入口")
    check(flat.contains("CalendarUtils.isSameMonth"), "跳月必须复用同月判定，不得重复实现年月比较")
    check(flat.contains("overlay(alignment: .topLeading)"), "面板必须挂在顶栏年月的左上方")
}

// MARK: - 运行

verifyMonthPickerLogic()
verifyMonthPickerSource()
verifyUIDefaultsAgainstRegression()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 界面回归：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
