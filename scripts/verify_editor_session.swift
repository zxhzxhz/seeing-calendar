#!/usr/bin/env swift
//
//  verify_editor_session.swift
//  编辑器会话相位机门禁（CI 以 --strict 执行）
//
//  钉三类用户实测回来的隐式行为回退：
//
//  【换页后的重复写盘】旧实现把「当前页有未落盘的改动」隐式编码在 `saveTask != nil`
//     上，且 `save()` 自己不取消在途去抖任务。于是 `selectPage()` / `addPage()` /
//     `movePages()` 里先 `save()`、随后那个仍在计时的任务会在 2 秒后再写一遍
//     （写的是**新**的 currentPage）。本门禁从两个方向钉死它：
//     ① 相位 + 页身份的纯逻辑语义（`shouldCommit` / `reduce`，断言 1、2、3）；
//     ② 生产源码里 markDirty 的防抖任务体必须真的做页身份校验（断言 0，文本护栏）。
//
//  【`.saving` 期间的新改动被吞掉】相位机要求 `.saving` 期间收到 `.contentChanged`
//     必须落回 `.debouncing`（不变量 3）。本门禁用 (4 相位 × 4 事件) 穷举钉死它。
//
//  【二次编辑 6 个平行字段漂移】旧实现用 `editingItemID` / `editingItemPayload` /
//     `editingTextConfig` / `isEditingText` / `editingShapeConfig` / `isEditingShape`
//     手工镜像同一个 payload，回调里逐个赋值、`updateEditedItem` 里逐个清零，漏一个就漂移。
//     本门禁断言生产源码里只剩 `editSession` 一个真值 + 派生投影（断言 0 负向护栏），
//     并镜像验证「payload → 会话 → 全部投影」的派生一致性（断言 5）。
//
//  运行：swift scripts/verify_editor_session.swift [--strict]
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

/// 镜像 SeeingCalendar/Views/EditorSessionPolicy.swift 的 SavePhase。
enum Phase: Equatable {
    case clean
    case debouncing(pageUUID: UUID)
    case saving(pageUUID: UUID)

    var isDirty: Bool {
        if case .debouncing = self { return true }
        return false
    }

    var pendingPageUUID: UUID? {
        switch self {
        case .clean: return nil
        case .debouncing(let pageUUID), .saving(let pageUUID): return pageUUID
        }
    }
}

/// 镜像 SaveEvent。
enum Event: Equatable {
    case contentChanged(pageUUID: UUID)
    case debounceElapsed
    case flushRequested
    case saveCompleted
}

/// 镜像 SavePolicy。
enum Policy {
    static let debounce: Duration = .seconds(2)

    static func shouldCommit(phase: Phase, pageUUID: UUID) -> Bool {
        guard case .debouncing(let pending) = phase else { return false }
        return pending == pageUUID
    }

    static func reduce(_ phase: Phase, event: Event) -> Phase {
        switch event {
        case .contentChanged(let pageUUID):
            return .debouncing(pageUUID: pageUUID)

        case .debounceElapsed:
            if case .debouncing(let pageUUID) = phase {
                return .saving(pageUUID: pageUUID)
            }
            return phase

        case .flushRequested:
            if let pageUUID = phase.pendingPageUUID {
                return .saving(pageUUID: pageUUID)
            }
            return .clean

        case .saveCompleted:
            return .clean
        }
    }
}

/// 破坏变体：只看相位、完全忽略页身份 —— 这正是旧实现「不校验身份」的行为形状。
enum BrokenPolicy {
    static func shouldCommit(phase: Phase, pageUUID: UUID) -> Bool {
        if case .debouncing = phase { return true }
        return false
    }
}

// MARK: - 二次编辑会话的镜像

struct TextConfig: Equatable {
    var text: String
}

struct ShapeConfig: Equatable {
    var kind: String
}

/// 镜像 CanvasItemPayload 的判别子集。
enum Payload: Equatable {
    case text(TextConfig)
    case shape(ShapeConfig)
}

/// 镜像 CanvasEditSession。
enum EditSession: Equatable {
    case none
    case text(id: UUID, config: TextConfig)
    case shape(id: UUID, config: ShapeConfig)

    static func session(id: UUID, payload: Payload) -> EditSession {
        switch payload {
        case .text(let config): return .text(id: id, config: config)
        case .shape(let config): return .shape(id: id, config: config)
        }
    }

    var itemID: UUID? {
        switch self {
        case .none: return nil
        case .text(let id, _), .shape(let id, _): return id
        }
    }

