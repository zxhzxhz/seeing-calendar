#!/usr/bin/env swift
//
//  verify_input_mode.swift
//  画布输入模式机门禁（CI 以 --strict 执行）
//
//  钉的是「一条重载链靠一个探针脚本撑着」这类回退 —— 具体这几类：
//
//  【7 个互斥输入模式退化成两个独立字段】旧实现把导航 / 4 种笔 / 橡皮 / 套索编码成
//     `activeTool: CanvasTool?` × `isLassoActive: Bool`，合法组合没有任何类型约束，
//     `activeTool == .pen && isLassoActive == true` 这种野组合能被随便构造。本门禁
//     从两个方向钉死它：
//     ① `CanvasInputMode` 的 7 态纯逻辑语义（7×7 全转移穷举，不变量 1~4）；
//     ② 生产源码里 `activeTool` / `isLassoActive` 必须降级为只读投影（断言 0，文本护栏）。
//
//  【期望状态靠存储的影子副本】旧 `appliedToolSignature` 是「已下发的期望状态」的手写副本，
//     注释自己承认「之所以不用标志位，是因为它依赖属性观察器能否触发」。本门禁断言签名
//     由模式**纯计算**得出、且 7 个模式签名去重后仍是 7（不变量 6）。
//
//  【持久化层是第二份副本】旧 `lastSelectedTool` + `lastIsLassoActive` 两个键在 3 处写入。
//     本门禁断言新键 `editorTool.inputMode` 的单键往返、以及旧键读取路径必须保留（迁移）。
//
//  【M13：remembered 的两条更新规则被「顺手统一」】`select(tool:)` 只在目标不同时记下上一支，
//     而套索/导航（transition）不改变 remembered —— 这是刻意的差异（改动会改变边缘双击手感）。
//     本门禁把「两者必须分歧」写死。
//
//  【M9：单指归属的内联三元表达式】`(手指书写 && 会绘制) ? 2 : 1` 策略值无处存放。
//     本门禁用 (2 × 7) 真值表逐位钉死 `TouchRoutingPolicy`。
//
//  运行：swift scripts/verify_input_mode.swift [--strict]
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

/// 镜像 CanvasTool。
enum MTool: String, CaseIterable {
    case pen, monoline, marker, pencil, eraser
}

/// 镜像 CanvasInputMode。
enum MMode: Hashable {
    case navigation
    case ink(MTool)
    case eraser
    case lasso

    var tool: MTool? {
        switch self {
        case .navigation, .lasso: return nil
        case .ink(let tool): return tool
        case .eraser: return .eraser
        }
    }

    var isLassoActive: Bool { self == .lasso }

    var drawsWithFinger: Bool {
        switch self {
        case .navigation: return false
        case .ink, .eraser, .lasso: return true
        }
    }

