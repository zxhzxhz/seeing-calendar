#!/usr/bin/env swift
//
//  verify_ui_regressions.swift
//  界面回归门禁（CI 以 --strict 执行）。
//
//  钉四类用户实测报回来的界面回退：
//
//  ① 月份选择下拉面板（顶栏年月处点开）：3 列 × 4 行网格、年月归一化、高亮唯一性。
//  ② 面板下部月份区域的左右滑动切年：方向、阈值、主方向判定、一次只切一年。
//  ③ 年月标签不得带千位分隔符（「2,026年」）。
//  ④ 锁定贴图不得再画小锁角标；横屏主屏不得随键盘压缩。
//
//  ④ 里「横屏不得随键盘压缩」没法在 macOS 上真摆一台 iPad 出来量，所以走**文本护栏**：
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

/// 镜像 `MonthPickerPanel.yearStep(forSwipeX:y:)`。
///
/// 阈值之所以作为入参而不是直接取 44，是为了能在边界两侧各扎一针（43 / 44）；
/// 与生产常量的等值关系由 `verifyMonthPickerSource` 的文本护栏负责钉住。
func yearStep(forSwipeX dx: CGFloat, y dy: CGFloat, commit: CGFloat) -> Int {
    guard abs(dx) > abs(dy) else { return 0 }    // 主方向必须是横向
    guard abs(dx) >= commit else { return 0 }    // 距离必须够
    return dx < 0 ? 1 : -1                       // 往左滑 = 下一年
}

/// 镜像面板里 `Text(verbatim: "\(browsingYear)年")` 所走的格式化路径：
/// 普通 `String` 插值，**不经过** `LocalizedStringKey` 的数字本地化，因此没有千位分隔符。
func yearLabel(_ year: Int) -> String { "\(year)年" }

// MARK: - 源码读取与文本护栏工具

func productionSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

/// 把换行 / 连续空白压成单个空格，让文本护栏不受排版影响。
func normalizeWhitespace(_ source: String) -> String {
    source.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .joined(separator: " ")
}

/// 剥掉 `//` 行注释后压空白 —— 文本护栏一律拿它比对，不比对原始源码。
///
/// 为什么必须先剥注释：护栏要钉的是**代码**，不是散文。写这套护栏时被自己拦过一次 ——
/// 面板注释里那句「不要用某个编号字形」正好写了那个字形名，于是负向断言当场报错。
/// 而注释越写越像代码，恰恰是好注释的样子（本轮又有一例：注释里引用了
/// `Text("\(browsingYear)年")` 这个**反例**）。所以顺序只能是先剥注释再判。
///
/// 字符串字面量内部的 `//`（URL 之类）不算注释，靠 `inString` 状态排除。
func code(of source: String) -> String {
    var out = ""
    for line in source.components(separatedBy: "\n") {
        var visible = ""
        var inString = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if inString {
                visible.append(ch)
                if ch == "\\", index + 1 < chars.count {   // 转义：连同下一个字符一起吞掉
                    index += 1
                    visible.append(chars[index])
                } else if ch == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if ch == "\"" { inString = true; visible.append(ch); index += 1; continue }
            if ch == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
            visible.append(ch)
            index += 1
        }
        out += visible + "\n"
    }
    return normalizeWhitespace(out)
}

