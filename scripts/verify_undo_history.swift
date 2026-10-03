#!/usr/bin/env swift
//
//  verify_undo_history.swift
//  撤销 / 重做历史的**可执行不变量**门禁。
//
//  由来：用户报「被撤销的笔画在新笔画绘完时重新出现」。
//  先把 `CompositeCanvasContainerView` 的 history / redoStack / 选区状态机**照抄成模型**，
//  再穷举操作序列 —— 结论是：**这套栈在结构上不可能让被撤销的笔画自行回来**，
//  所以病灶在 PencilKit 那一侧的集成边界（它另有一条撤销登记，程序化换 drawing 不会清掉）。
//  这份门禁把上面这段推理固化下来，防三件事：
//
//   ① 现在的不变量（undo 必须丢弃浮动选区、快照自包含浮动笔迹、新编辑必须清空重做栈）
//      被后人改坏 —— 模型会当场枚举出反例；
//   ② 检查器本身退化成恒真 —— 用两个**故意破坏**的变体反证它抓得到；
//   ③ 生产代码退回「直接给画布赋值」而不清 PencilKit 的撤销登记 —— 源码钉会红。
//
//      swift scripts/verify_undo_history.swift --strict
//
import Foundation

// MARK: - 迷你断言

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

// MARK: - 状态机（生产代码的镜像）

enum Op: CaseIterable {
    /// `canvasViewDidBeginUsingTool` → 落笔成笔迹
    case beginAdd
    /// 落笔但**没有**经过 didBeginUsingTool（历史上真出过：isToolSessionActive 卡住 → 漏记历史）
    case addWithoutBegin
    case undo
    case redo
    /// 套索选中一笔（`select(strokeIndices:)`：从 drawing 里取出，放进浮动选区）
    case lasso
    /// 点空白取消选中（`commitSelection`）
    case deselect
    /// 进入变形/裁剪手势（`beginHandleGesture`：变换前先入栈）
    case transformBegin
    /// 删除选区（`deleteSelection`：先入栈再删除）
    case deleteSelection

    var label: String {
        switch self {
        case .beginAdd: return "draw"
        case .addWithoutBegin: return "draw*"
        case .undo: return "undo"
        case .redo: return "redo"
        case .lasso: return "lasso"
        case .deselect: return "deselect"
        case .transformBegin: return "transform"
        case .deleteSelection: return "delete"
        }
    }
}

/// 故意破坏的变体：用来证明检查器不是恒真。
enum Sabotage: CaseIterable {
    /// 生产语义（不破坏）
    case production
    /// `pushHistory()` 不清空重做栈 —— 新编辑之后还能重做回旧内容（经典「旧笔迹复活」）。
    case keepsRedoAfterNewEdit
    /// `commitSelection()` 不腾空浮动选区 —— 同一批笔迹被合并两次（重复的笔画）。
    case duplicatesFloatingStrokes

    var label: String {
        switch self {
        case .production: return "生产语义"
        case .keepsRedoAfterNewEdit: return "破坏：新编辑后仍可重做"
        case .duplicatesFloatingStrokes: return "破坏：浮动笔迹被合并两次"
        }
    }
}

struct CanvasModel {
    var drawing: [Int] = []
    var sel: [Int] = []
    var history: [[Int]] = []
    var redo: [[Int]] = []
    var nextID = 0
    var sabotage: Sabotage = .production
    /// 内容发生变化的次数。检查器靠它判断「重做是否仍然合法」——
    /// 必须由模型自己计数，而不能由检查器根据操作名推断：
    /// 空操作的 `deleteSelection`（没有选区）不该算一次变化，
    /// 而破坏变体里的变化又不一定伴随重做栈清空。
    var editCount = 0

    /// `snapshot()`：**快照自包含浮动笔迹**（撤销/重做不会丢内容）。
    func snapshot() -> [Int] { drawing + sel }

    /// `pushHistory()`：入栈 + 超限裁剪 + 让重做栈失效。
    mutating func pushHistory() {
        editCount += 1
        history.append(snapshot())
        if history.count > 30 { history.removeFirst() }
        invalidateRedo()
    }

    /// 内容一变就让重做栈失效（生产里是 `pushHistory` 与 `canvasViewDrawingDidChange` 两处）。
    mutating func invalidateRedo() {
        if sabotage != .keepsRedoAfterNewEdit { redo.removeAll() }
    }

    /// `commitSelection()`：浮动笔迹落回画布。
    mutating func commitSelection() {
        guard !sel.isEmpty else { return }
        drawing += sel
        if sabotage != .duplicatesFloatingStrokes { sel = [] }
    }