    var storageToken: String {
        switch self {
        case .navigation: return "navigation"
        case .ink(let tool): return "ink.\(tool.rawValue)"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    static func fromToken(_ token: String?) -> MMode? {
        guard let token, !token.isEmpty else { return nil }
        if token == "navigation" { return .navigation }
        if token == "eraser" { return .eraser }
        if token == "lasso" { return .lasso }
        if token.hasPrefix("ink.") {
            let raw = String(token.dropFirst("ink.".count))
            guard let tool = MTool(rawValue: raw), tool != .eraser else { return nil }
            return .ink(tool)
        }
        return nil
    }
}

/// 镜像 CanvasInputModePolicy（模式部分）。remembered 部分另见下面的两个纯函数。
enum MPolicy {
    static func signature(_ mode: MMode) -> String {
        switch mode {
        case .navigation: return "navigation"
        case .ink(let tool): return "ink:\(tool.rawValue)"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    static func transition(from current: MMode, to requested: MMode) -> MMode {
        _ = current
        return requested
    }

    static func selecting(tool: MTool?, from current: MMode) -> MMode {
        guard let tool else { return .navigation }
        let target: MMode = (tool == .eraser) ? .eraser : .ink(tool)
        return target == current ? .navigation : target
    }

    static func togglingLasso(from current: MMode) -> MMode {
        current == .lasso ? .navigation : .lasso
    }

    /// 模式 → 边缘切换目标类型名（导航态沿用旧的「按钢笔算」）。
    static func edgeTargetName(_ mode: MMode) -> String {
        switch mode {
        case .lasso: return "lasso"
        case .eraser: return "eraser"
        case .navigation: return "pen"
        case .ink(let tool): return tool.rawValue
        }
    }
}

// MARK: - M13：remembered 的两条**刻意不同**的更新规则（EditorModel 的镜像）

/// 镜像 EditorModel.select(tool:)：只有「落到某个绘制工具」且目标与上一支不同才记下上一支。
/// （取消到导航态不动 remembered —— 逐位等价旧 `if nextTool != nil && nextTarget != prev`。）
func rememberedAfterSelecting(tool: MTool?, from current: MMode, previous: String?) -> String? {
    let nextMode = MPolicy.selecting(tool: tool, from: current)
    guard nextMode != .navigation else { return previous }
    let nextTarget = MPolicy.edgeTargetName(nextMode)
    let prevTarget = MPolicy.edgeTargetName(current)
    return nextTarget != prevTarget ? prevTarget : previous
}

/// 镜像 EditorModel.switchTo(.lasso) / transition：**不改变** remembered
///（不论切到哪个模式；笔与橡皮走 select，另有规则）。
func rememberedAfterTransition(to target: MMode, previous: String?) -> String? {
    _ = target
    return previous
}

// MARK: - M9：单指路由（TouchRoutingPolicy 的镜像）

enum MRouting: Equatable {
    case pansCanvas
    case drawsOnCanvas
}

func fingerRouting(isFingerDrawingEnabled: Bool, inputMode: MMode) -> MRouting {
    (isFingerDrawingEnabled && inputMode.drawsWithFinger) ? .drawsOnCanvas : .pansCanvas
}

func panTouches(for routing: MRouting) -> Int {
    routing == .drawsOnCanvas ? 2 : 1
}

// MARK: - 破坏变体：旧实现的形状（两个独立字段，允许野组合）

/// 旧实现：`activeTool` 与 `isLassoActive` 各自独立、无类型约束。
/// 于是 `activeTool == .pen && isLassoActive == true`（既在画钢笔、又开着套索）也能被构造出来。
struct BrokenInputMode: Equatable {
    var activeTool: MTool?
    var isLassoActive: Bool

    var tool: MTool? { activeTool }

    var signature: String { "\(activeTool?.rawValue ?? "none")|\(isLassoActive)" }

    /// 旧 toggleLasso：翻转 lasso，但**不碰** activeTool（工具残留在台面上）。
    func togglingLasso() -> BrokenInputMode {
        BrokenInputMode(activeTool: activeTool, isLassoActive: !isLassoActive)
    }
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

// MARK: - 测试用的 7 个模式

let allModes: [MMode] = [
    .navigation,
    .ink(.pen),
    .ink(.monoline),
    .ink(.marker),
    .ink(.pencil),
    .eraser,
    .lasso
]

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    // ---- 纯逻辑模式机文件 ----
    let modeSource = productionSource("SeeingCalendar/Views/CanvasInputMode.swift") ?? ""
    check(modeSource.contains("enum CanvasInputMode: Equatable, Sendable"),
          "CanvasInputMode 必须仍是 Equatable + Sendable 的纯值类型")
    check(modeSource.contains("case navigation"), "CanvasInputMode 必须保留 .navigation")
    check(modeSource.contains("case ink(CanvasTool)"), "CanvasInputMode 必须保留 .ink(CanvasTool)")
    check(modeSource.contains("case eraser"), "CanvasInputMode 必须保留 .eraser")
    check(modeSource.contains("case lasso"), "CanvasInputMode 必须保留 .lasso")
    check(modeSource.contains("var tool: CanvasTool?"), "tool 投影必须存在")
    check(modeSource.contains("var isLassoActive: Bool { self == .lasso }"),
          "isLassoActive 投影必须严格等价于 .lasso")
    check(modeSource.contains("var drawsWithFinger: Bool"), "drawsWithFinger 投影必须存在")
    check(modeSource.contains("var storageToken: String"), "storageToken 必须存在")
    check(modeSource.contains("static func fromStorageToken(_ token: String?) -> CanvasInputMode?"),
          "必须有容错的存储令牌解码入口")
    check(modeSource.contains("enum CanvasInputModePolicy"), "必须有转移策略类型")
    check(modeSource.contains("static func signature(of mode: CanvasInputMode) -> String"),
          "签名必须是模式到字符串的纯函数")
    check(modeSource.contains("static func transition(from current: CanvasInputMode, to requested: CanvasInputMode) -> CanvasInputMode"),
          "必须存在 transition 转移函数")
    check(modeSource.contains("static func selecting(tool: CanvasTool?, from current: CanvasInputMode) -> CanvasInputMode"),
          "必须存在 selecting 转移函数")
    check(modeSource.contains("static func togglingLasso(from current: CanvasInputMode) -> CanvasInputMode"),
          "必须存在 togglingLasso 转移函数")
    check(modeSource.contains("static func switching(from current: CanvasInputMode,"),
          "必须存在边缘双击的 switching 决策函数")

    // ---- EditorModel：单一真值 + 只读投影 ----
    let editorSource = productionSource("SeeingCalendar/Views/EditorModel.swift") ?? ""
    check(editorSource.contains("var inputMode: CanvasInputMode = .ink(.pen)"),
          "inputMode 必须是唯一可写的模式真值")
    check(editorSource.contains("var activeTool: CanvasTool? { inputMode.tool }"),
          "activeTool 必须降级为只读计算投影")
    check(editorSource.contains("var isLassoActive: Bool { inputMode.isLassoActive }"),
          "isLassoActive 必须降级为只读计算投影")
    check(editorSource.contains("CanvasInputModePolicy.signature(of: inputMode)"),
          "期望指纹的模式部分必须由 inputMode 纯计算得出")
    check(editorSource.contains("private func applyInputMode(_ mode: CanvasInputMode)"),
          "必须有唯一的模式应用管线")
    check(editorSource.contains("CanvasInputModePolicy.selecting(tool: tool, from: inputMode)"),
          "select(tool:) 必须走 selecting 转移")
    check(editorSource.contains("CanvasInputModePolicy.togglingLasso(from: inputMode)"),
          "toggleLasso 必须走 togglingLasso 转移")
    check(editorSource.contains("host.canvas.inputMode = inputMode"),
          "inputMode 必须沿既有通道下发给画布")

    // ---- ToolSettingsStore：新键单条往返 + 旧键只读迁移路径 ----
    let storeSource = productionSource("SeeingCalendar/Store/ToolSettingsStore.swift") ?? ""
    check(storeSource.contains("var inputMode: CanvasInputMode?"),
          "必须新增 inputMode 持久化键（读写单个键）")
    check(storeSource.contains("static let inputMode = \"editorTool.inputMode\""),
          "inputMode 必须写进独立的新键")
    check(storeSource.contains("var lastSelectedTool: CanvasTool? {"),
          "旧键 lastSelectedTool 的读取路径必须保留（一次性迁移）")
    check(storeSource.contains("var lastIsLassoActive: Bool {"),
          "旧键 lastIsLassoActive 的读取路径必须保留（一次性迁移）")

    // ---- CanvasHostView：M9 路由走策略函数 ----
    let hostSource = productionSource("SeeingCalendar/Canvas/CanvasHostView.swift") ?? ""
    check(hostSource.contains("TouchRoutingPolicy.panMinimumNumberOfTouches("),
          "触控策略必须委派给 TouchRoutingPolicy（不再内联三元表达式）")

    let routingSource = productionSource("SeeingCalendar/Canvas/TouchRoutingPolicy.swift") ?? ""
    check(routingSource.contains("enum FingerRouting: Equatable, Sendable"),
          "FingerRouting 必须是 Equatable + Sendable 的纯值类型")
    check(routingSource.contains("case pansCanvas"), "FingerRouting 必须保留 .pansCanvas")
    check(routingSource.contains("case drawsOnCanvas"), "FingerRouting 必须保留 .drawsOnCanvas")
    check(routingSource.contains("static func fingerRouting(isFingerDrawingEnabled: Bool, inputMode: CanvasInputMode) -> FingerRouting"),
          "单指归属判定必须是独立可测的纯函数")
    check(routingSource.contains("static func panMinimumNumberOfTouches(for routing: FingerRouting) -> Int"),
          "触点数映射必须是纯函数")
    check(routingSource.contains("static func panMinimumNumberOfTouches(isFingerDrawingEnabled: Bool, inputMode: CanvasInputMode) -> Int"),
          "必须提供便捷组合入口")
    check(routingSource.contains("routing == .drawsOnCanvas ? 2 : 1"),
          "触点数映射必须逐位等价旧三元表达式")

    // ---- 容器：inputMode 沿既有通道下发 ----
    let containerSource = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") ?? ""
    check(containerSource.contains("var inputMode: CanvasInputMode = .navigation"),
          "容器必须承载下发的 inputMode（沿用 isFingerDrawingEnabled 那条通道）")

    // ---- 负向护栏：旧存储声明不得回潮 ----
    check(!editorSource.contains("var activeTool: CanvasTool? ="),
          "★ activeTool 不得回退为带初值的存储属性（真值必须是 inputMode）")
    check(!editorSource.contains("var isLassoActive = false"),
          "★ isLassoActive 不得回退为存储属性（真值必须是 inputMode）")
}

// MARK: - 断言 1：7×7 全转移穷举（不变量 1~4、6）

func verifySevenBySevenTransitions() {
    let inkTools: [MTool] = [.pen, .monoline, .marker, .pencil]

    for from in allModes {
        for to in allModes {
            let label = "\(from) × \(to)"
            // transition：模式互斥，请求即结果。
            checkEqual(MPolicy.transition(from: from, to: to), to, "\(label)：transition 请求即结果")
            // 结果必属 7 态之一 —— 签名与模式一一对应（不再需要观察器/影子副本）。
            check(allModes.map(MPolicy.signature).contains(MPolicy.signature(MPolicy.transition(from: from, to: to))),
                  "\(label)：transition 结果的签名必须对应合法模式")
        }

        // 不变量 1：nil → 导航态。
        checkEqual(MPolicy.selecting(tool: nil, from: from), .navigation,
                   "selecting(nil, from: \(from)) 必须回到导航态")
    }

    // 不变量 1：再点一次当前笔 → 导航态；否则 → 该笔。
    for tool in inkTools {
        for from in allModes {
            let expected: MMode = (from == .ink(tool)) ? .navigation : .ink(tool)
            checkEqual(MPolicy.selecting(tool: tool, from: from), expected,
                       "selecting(\(tool.rawValue), from: \(from))")
            check(allModes.contains(MPolicy.selecting(tool: tool, from: from)),
                  "selecting(\(tool.rawValue), from: \(from)) 的结果必属 7 态")
        }
    }

    // 不变量 2：橡皮是独立模式；再点一次橡皮也取消（现有 toggle 语义）。
    for from in allModes {
        let expected: MMode = (from == .eraser) ? .navigation : .eraser
        checkEqual(MPolicy.selecting(tool: .eraser, from: from), expected,
                   "selecting(eraser, from: \(from)) 必须落到独立的 .eraser（非 .ink(.eraser)）")
        check(MPolicy.selecting(tool: .eraser, from: from) != .ink(.eraser),
              "selecting(eraser, from: \(from)) 绝不允许落到 .ink(.eraser)")
    }

    // 不变量 3：套索开关。
    for from in allModes {
        let expected: MMode = (from == .lasso) ? .navigation : .lasso
        checkEqual(MPolicy.togglingLasso(from: from), expected, "togglingLasso(from: \(from))")
        check(allModes.contains(MPolicy.togglingLasso(from: from)),
              "togglingLasso(from: \(from)) 的结果必属 7 态")
    }
}

// MARK: - 断言 2：签名唯一性（不变量 6）

func verifySignatureUniqueness() {
    let signatures = allModes.map(MPolicy.signature)
    checkEqual(signatures.count, 7, "必须恰有 7 个模式")
    checkEqual(Set(signatures).count, 7, "★ 7 个模式的签名去重后必须仍为 7")
    checkEqual(Set(allModes).count, 7, "7 个模式本身必须互不相同")

    // 签名 → 模式的反查唯一：任意路径后「签名与模式一一对应」。
    var bySignature: [String: MMode] = [:]
    for mode in allModes { bySignature[MPolicy.signature(mode)] = mode }
    for mode in allModes {
        checkEqual(bySignature[MPolicy.signature(mode)], mode,
                   "签名必须唯一映射回模式（\(mode)）")
    }
    // 任意转移之后，签名仍必须对应那个模式。
    for from in allModes {
        for tool in MTool.allCases {
            let after = MPolicy.selecting(tool: tool, from: from)
            checkEqual(bySignature[MPolicy.signature(after)], after,
                       "selecting 之后签名必须仍一一对应")
        }
        let toggled = MPolicy.togglingLasso(from: from)
        checkEqual(bySignature[MPolicy.signature(toggled)], toggled,
                   "togglingLasso 之后签名必须仍一一对应")
    }
}

// MARK: - 断言 3：持久化往返

func verifyStorageRoundTrip() {
    for mode in allModes {
        checkEqual(MMode.fromToken(mode.storageToken), mode,
                   "模式 \(mode) 的 storageToken 必须能逐位还原")
    }
    checkEqual(MMode.fromToken(nil), nil, "nil 令牌必须容错返回 nil（不崩）")
    checkEqual(MMode.fromToken(""), nil, "空令牌必须容错返回 nil")
    checkEqual(MMode.fromToken("乱码"), nil, "乱码令牌必须容错返回 nil")
    checkEqual(MMode.fromToken("ink.eraser"), nil, "ink.eraser 非法（橡皮是独立模式）")
    checkEqual(MMode.fromToken("ink.bogus"), nil, "未知笔名必须容错返回 nil")
    checkEqual(MMode.fromToken("INK.pen"), nil, "大小写敏感：无效令牌必须返回 nil")
}

// MARK: - 断言 4：M13 —— 两条 remembered 规则**必须分歧**

func verifyRememberedDivergence() {
    // transition 到套索 / 导航（以及任何模式）不改变 remembered。
    for previous in ["pen", "eraser", "lasso", "marker", nil] as [String?] {
        for target in allModes {
            checkEqual(rememberedAfterTransition(to: target, previous: previous), previous,
                       "★ transition 到 \(target) 不得改变 remembered")
        }
    }

    // select 到不同工具时必须记下「上一支」。
    checkEqual(rememberedAfterSelecting(tool: .marker, from: .ink(.pen), previous: "eraser"), "pen",
               "★ select 到不同工具必须把上一支记下（此处上一支是 pen）")
    checkEqual(rememberedAfterSelecting(tool: .eraser, from: .ink(.pen), previous: "monoline"), "pen",
               "★ select 到橡皮也必须把上一支记下")
    // select 取消到导航态：不动 remembered。
    checkEqual(rememberedAfterSelecting(tool: .pen, from: .ink(.pen), previous: "marker"), "marker",
               "★ select 取消到导航态不得改变 remembered")
    // select 到同一支：目标与上一支相同，不动 remembered。
    checkEqual(rememberedAfterSelecting(tool: .pen, from: .ink(.marker), previous: "marker"), "marker",
               "★ select 到同一支时不动 remembered")

    // ★ 两条规则必须分歧：同一输入下，select 改了、transition 没改。
    let previous = "eraser"
    let viaSelecting = rememberedAfterSelecting(tool: .marker, from: .ink(.pen), previous: previous)
    let viaTransition = rememberedAfterTransition(to: .lasso, previous: previous)
    check(viaSelecting != viaTransition,
          "★ select 与 transition 的 remembered 规则必须分歧（把「不许统一」写死）")
    checkEqual(viaSelecting, "pen", "分歧点：select 记下了上一支 pen")
    checkEqual(viaTransition, "eraser", "分歧点：transition 保持原 remembered 不变")
}

// MARK: - 断言 5：M9 —— (2 × 7) 全组合真值表

func verifyTouchRouting() {
    for finger in [false, true] {
        for mode in allModes {
            let routing = fingerRouting(isFingerDrawingEnabled: finger, inputMode: mode)
            let expectedTouches = (finger && mode.drawsWithFinger) ? 2 : 1
            // 与旧内联三元表达式逐位等价。
            let legacy = (finger && mode.drawsWithFinger) ? 2 : 1
            checkEqual(panTouches(for: routing), legacy,
                       "panTouches(finger=\(finger), \(mode)) 必须逐位等价旧三元表达式")
            checkEqual(panTouches(for: routing), expectedTouches,
                       "panTouches(finger=\(finger), \(mode)) 期望值")
            // 归属与触点数一一对应。
            checkEqual(routing == .drawsOnCanvas, expectedTouches == 2,
                       "routing 与触点数必须一一对应（\(mode)）")
            // 只有「偏好为真 且 模式会绘制」才把单指留给画布。
            checkEqual(routing == .drawsOnCanvas, finger && mode.drawsWithFinger,
                       "单指归画布必须恰是「手指书写开 且 模式会绘制」")
        }
    }
    // 导航态：无论偏好如何，单指一律归平移。
    checkEqual(panTouches(for: fingerRouting(isFingerDrawingEnabled: true, inputMode: .navigation)), 1,
               "导航态即使开着手指书写也必须单指平移（drawsWithFinger == false）")
    // 两个维度正交：偏好为假时，即使模式会绘制也不归画布。
    checkEqual(panTouches(for: fingerRouting(isFingerDrawingEnabled: false, inputMode: .ink(.pen))), 1,
               "手指书写关闭时必须单指平移")
    checkEqual(panTouches(for: fingerRouting(isFingerDrawingEnabled: true, inputMode: .ink(.pen))), 2,
               "手指书写开启且画笔模式时必须双指平移（单指留给绘制）")
}

// MARK: - 断言 6：反证 —— 两个独立字段的破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    let correctSignatures = Set(allModes.map(MPolicy.signature))

    // ① 破坏变体允许「工具与套索同时成立」的野组合，正确实现无法表达。
    let wild = BrokenInputMode(activeTool: .pen, isLassoActive: true)
    check(!correctSignatures.contains(wild.signature),
          "★ 破坏变体允许 `activeTool == .pen && isLassoActive == true`，正确实现无法表达")

    // ② 至少一个转移上必然分歧：旧 toggleLasso 翻转 lasso 却把工具留在台面上。
    let brokenAfter = BrokenInputMode(activeTool: .pen, isLassoActive: false).togglingLasso()
    let correctAfter = MPolicy.togglingLasso(from: .ink(.pen))
    checkEqual(brokenAfter.tool, .pen, "破坏变体 toggleLasso 之后仍留着钢笔")
    checkEqual(correctAfter.tool, nil, "正确实现 toggleLasso 之后工具必须为 nil（7 态互斥）")
    check(brokenAfter.tool != correctAfter.tool,
          "★ 破坏变体必须与正确实现在至少一个转移上分歧")
    check(brokenAfter.isLassoActive && correctAfter == .lasso,
          "破坏变体与正确实现在套索标志上都为真 —— 分歧点恰是「工具是否残留」")
    check(!correctSignatures.contains(brokenAfter.signature),
          "★ 破坏变体 toggleLasso 后仍是野组合（钢笔 + 套索），正确实现无法表达")

    // ③ 检查器不得退化成恒真。
    check(checks > 100, "断言数量必须足够大（实际 \(checks) 条），否则等于没查")
    check(Set(allModes.map(MPolicy.signature)).count == 7,
          "★ 正确实现的 7 个签名必须互不相同，否则反证本身失效")
    check(BrokenInputMode(activeTool: .pen, isLassoActive: true).signature
            != MPolicy.signature(.lasso),
          "★ 野组合的签名不得恰好撞上某个合法模式 —— 否则检查器抓不到")
}

// MARK: - 运行

verifySourceGuardrails()
verifySevenBySevenTransitions()
verifySignatureUniqueness()
verifyStorageRoundTrip()
verifyRememberedDivergence()
verifyTouchRouting()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 输入模式机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