    var payload: Payload? {
        switch self {
        case .none: return nil
        case .text(_, let config): return .text(config)
        case .shape(_, let config): return .shape(config)
        }
    }

    var isEditingText: Bool {
        if case .text = self { return true }
        return false
    }

    var isEditingShape: Bool {
        if case .shape = self { return true }
        return false
    }

    var textConfig: TextConfig? {
        if case .text(_, let config) = self { return config }
        return nil
    }

    var shapeConfig: ShapeConfig? {
        if case .shape(_, let config) = self { return config }
        return nil
    }
}

/// 镜像 EditorModel 里 `isEditingText` / `isEditingShape` 可写计算属性的 setter 语义：
/// **置 false 收敛到 `.none`；置 true 不改动**（真值来源是 payload，不是布尔镜像）。
func applyEditingTextSetter(_ value: Bool, to session: inout EditSession) {
    if !value { session = .none }
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 取出某个声明的主体（花括号配平）。找不到返回 nil。
func declarationBody(of declaration: String, in source: String) -> String? {
    guard let start = source.range(of: declaration),
          let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var index = open.lowerBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        else if character == "}" {
            depth -= 1
            if depth == 0 { return String(source[open.lowerBound...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

/// 子串出现次数（用于「某类型声明全文件只允许出现一次」这类负向护栏）。
func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}

let p1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let p2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

/// 4 相位（覆盖 clean / 两种脏子态 / 两个页身份）。
private let allPhases: [Phase] = [
    .clean,
    .debouncing(pageUUID: p1),
    .debouncing(pageUUID: p2),
    .saving(pageUUID: p1)
]

/// 4 事件。
private let allEvents: [Event] = [
    .contentChanged(pageUUID: p1),
    .debounceElapsed,
    .flushRequested,
    .saveCompleted
]

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    guard let policySource = productionSource("SeeingCalendar/Views/EditorSessionPolicy.swift") else {
        check(false, "读不到生产文件 EditorSessionPolicy.swift")
        return
    }
    guard let editorSource = productionSource("SeeingCalendar/Views/EditorModel.swift") else {
        check(false, "读不到生产文件 EditorModel.swift")
        return
    }

    // —— 相位机的形状 ——
    check(policySource.contains("enum SavePhase: Equatable, Sendable"),
          "SavePhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policySource.contains("case debouncing(pageUUID: UUID)"),
          "相位必须为「去抖中」携带页身份（否则换页竞态无法表达）")
    check(policySource.contains("case saving(pageUUID: UUID)"),
          "相位必须为「落盘中」携带页身份")
    check(policySource.contains("var isDirty: Bool {"),
          "「脏」必须是相位的派生投影，不得再有独立存储标志")
    check(policySource.contains("var pendingPageUUID: UUID? {"),
          "待落盘页身份必须是相位的派生投影")
    check(policySource.contains("case contentChanged(pageUUID: UUID)"),
          "contentChanged 必须携带页身份")
    check(policySource.contains("case debounceElapsed"), "必须保留 debounceElapsed 事件")
    check(policySource.contains("case flushRequested"), "必须保留 flushRequested 事件")
    check(policySource.contains("case saveCompleted"), "必须保留 saveCompleted 事件")
    check(policySource.contains("static let debounce: Duration = .seconds(2)"),
          "去抖窗口必须是具名常量（不许再在 markDirty 里写 .seconds(2) 字面量）")

    // —— 不变量 1：shouldCommit 的双重校验 ——
    check(policySource.contains("static func shouldCommit(phase: SavePhase, pageUUID: UUID) -> Bool"),
          "准入判定必须是独立可测的纯函数")
    check(policySource.contains("guard case .debouncing(let pending) = phase else { return false }"),
          "★ shouldCommit 必须校验相位（离开 .debouncing 即拒绝）")
    check(policySource.contains("return pending == pageUUID"),
          "★ shouldCommit 必须校验页身份（这是「防抖任务误写换页后的另一页」的直接修法）")
    check(policySource.contains("static func reduce(_ phase: SavePhase, event: SaveEvent) -> SavePhase"),
          "转移函数必须是单一 reduce 入口，可穷举 (相位 × 事件)")

    // —— 二次编辑会话的形状 ——
    check(policySource.contains("enum CanvasEditSession: Equatable"),
          "CanvasEditSession 必须是 Equatable 的纯值类型")
    check(policySource.contains("case text(id: UUID, config: TextItemConfig)"),
          "文本会话必须携带 id 与配置")
    check(policySource.contains("case shape(id: UUID, config: ShapeItemConfig)"),
          "形状会话必须携带 id 与配置")
    check(policySource.contains("static func session(id: UUID, payload: CanvasItemPayload) -> CanvasEditSession"),
          "必须有唯一构造入口（杜绝手工同步多个平行字段）")
    check(policySource.contains("var itemID: UUID? {"), "itemID 必须是派生投影")
    check(policySource.contains("var payload: CanvasItemPayload? {"), "payload 必须是派生投影")
    check(policySource.contains("var isEditingText: Bool {"), "isEditingText 必须是派生投影")
    check(policySource.contains("var isEditingShape: Bool {"), "isEditingShape 必须是派生投影")
    check(policySource.contains("var textConfig: TextItemConfig? {"), "textConfig 必须是派生投影")
    check(policySource.contains("var shapeConfig: ShapeItemConfig? {"), "shapeConfig 必须是派生投影")

    // —— EditorModel：M6 单一真值 ——
    check(editorSource.contains("@ObservationIgnored private(set) var savePhase: SavePhase = .clean"),
          "savePhase 必须是单一真值入口")
    check(editorSource.contains("savePhase = SavePolicy.reduce(savePhase, event: .contentChanged(pageUUID: page.uuid))"),
          "markDirty 必须经 reduce(.contentChanged) 显式驱动相位")
    check(editorSource.contains("guard SavePolicy.shouldCommit(phase: self.savePhase, pageUUID: pageUUID) else { return }"),
          "★ 防抖任务体必须做相位 + 页身份校验")
    check(editorSource.contains("func save() {"), "save() 的公开签名必须保留")
    check(editorSource.contains("savePhase = .saving(pageUUID: page.uuid)"),
          "save() 必须先进入 .saving（不变量 2：不允许把相位留在脏态）")
    check(editorSource.contains("private func saveNow() {"), "落盘逻辑必须下沉到 saveNow()")
    check(editorSource.contains("savePhase = SavePolicy.reduce(savePhase, event: .saveCompleted)"),
          "save() 完成必须经 reduce(.saveCompleted) 回到 .clean")
    check(editorSource.contains("savePhase = SavePolicy.reduce(savePhase, event: .flushRequested)"),
          "flushPendingSave 必须经 reduce(.flushRequested) 收编在途去抖")

    // —— EditorModel：M14 唯一真值 + 派生投影 ——
    check(editorSource.contains("var editSession: CanvasEditSession = .none"),
          "editSession 必须是二次编辑的单一真值入口")
    check(editorSource.contains("var editingItemID: UUID? { editSession.itemID }"),
          "editingItemID 必须降级为派生投影")
    check(editorSource.contains("var editingItemPayload: CanvasItemPayload? { editSession.payload }"),
          "editingItemPayload 必须降级为派生投影")
    check(editorSource.contains("var editingTextConfig: TextItemConfig? { editSession.textConfig }"),
          "editingTextConfig 必须降级为派生投影")
    check(editorSource.contains("var editingShapeConfig: ShapeItemConfig? { editSession.shapeConfig }"),
          "editingShapeConfig 必须降级为派生投影")
    check(editorSource.contains("self.editSession = CanvasEditSession.session(id: id, payload: payload)"),
          "onRequestItemEdit 回调必须只写 editSession")
    check(editorSource.contains("editSession = .none"),
          "updateEditedItem 必须只把 editSession 收敛为 .none")

    // —— 负向护栏：旧存储属性与「不校验身份」的防抖体不得回潮 ——
    //
    // 说明：`var editingTextConfig: TextItemConfig?` 这种字面量**不能**直接用作负向断言 ——
    // 派生投影 `var editingTextConfig: TextItemConfig? { editSession.textConfig }` 天然
    // 包含该子串。改为「该类型声明全文件只出现一次（即那个派生投影）」+ 严格无带初值的存储形。
    check(!editorSource.contains("var isEditingText: Bool = false"),
          "★ isEditingText 不得回退为存储属性（真值来源必须是 editSession）")
    check(!editorSource.contains("var isEditingShape: Bool = false"),
          "★ isEditingShape 不得回退为存储属性（真值来源必须是 editSession）")
    check(countOccurrences(of: "editingTextConfig: TextItemConfig?", in: editorSource) == 1,
          "★ editingTextConfig 只允许一个派生投影，不得再出现第二个（存储）声明")
    check(countOccurrences(of: "editingShapeConfig: ShapeItemConfig?", in: editorSource) == 1,
          "★ editingShapeConfig 只允许一个派生投影，不得再出现第二个（存储）声明")
    check(!editorSource.contains("var editingTextConfig: TextItemConfig? = nil"),
          "★ editingTextConfig 不得回潮为带初值的存储属性")
    check(!editorSource.contains("var editingShapeConfig: ShapeItemConfig? = nil"),
          "★ editingShapeConfig 不得回潮为带初值的存储属性")

    // —— 精确到函数体：防抖任务体里必须真的有过页身份校验 ——
    if let body = declarationBody(of: "func markDirty()", in: editorSource) {
        check(body.contains("SavePolicy.shouldCommit"),
              "★ markDirty 的防抖任务体必须做页身份校验（否则会误写换页后的另一页）")
        check(body.contains("SavePolicy.reduce(savePhase, event: .contentChanged(pageUUID: page.uuid))"),
              "markDirty 必须显式驱动相位转移")
    } else {
        check(false, "无法定位 markDirty() 的函数体 —— 签名改了吗？")
    }

    // —— 缩略图门禁钉住的形状：这几处不得被本轮改动破坏 ——
    if let body = declarationBody(of: "func flushPendingSave()", in: editorSource) {
        check(body.contains("saveTask?.cancel()"),
              "flushPendingSave 必须先撤掉在途去抖任务（缩略图门禁同款断言）")
        check(body.contains("save()"), "flushPendingSave 必须真的写盘")
    } else {
        check(false, "无法定位 flushPendingSave() 的函数体")
    }
    if let body = declarationBody(of: "func clearPage()", in: editorSource) {
        check(body.contains("ThumbnailStore.shared.forget(page.pageSlot"),
              "clearPage 必须仍当场乐观收图（不得被本轮改动碰掉）")
        check(body.contains("markDirty()"), "clearPage 必须仍走 markDirty 落盘")
    } else {
        check(false, "无法定位 clearPage() 的函数体")
    }
    if let body = declarationBody(of: "private func refreshThumbnails(for page: DrawingPage)", in: editorSource) {
        check(body.contains("regenerate(page.coverSlot"), "refreshThumbnails 必须仍重算封面槽位")
        check(body.contains("regenerate(page.pageSlot"), "refreshThumbnails 必须仍重算单页槽位")
        check(body.contains("day.coverPage?.uuid == page.uuid"),
              "封面判定必须仍问模型（day.coverPage）")
    } else {
        check(false, "无法定位 refreshThumbnails(for:) 的函数体")
    }
    check(editorSource.contains("func finishEditing()"),
          "finishEditing 必须仍然存在（缩略图门禁依赖它走 flushPendingSave）")
}

// MARK: - 断言 1：相位 × 事件的穷举不变量

func verifyExhaustiveInvariants() {
    for phase in allPhases {
        for event in allEvents {
            let next = Policy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"

            // 不变量 4：相位是 Equatable 的纯值 —— 转移结果必须能自反比较。
            checkEqual(next, next, "\(label) 相位必须可 Equatable 自反")

            // 相位形状的一致性：脏必带页身份；.clean 必不带页身份；
            // .saving 带页身份但不算脏（内容即将被写下，落盘期间的新改动会重新变脏）。
            if next.isDirty {
                check(next.pendingPageUUID != nil, "\(label) 脏相位必须携带页身份")
            }
            if case .clean = next {
                check(next.pendingPageUUID == nil, "\(label) .clean 不得携带页身份")
            }
            if case .saving = next {
                check(next.pendingPageUUID != nil, "\(label) .saving 必须携带页身份")
                check(!next.isDirty, "\(label) .saving 不算脏（落盘期间的新改动会重新变脏）")
            }

            switch event {
            case .contentChanged:
                // 不变量 3：任何相位下的 contentChanged 都必须落到 .debouncing(该页)。
                checkEqual(next, .debouncing(pageUUID: p1), "\(label) contentChanged 必须锚定到该页并变脏")
                if case .saving = phase {
                    check(next.isDirty, "★ \(label) .saving 期间的新改动必须落回脏态（不得被吞掉）")
                }

            case .debounceElapsed:
                if case .debouncing(let pending) = phase {
                    checkEqual(next, .saving(pageUUID: pending),
                               "\(label) 去抖到点必须推进为 .saving 且保持页身份")
                } else {
                    checkEqual(next, phase, "\(label) 非去抖态的去抖事件必须原样返回")
                }

            case .flushRequested:
                // 不变量 2：flushRequested 之后不得留脏。
                check(!next.isDirty, "★ \(label) flushRequested 之后不得仍为脏态")
                if let pending = phase.pendingPageUUID {
                    checkEqual(next, .saving(pageUUID: pending),
                               "\(label) flushRequested 必须把待落盘推进为 .saving 并保持页身份")
                } else {
                    checkEqual(next, .clean, "\(label) 干净态 flush 无事可做，应保持 .clean")
                }

            case .saveCompleted:
                checkEqual(next, .clean, "\(label) 落盘完成必须回到 .clean")
                check(!next.isDirty, "\(label) 落盘完成之后不得仍为脏态")
            }
        }
    }

    checkEqual(Policy.debounce, .seconds(2), "去抖窗口必须仍是 2 秒")
}

// MARK: - 断言 2：重放序列（换页竞态 / 三态流转）

func verifyReplaySequences() {
    // 三态流转：clean → debouncing → saving → clean
    var phase: Phase = .clean
    phase = Policy.reduce(phase, event: .contentChanged(pageUUID: p1))
    checkEqual(phase, .debouncing(pageUUID: p1), "内容变化应进入去抖态")
    phase = Policy.reduce(phase, event: .debounceElapsed)
    checkEqual(phase, .saving(pageUUID: p1), "去抖到点应进入落盘态")
    phase = Policy.reduce(phase, event: .saveCompleted)
    checkEqual(phase, .clean, "落盘完成应回到干净态")

    // 换页竞态：p1 去抖中又来 p2 改动 → 只允许落盘 p2。
    var race: Phase = .clean
    race = Policy.reduce(race, event: .contentChanged(pageUUID: p1))
    race = Policy.reduce(race, event: .contentChanged(pageUUID: p2))
    checkEqual(race.pendingPageUUID, p2, "★ 连续改动必须锚定到最新一页")
    check(!Policy.shouldCommit(phase: race, pageUUID: p1),
          "★ 旧页 p1 的去抖任务必须被拒绝（换页后不得误写）")
    race = Policy.reduce(race, event: .debounceElapsed)
    checkEqual(race, .saving(pageUUID: p2), "★ 去抖到点只允许落盘 p2")

    // `.saving` 期间的新改动必须回到脏态。
    var duringSave: Phase = .saving(pageUUID: p1)
    duringSave = Policy.reduce(duringSave, event: .contentChanged(pageUUID: p1))
    checkEqual(duringSave, .debouncing(pageUUID: p1), "★ .saving 期间的 contentChanged 必须落回 .debouncing")
    check(duringSave.isDirty, "★ 落盘期间的新改动必须让相位重新变脏")

    // selectPage 场景：先 save()（相位推进过），旧去抖任务到点必须被拒。
    var selectPageLike: Phase = .clean
    selectPageLike = Policy.reduce(selectPageLike, event: .contentChanged(pageUUID: p1))
    selectPageLike = Policy.reduce(selectPageLike, event: .flushRequested)   // save() 的相位起点
    selectPageLike = Policy.reduce(selectPageLike, event: .saveCompleted)    // save() 收尾
    checkEqual(selectPageLike, .clean, "selectPage 的 save() 应收敛到 .clean")
    check(!Policy.shouldCommit(phase: selectPageLike, pageUUID: p1),
          "★ 换页 save() 之后，2 秒到点的去抖任务必须被拒绝（消除重复写盘）")
}

// MARK: - 断言 3：shouldCommit 的双重校验（三种情形）

func verifyShouldCommit() {
    // 相位不匹配 —— 拒绝。
    checkEqual(Policy.shouldCommit(phase: .clean, pageUUID: p1), false,
               "干净相位必须拒绝落盘")
    checkEqual(Policy.shouldCommit(phase: .saving(pageUUID: p1), pageUUID: p1), false,
               "已落盘相位必须拒绝再次落盘")
    // 页身份不匹配 —— 拒绝。
    checkEqual(Policy.shouldCommit(phase: .debouncing(pageUUID: p1), pageUUID: p2), false,
               "★ 页身份不一致必须拒绝（否则会误写换页后的另一页）")
    // 两者都匹配 —— 放行。
    checkEqual(Policy.shouldCommit(phase: .debouncing(pageUUID: p1), pageUUID: p1), true,
               "相位与页身份都匹配时必须放行")
}

// MARK: - 断言 4：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    var divergent = false
    var goodRejects = false
    for phase in allPhases {
        for uuid in [p1, p2] {
            let good = Policy.shouldCommit(phase: phase, pageUUID: uuid)
            let bad = BrokenPolicy.shouldCommit(phase: phase, pageUUID: uuid)
            if good != bad { divergent = true }
            if !good { goodRejects = true }
        }
    }
    check(divergent, "★ 只看相位的破坏变体必须与正确实现分歧（检查器不得退化成恒真）")
    check(goodRejects, "★ 正确实现必须存在「拒绝落盘」的情形，否则准入判定退化成恒真")

    let good = Policy.shouldCommit(phase: .debouncing(pageUUID: p1), pageUUID: p2)
    let bad = BrokenPolicy.shouldCommit(phase: .debouncing(pageUUID: p1), pageUUID: p2)
    checkEqual(good, false, "正确实现必须拒绝换页后的写盘")
    checkEqual(bad, true, "破坏变体确实会误放行换页后的写盘 —— 反证有效")
    check(good != bad, "正反两实现必须在页身份不一致上分歧")
}

// MARK: - 断言 5：二次编辑会话的派生一致性

func verifyEditSessionDerivation() {
    let textConfig = TextConfig(text: "你好")
    let shapeConfig = ShapeConfig(kind: "roundedRect")

    // payload → 会话（唯一构造入口）
    let textSession = EditSession.session(id: p1, payload: .text(textConfig))
    checkEqual(textSession, .text(id: p1, config: textConfig), "文本 payload 必须构造出文本会话")
    let shapeSession = EditSession.session(id: p2, payload: .shape(shapeConfig))
    checkEqual(shapeSession, .shape(id: p2, config: shapeConfig), "形状 payload 必须构造出形状会话")

    // 文本会话的全部投影
    checkEqual(textSession.itemID, p1, "文本会话的 itemID 必须派生正确")
    checkEqual(textSession.payload, .text(textConfig), "文本会话的 payload 必须派生正确")
    check(textSession.isEditingText, "文本会话的 isEditingText 必须为真")
    check(!textSession.isEditingShape, "文本会话的 isEditingShape 必须为假")
    checkEqual(textSession.textConfig, textConfig, "文本会话的 textConfig 必须派生正确")
    checkEqual(textSession.shapeConfig, nil, "文本会话的 shapeConfig 必须为 nil")

    // 形状会话的全部投影
    checkEqual(shapeSession.itemID, p2, "形状会话的 itemID 必须派生正确")
    checkEqual(shapeSession.payload, .shape(shapeConfig), "形状会话的 payload 必须派生正确")
    check(shapeSession.isEditingShape, "形状会话的 isEditingShape 必须为真")
    check(!shapeSession.isEditingText, "形状会话的 isEditingText 必须为假")
    checkEqual(shapeSession.shapeConfig, shapeConfig, "形状会话的 shapeConfig 必须派生正确")
    checkEqual(shapeSession.textConfig, nil, "形状会话的 textConfig 必须为 nil")

    // .none 的全部投影
    let noneSession = EditSession.none
    checkEqual(noneSession.itemID, nil, ".none 的 itemID 必须为 nil")
    checkEqual(noneSession.payload, nil, ".none 的 payload 必须为 nil")
    check(!noneSession.isEditingText, ".none 的 isEditingText 必须为假")
    check(!noneSession.isEditingShape, ".none 的 isEditingShape 必须为假")
    checkEqual(noneSession.textConfig, nil, ".none 的 textConfig 必须为 nil")
    checkEqual(noneSession.shapeConfig, nil, ".none 的 shapeConfig 必须为 nil")

    // 可写计算属性的 setter 语义：置 false 收敛到 .none；置 true 不改动。
    var closing: EditSession = .text(id: p1, config: textConfig)
    applyEditingTextSetter(false, to: &closing)
    checkEqual(closing, .none, "★ isEditingText = false 必须收敛到 .none")

    var reopening: EditSession = .shape(id: p2, config: shapeConfig)
    applyEditingTextSetter(true, to: &reopening)
    checkEqual(reopening, .shape(id: p2, config: shapeConfig),
               "★ isEditingText = true 不得改动真值来源（真值在 payload，不在布尔镜像）")
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyReplaySequences()
verifyShouldCommit()
verifyBrokenVariantIsCaught()
verifyEditSessionDerivation()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 编辑器会话相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