func occurrenceCount(_ haystack: String, _ needle: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

// MARK: - 断言 1：月份网格与高亮

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

// MARK: - 断言 2：滑动切年的判定

func verifyYearSwipeLogic() {
    let commit: CGFloat = 44

    // 方向语义：往左滑 = 下一年，与右侧翻年箭头同向。
    checkEqual(yearStep(forSwipeX: -60, y: 4, commit: commit), 1, "往左滑应当切到下一年")
    checkEqual(yearStep(forSwipeX: 60, y: 4, commit: commit), -1, "往右滑应当切到上一年")

    // 一次滑动只切一年：不按距离放大，免得一个快手滑直接飞出去好几年、还得再滑回来。
    checkEqual(yearStep(forSwipeX: -500, y: 2, commit: commit), 1, "长滑也只切一年")
    checkEqual(yearStep(forSwipeX: 500, y: 2, commit: commit), -1, "长滑也只切一年（反向）")

    // 主方向不是横向的一律不切年：竖直拖拽、斜拖都要放行给点击 / 滚动。
    checkEqual(yearStep(forSwipeX: 0, y: 80, commit: commit), 0, "竖直拖拽不得切年")
    checkEqual(yearStep(forSwipeX: 50, y: 70, commit: commit), 0, "斜向拖拽（竖向更长）不得切年")
    checkEqual(yearStep(forSwipeX: -50, y: 70, commit: commit), 0, "斜向拖拽（反向）不得切年")

    // 距离阈值边界：差一点不切，够线就切。
    checkEqual(yearStep(forSwipeX: -43, y: 0, commit: commit), 0, "横向 43pt 不足以切年")
    checkEqual(yearStep(forSwipeX: -44, y: 0, commit: commit), 1, "横向 44pt 正好够线，应当切年")

    // 轻微抖动当点击处理，不得跳年。
    checkEqual(yearStep(forSwipeX: -8, y: 6, commit: commit), 0, "点击抖动不得切年")

    // 阈值之间的关系：既要明显大于手势识别距离，又必须小于一个月份格的宽度。
    let recognition: CGFloat = 12
    check(commit > recognition, "切年距离（\(commit)pt）必须大于手势识别距离（\(recognition)pt）")
    // 月份格宽度由面板自己的尺寸常量推出来（3 列、列距 6、两侧各留 12）；
    // 这些常量与生产源码的等值关系由 verifyMonthPickerSource 的护栏钉住。
    let cellWidth = (CGFloat(296) - 2 * 12 - 2 * 6) / 3
    check(commit < cellWidth,
          "切年距离（\(commit)pt）必须小于一个月份格宽度（\(Int(cellWidth))pt），否则拇指够不到的短滑会失效")
}

// MARK: - 断言 3：年月标签不得带千位分隔符

func verifyYearLabelFormatting() {
    checkEqual(yearLabel(2026), "2026年", "★ 年份标签不得带千位分隔符（不得渲染成 2,026年）")
    check(!yearLabel(2026).contains(","), "年份标签里不得出现逗号")
    checkEqual(yearLabel(999), "999年", "三位年份同样不加分隔符")
    checkEqual(yearLabel(12345), "12345年", "五位年份同样不加分隔符")
}

// MARK: - 断言 4：面板源码的形态护栏

func verifyMonthPickerSource() {
    guard let panel = productionSource("SeeingCalendar/Views/MonthPickerPanel.swift") else {
        check(false, "读不到 SeeingCalendar/Views/MonthPickerPanel.swift（门禁必须在仓库根运行）")
        return
    }
    let src = code(of: panel)

    // ── 网格形态 ───────────────────────────────────────────────────────────
    check(src.contains("count: 3"), "面板必须是 3 列网格")
    check(src.contains("ForEach(1...12"), "面板必须铺满 1…12 月")
    check(src.contains("Color.accentColor"), "当前月高亮必须沿用 accentColor（不得引入新配色）")
    check(src.contains("design: .rounded"), "字体必须沿用 APP 的 rounded 体系")
    check(src.contains("browsingYear"), "翻年必须只改面板自己的年份，不得直接改动月历")
    // 编号字形（chevron 后面带序号的那种）在不同 SF Symbols 版本里不一定存在，
    // 缺字形时 SwiftUI 静默渲染空白 —— 界面上会出现两个点不动的隐形按钮。
    check(!src.contains("chevron.left.2") && !src.contains("chevron.right.2"),
          "★ 双箭头不得用编号字形，必须由两枚 chevron 叠出")

    // ── 数字标签必须走 verbatim 插值 ──────────────────────────────────────
    // `Text("\(year)年")` 是带插值的**字符串字面量**，会被当成 LocalizedStringKey，
    // 其中的 Int 按本地化数字格式化 → 年份被分组渲染成「2,026年」。
    check(occurrenceCount(src, "Text(verbatim:") >= 3,
          "年份、月份、无障碍标签都必须走 Text(verbatim:)，不得走本地化字符串字面量")
    check(!src.contains("Text(\"\\("),
          "★ 面板里不得出现带插值的 Text 字面量：那是 LocalizedStringKey 的数字本地化路径，会把年份渲染成 2,026年")
    checkEqual(occurrenceCount(src, ".monospacedDigit()"), 2,
               "年份与月份都必须等宽数字，避免换年时标题宽度抖动")

    // ── 滑动切年：挂在哪儿、走哪条路 ──────────────────────────────────────
    check(src.contains("DragGesture(minimumDistance: Self.swipeRecognitionDistance)"),
          "月份区域必须挂左右滑动，且识别距离要取命名常量")
    check(src.contains(".gesture(yearSwipeGesture)"), "滑动手势必须挂在月份网格那一层")
    check(src.contains("swipeRecognitionDistance: CGFloat = 12"),
          "手势识别距离必须是 12pt（与本门禁的第 2 组断言一致）")
    check(src.contains("swipeCommitDistance: CGFloat = 44"),
          "切年距离必须是 44pt（与本门禁的第 2 组断言一致）")
    check(src.contains("Self.yearStep(forSwipeX:"), "滑动判定必须复用 yearStep，不得在闭包里另写一套")
    checkEqual(occurrenceCount(src, "browsingYear += delta"), 1,
               "★ 浏览年份只能在 stepYear 里改一处：箭头与滑动共用同一条路径，动画与方向语义才不会分叉")

    // ── 切年动画的承载与裁剪 ──────────────────────────────────────────────
    check(src.contains(".id(browsingYear)"), "换年必须换网格身份，动画才有新旧两份")
    check(src.contains("ZStack {"),
          "★ 承载插入 / 移除两份网格的必须是 ZStack：换成 VStack 面板高度会先翻倍再回落")
    check(src.contains(".clipShape(RoundedRectangle(cornerRadius: Self.panelCornerRadius"),
          "★ 滑动动画必须被面板裁住，否则平移中的月份格会溢出到面板外面")
    check(src.contains("removal: .opacity"),
          "★ 离场动画不得带方向：离场侧的方向捕获自上一帧的状态，反向滑动时会有半张卡片走错边")

    // ── 尺寸常量（上面第 2 组断言里的格宽就是由它们算出来的）───────────────
    check(src.contains("panelWidth: CGFloat = 296"), "面板宽度常量必须是 296pt")
    check(src.contains(".padding(.horizontal, 12)"), "月份网格两侧留白必须是 12pt")
    check(src.contains("GridItem(.flexible(), spacing: 6)"), "月份网格列距必须是 6pt")
}

// MARK: - 断言 5：锁角标与键盘压缩的文本护栏

func verifyUIDefaultsAgainstRegression() {
    // ── 锁定贴图不得再画角标 ───────────────────────────────────────────────
    guard let entity = productionSource("SeeingCalendar/Canvas/ImageEntityView.swift") else {
        check(false, "读不到 ImageEntityView.swift")
        return
    }
    let entityCode = code(of: entity)
    check(!entityCode.contains("lock.fill"), "★ 锁定贴图不得再画锁图标（角标会一直压在用户画作上）")
    check(!entityCode.contains("lockBadge"), "锁角标连同它的布局代码都要清掉，不留死代码")
    check(entityCode.contains("private(set) var isLocked"), "锁定语义本身必须保留（不可选中 / 不可拖动）")
    check(entityCode.contains("if locked { setHighlighted(false) }"), "锁定仍应清掉选中高亮")

    // 去掉角标之后，锁定状态必须仍然可查、可解 —— 否则用户锁了贴图就再也解不回来。
    if let dayEditor = productionSource("SeeingCalendar/Views/DayEditorView.swift") {
        check(code(of: dayEditor).contains("解锁全部贴图"), "编辑器菜单必须仍有「解锁全部贴图（N）」入口")
    } else {
        check(false, "读不到 DayEditorView.swift")
    }
    if let selection = productionSource("SeeingCalendar/Canvas/SelectionOverlayView.swift") {
        check(code(of: selection).contains(".lock"), "贴图菜单必须仍有「锁定贴图」入口")
    } else {
        check(false, "读不到 SelectionOverlayView.swift")
    }

    // ── 横屏主屏不得随键盘压缩 ─────────────────────────────────────────────
    guard let root = productionSource("SeeingCalendar/Views/RootView.swift") else {
        check(false, "读不到 RootView.swift")
        return
    }
    let rootCode = code(of: root)
    check(rootCode.contains("private func landscapeLayout(width: CGFloat) -> some View"),
          "横屏布局不得再接收外部传入的（会被键盘压缩的）高度")
    check(rootCode.contains("height: proxy.size.height - 120"),
          "横屏网格高度必须在忽略键盘安全区的那一层重新量")
    checkEqual(occurrenceCount(rootCode, "ignoresSafeArea(.keyboard"), 1,
               "★ 键盘安全区只能被忽略一次（就在横屏分支里）：根部一旦也忽略，竖屏的便签输入框会被键盘盖住")
    check(rootCode.contains("ignoresSafeArea(.keyboard, edges: .bottom)"), "忽略的必须是底部键盘安全区")
    check(rootCode.contains("scrollDismissesKeyboard(.interactively)"), "竖屏的键盘避让不得被摘掉")

    // ── 月份面板的入口与收口 ───────────────────────────────────────────────
    check(rootCode.contains("MonthPickerPanel(month: month"), "顶栏年月必须能开面板")
    check(rootCode.contains("showMonthPicker.toggle()"), "年月标题本身必须是面板入口")
    check(rootCode.contains("private var monthPickerDismissLayer"), "面板必须有点面板以外关闭的收口层")
    check(rootCode.contains("private func pickMonth(_ target: Date)"), "必须有一个统一的跳月入口")
    check(rootCode.contains("CalendarUtils.isSameMonth"), "跳月必须复用同月判定，不得重复实现年月比较")
    check(rootCode.contains("overlay(alignment: .topLeading)"), "面板必须挂在顶栏年月的左上方")

    // ── 标题旁不得再放下拉小箭头 ───────────────────────────────────────────
    check(!rootCode.contains("chevron.down"),
          "★ 顶栏年月标题旁不得再放下拉小箭头：标题本身就是入口，箭头只是视觉噪音")
    check(!rootCode.contains("rotationEffect(.degrees(showMonthPicker"),
          "下拉箭头的翻转动画必须一并清掉，不留死代码")
}

// MARK: - 运行

verifyMonthPickerLogic()
verifyYearSwipeLogic()
verifyYearLabelFormatting()
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
