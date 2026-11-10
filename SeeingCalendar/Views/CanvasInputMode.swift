import Foundation

/// 画布输入模式：**7 个互斥状态的唯一真值**。
///
/// 为什么需要它：旧实现把 7 个互斥输入模式编码成两个**互相独立、没有任何类型约束**的字段 ——
/// `activeTool: CanvasTool?` × `isLassoActive: Bool`：
/// `nil + false` = 导航；`pen/monoline/marker/pencil + false` = 4 种笔；
/// `eraser + false` = 橡皮；`nil + true` = 套索。
///
/// 合法组合只存在于作者脑子里：`activeTool == .pen && isLassoActive == true` 这种
/// 「既在画钢笔、又开着套索」的野组合能被随便构造出来，而三处手写代码
/// （`select(tool:)` / `toggleLasso()` / `switchTo(target:)`）各自靠约定记住
/// 「进套索先清工具、选工具先退套索」—— 少记一处就会漂移。
/// 把 7 态收成一个枚举后，「工具与套索同时成立」变成**不可表达**，
/// 合法状态由类型而非约定保证。
enum CanvasInputMode: Equatable, Sendable {
    /// 导航态：不落笔，单指平移。
    case navigation
    /// 4 种画笔（pen / monoline / marker / pencil）。
    case ink(CanvasTool)
    /// 橡皮（独立成相，因为它有自己的擦除模式与有效范围）。
    case eraser
    /// 套索。
    case lasso

    /// 下发给 PencilKit 的工具（导航态与套索态为 nil）。
    var tool: CanvasTool? {
        switch self {
        case .navigation, .lasso: return nil
        case .ink(let tool): return tool
        case .eraser: return .eraser
        }
    }

    /// 是否处于套索态。
    var isLassoActive: Bool { self == .lasso }

    /// 该模式是否把单指交给画布绘制（导航态为 false → 单指平移）。
    ///
    /// 逐位等价于旧 `setNavigationMode` 驱动的 `canvas.isDrawingEnabled`（= 非导航态）。
    var drawsWithFinger: Bool {
        switch self {
        case .navigation: return false
        case .ink, .eraser, .lasso: return true
        }
    }