    /// `apply()`：装快照 + `discardSelection()`。
    mutating func apply(_ state: [Int]) {
        drawing = state
        sel = []
    }

    mutating func undoOp() {
        commitSelection()
        guard let previous = history.popLast() else { return }
        redo.append(snapshot())
        apply(previous)
    }

    mutating func redoOp() {
        commitSelection()
        guard let next = redo.popLast() else { return }
        history.append(snapshot())
        apply(next)
    }

    /// `canvasViewDidBeginUsingTool` 的前半段：有选区先把选区落回画布，再入栈。
    mutating func beginStroke() {
        if !sel.isEmpty { commitSelection() }
        pushHistory()
    }

    /// 落笔成笔迹 + `canvasViewDrawingDidChange` 里的重做栈失效。
    mutating func addStroke() {
        nextID += 1
        drawing.append(nextID)
        editCount += 1
        invalidateRedo()
    }

    /// `select(strokeIndices:)`：把选中笔画从画布取出、放入浮动选区。
    mutating func lasso() {
        commitSelection()
        guard let first = drawing.first else { return }
        sel = [first]
        drawing.removeFirst()
    }

    /// `beginHandleGesture`：变换前先入栈（此时可能有浮动选区 → 快照会合并它们）。
    mutating func transformBegin() { pushHistory() }

    /// `deleteSelection()`：先入栈再删除（没有选区时什么也不做）。
    mutating func deleteSelection() {
        guard !sel.isEmpty else { return }
        pushHistory()
        sel = []
    }

    var drawingHasDuplicate: Bool { Set(drawing).count != drawing.count }
}

/// 跑一段操作序列，返回发现的问题（nil = 干净）。
///
/// 两条不变量：
///  A. **被 undo 从画布里移除的笔画，不得在没有合法 redo 的情况下自己回到画布**（复活）；
///  B. **画布里不得出现同一笔画两次**（重复 = 视觉上的「复活」）。
///
/// 「合法 redo」的定义：自那次 undo 以来**内容没有被改过**（`editCount` 未变）。
/// 否则重做栈指向的就是另一条线的旧状态，搬回来就是复活。
func violation(_ ops: [Op], sabotage: Sabotage) -> String? {
    var model = CanvasModel()
    model.sabotage = sabotage
    var removedByUndo = Set<Int>()
    var redoIsValid = false
    var seenEdits = 0

    for op in ops {
        switch op {
        case .beginAdd:
            model.beginStroke()
            model.addStroke()
        case .addWithoutBegin:
            model.addStroke()
        case .undo:
            let before = Set(model.drawing)
            model.undoOp()
            removedByUndo = before.subtracting(model.drawing)
            redoIsValid = true
        case .redo:
            model.redoOp()
            if redoIsValid { removedByUndo.removeAll() }
        case .lasso:
            model.lasso()
        case .deselect:
            model.commitSelection()
        case .transformBegin:
            model.transformBegin()
        case .deleteSelection:
            model.deleteSelection()
        }

        // 内容一旦变化，重做就不再指向当前这条线。
        if model.editCount != seenEdits {
            seenEdits = model.editCount
            redoIsValid = false
        }

        if let resurrected = removedByUndo.sorted().first(where: { model.drawing.contains($0) }) {
            let cause = redoIsValid ? "被撤销后又自行回到画布" : "重做搬回了旧内容"
            return "笔画 \(resurrected) \(cause)（序列：\(ops.map(\.label).joined(separator: " → "))）"
        }
        if model.drawingHasDuplicate {
            return "画布出现重复笔画（序列：\(ops.map(\.label).joined(separator: " → "))）"
        }
    }
    return nil
}

/// 穷举长度 ≤ depth 的所有操作序列。
func enumerate(depth: Int, sabotage: Sabotage) -> (searched: Int, found: String?) {
    let ops = Op.allCases
    var searched = 0
    var found: String?

    func walk(_ prefix: [Op]) {
        if found != nil { return }
        if !prefix.isEmpty {
            searched += 1
            if let bad = violation(prefix, sabotage: sabotage) {
                found = bad
                return
            }
        }
        guard prefix.count < depth else { return }
        for op in ops { walk(prefix + [op]) }
    }
    walk([])
    return (searched, found)
}

// MARK: - ① 生产语义：必须找不到反例

// 深度 5（8 种操作 = 37448 条序列）在离线镜像里已跑通；
// 两种破坏各自在**长度 4** 就被抓到，所以这个深度足够暴露它们。
let searchDepth = 5
let groupOne = enumerate(depth: searchDepth, sabotage: .production)
check(groupOne.found == nil, "生产语义下不得存在复活/重复序列：\(groupOne.found ?? "")")
check(groupOne.searched > 30_000, "枚举规模必须足够大（实际 \(groupOne.searched) 条），否则等于没查")

// MARK: - ② 反证：被破坏的变体必须被抓到

for sabotage in [Sabotage.keepsRedoAfterNewEdit, .duplicatesFloatingStrokes] {
    let result = enumerate(depth: searchDepth, sabotage: sabotage)
    check(result.found != nil,
          "\(sabotage.label) 必须被检查器抓到（否则检查器恒真，形同虚设）")
}

// MARK: - ③ 源码钉：PencilKit 集成边界

let root = FileManager.default.currentDirectoryPath
func productionSource(_ relativePath: String) -> String? {
    try? String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(relativePath),
               encoding: .utf8)
}
func normalizeWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
}

func verifyProductionWiring() {
    guard let container = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") else {
        check(false, "读不到 SeeingCalendar/Canvas/CompositeCanvasContainerView.swift")
        return
    }
    let code = normalizeWhitespace(container)

    // drawing 的唯一写入漏斗：会话内单赋一次（1）+ 非会话的清空-装入（2）= 3 处。
    let assignments = code.components(separatedBy: "canvasView.drawing =").count - 1
    check(assignments == 3,
          "★ `canvasView.drawing =` 只应出现在 setDrawing 里（实际 \(assignments) 处）："
          + "任何旁路赋值都会绕过 PencilKit 撤销登记的清空，等于把病灶请回来")
    check(code.contains("canvasView.undoManager?.removeAllActions()"),
          "★ setDrawing 必须清掉 PencilKit 自己的撤销登记：两份历史并存时，我们追不上它那条链")
    check(code.contains("canvasView.drawing = PKDrawing()"),
          "★ setDrawing 必须先把画布清空一次：只赋一次值时，PencilKit 可能仍持有替换前的副本")
    check(code.contains("if isToolSessionActive {"),
          "有笔正按在画布上时必须只赋一次值 —— 绝不能把手里的那一笔置于清空状态")
    check(code.contains("private func apply(_ snapshot: CanvasSnapshot) { discardSelection()"),
          "★ apply() 必须丢弃浮动选区（模型已证明：选区残留是复活的通道之一）")

    // 快照自包含浮动笔迹 + 新编辑清空重做栈：这两条模型完全依赖。
    check(code.contains("if !selectedStrokes.isEmpty { drawing.strokes.append(contentsOf: selectedStrokes) }"),
          "★ snapshot() 必须合并浮动笔迹，否则撤销/重做会丢内容")
    check(code.contains("redoStack.removeAll()"),
          "★ pushHistory() 必须清空重做栈：否则「新编辑之后重做」会把旧内容搬回来")
    check(code.contains("func invalidateRedoStack()"),
          "★ 必须有「内容一变就让重做失效」的出口：重做栈只在最后一次操作是撤销时才有意义")
    check(code.contains("invalidateRedoStack() onContentChange?()"),
          "★ canvasViewDrawingDidChange 必须调 invalidateRedoStack()：内容变化不一定经过 pushHistory")

    guard let editor = productionSource("SeeingCalendar/Views/EditorModel.swift") else {
        check(false, "读不到 SeeingCalendar/Views/EditorModel.swift")
        return
    }
    let editorCode = normalizeWhitespace(editor)

    check(editorCode.contains("func undo() { canvasHost?.canvas.undo()"),
          "EditorModel.undo 必须仍然只调画布的 undo")
    check(editorCode.contains("func flushPendingSave()"),
          "撤销/重做必须立即落盘：2s 去抖期间退出，磁盘上留着的还是被撤销掉的内容")
    check(editorCode.components(separatedBy: "flushPendingSave()").count - 1 >= 3,
          "undo / redo / finishEditing 都应走 flushPendingSave()")
}

verifyProductionWiring()

// MARK: - 报告

let strict = CommandLine.arguments.contains("--strict")

print("")
if failures.isEmpty {
    print("PASS  撤销历史门禁（复活不可能 · 检查器有牙 · PencilKit 集成单一引擎）— \(checks) 项断言")
    print("      枚举 \(groupOne.searched) 条序列（长度 ≤ \(searchDepth)），两种破坏变体均被捕获")
} else {
    print("FAIL  撤销历史门禁 — \(failures.count)/\(checks) 项断言失败")
    for failure in failures { print("      • \(failure)") }
}

if strict, !failures.isEmpty { exit(1) }
exit(0)