    /// 持久化令牌（用于 UserDefaults 往返）。
    var storageToken: String {
        switch self {
        case .navigation: return "navigation"
        case .ink(let tool): return "ink.\(tool.rawValue)"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    /// 从持久化令牌还原。缺失 / 乱码一律返回 nil（容错，不崩）。
    ///
    /// `ink.eraser` 也视为非法（橡皮是独立模式，不该从笔的通道进来）。
    static func fromStorageToken(_ token: String?) -> CanvasInputMode? {
        guard let token, !token.isEmpty else { return nil }
        if token == "navigation" { return .navigation }
        if token == "eraser" { return .eraser }
        if token == "lasso" { return .lasso }
        if token.hasPrefix("ink.") {
            let raw = String(token.dropFirst("ink.".count))
            guard let tool = CanvasTool(rawValue: raw), tool != .eraser else { return nil }
            return .ink(tool)
        }
        return nil
    }
}

/// 输入模式机的转移（纯逻辑，可被 `scripts/verify_input_mode.swift` 直接镜像并穷举验证）。
///
/// 固化的不变量（**逐位等价于旧三处手写逻辑，一条都不许改**）：
///
/// 1. `selecting(tool: nil, from:)` → `.navigation`；`selecting(tool: some, from: .ink(same))`
///    → `.navigation`（再点一次取消，现有 toggle 语义）；`selecting(tool: some, from: 其它)`
///    → `.ink(some)`。橡皮同理：`selecting(.eraser, from: .eraser)` → `.navigation`。
/// 2. `selecting(.eraser, from: 非橡皮)` → `.eraser`（橡皮是独立模式，绝不落到 `.ink(.eraser)`）。
/// 3. `togglingLasso(from: .lasso)` → `.navigation`；`togglingLasso(from: 非 lasso)` → `.lasso`。
/// 4. `transition(to:)` **只**回报请求的模式（模式互斥，请求即结果），它本身不承载
///    remembered 的更新；remembered（`previousToolType`）的更新规则在调用方，且
///    「切到套索/导航不动 remembered」与「select 到不同工具才记下上一支」是**刻意的差异**
///    （见 `switching` 与 EditorModel 的注释），**不许统一**。
/// 5. `drawsWithFinger`：`.navigation == false`，其余 == `true`。
/// 6. `signature(of:)` 必须能区分全部 7 个模式（去重后仍是 7 个）。
enum CanvasInputModePolicy {
    /// 期望的下发指纹：`appliedToolSignature` 的**计算式**定义（不再是存储的影子副本）。
    ///
    /// 与 `storageToken` 刻意分开：令牌是对外持久化契约，指纹是「本条链路的期望状态」标记，
    /// 两者将来可能各自演化，不共用一份字面量。
    static func signature(of mode: CanvasInputMode) -> String {
        switch mode {
        case .navigation: return "navigation"
        case .ink(let tool): return "ink:\(tool.rawValue)"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    /// 切换到某个模式。
    ///
    /// 7 态互斥，因此「请求即结果」—— 这里没有隐藏的守卫（旧实现里「进套索先清工具、
    /// 选工具先退套索」的守卫已经由「模式不可同时成立」从类型上消除）。
    static func transition(from current: CanvasInputMode, to requested: CanvasInputMode) -> CanvasInputMode {
        _ = current
        return requested
    }

    /// 点击工具按钮（nil = 再点一次当前工具 → 回到导航态，这是现有 toggle 语义）。
    static func selecting(tool: CanvasTool?, from current: CanvasInputMode) -> CanvasInputMode {
        guard let tool else { return .navigation }
        let target: CanvasInputMode = (tool == .eraser) ? .eraser : .ink(tool)
        // 再点一次当前工具 → 取消，回到导航态（逐位等价旧 `next = (activeTool == tool) ? nil : tool`）。
        return target == current ? .navigation : target
    }

    /// 切换套索开关。
    static func togglingLasso(from current: CanvasInputMode) -> CanvasInputMode {
        current == .lasso ? .navigation : .lasso
    }

    /// 边缘双击快捷切换：在「上一次使用的画笔」与「当前模式」之间跳。
    ///
    /// 同时驱动两个记忆：`previousToolType`（上一个工具）与 `savedToolBeforeDesignated`
    /// （切到指定工具前被挤下去的那个工具）。这两条规则原本分散在 `handleEdgeDoubleTap`
    /// 的两个分支里、彼此不同，收进这一个纯决策函数后，「双击边缘会发生什么」变成可穷举的表。
    ///
    /// 返回的 `mode` 是**请求切换到的模式**；调用方仍要走 `switchTo(target:)`
    /// （保留「再点一次取消」的 toggle 语义），因此这里只做决策、不做落地。
    static func switching(from current: CanvasInputMode,
                          action: EdgeTapActionMode,
                          remembered: EdgeSwitchTargetTool,
                          designated: EdgeSwitchTargetTool,
                          savedBeforeDesignated: EdgeSwitchTargetTool)
        -> (mode: CanvasInputMode, remembered: EdgeSwitchTargetTool, savedBeforeDesignated: EdgeSwitchTargetTool) {
        let currentType = edgeTarget(of: current)
        switch action {
        case .switchToPrevious:
            let target = (remembered != currentType) ? remembered : (currentType == .eraser ? .pen : .eraser)
            return (mode: mode(of: target), remembered: currentType, savedBeforeDesignated: savedBeforeDesignated)
        case .switchToDesignated:
            if currentType != designated {
                return (mode: mode(of: designated), remembered: currentType, savedBeforeDesignated: currentType)
            }
            // 再次双击切回：优先回到「切到指定工具前的那个工具」，否则退回钢笔。
            let returnTool: EdgeSwitchTargetTool = (savedBeforeDesignated != designated) ? savedBeforeDesignated : .pen
            return (mode: mode(of: returnTool), remembered: currentType, savedBeforeDesignated: savedBeforeDesignated)
        }
    }

    /// 模式 ↔ 边缘切换目标类型（`.lasso` 与 `.eraser` 有各自的 case；导航态沿用旧的「按钢笔算」）。
    static func edgeTarget(of mode: CanvasInputMode) -> EdgeSwitchTargetTool {
        switch mode {
        case .lasso: return .lasso
        case .eraser: return .eraser
        case .navigation: return .pen
        case .ink(let tool): return EdgeSwitchTargetTool(rawValue: tool.rawValue) ?? .pen
        }
    }

    /// 边缘切换目标类型 → 模式。
    static func mode(of target: EdgeSwitchTargetTool) -> CanvasInputMode {
        switch target {
        case .lasso: return .lasso
        case .eraser: return .eraser
        case .pen, .monoline, .marker, .pencil:
            return .ink(CanvasTool(rawValue: target.rawValue) ?? .pen)
        }
    }
}
