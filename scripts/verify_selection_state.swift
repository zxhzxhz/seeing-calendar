#!/usr/bin/env swift
//
//  verify_selection_state.swift
//  选区语义相位机 + 手势重入旗标门禁（CI 以 --strict 执行）
//
//  钉四类回退：
//
//  【M2 选区语义退化成三个写者的镜像】旧实现里「当前是哪种选区」由 5 个扁平字段涌现，
//     而 `selectionKind` 只是它们的**存储镜像**，却有**三个写者**：
//     `notifySelection()`（重推导后赋值）、`commitSelection(notify:false)`（直接写
//     `selectionKind = .none`）、`discardSelection()`（再写一遍）。三个写者各写各的，
//     就出现「镜像与原始事实不一致」的窗口。本门禁从两个方向钉死：
//     ① 纯推导函数的优先级（断言 2：cropping > compositeTransform > 单图 > none > composite，
//        逐位等价于旧 if-else 链）；
//     ② 生产源码里相位只允许有一个写者（断言 0 正向 + 断言 1 负向）。
//
//  【M11 手势重入旗标退化】旧实现里 4 台 FSM 混住在同一批裸 bool 字段里、各自没有类型：
//     `isProgrammatic` / `isToolSessionActive` / `isAdjustingSelection` / `isCapturingLasso`。
//     本门禁断言这些裸存储字段不再回潮，只留下有类型的相位与只读投影（断言 1）。
//
//  【两个已知陷阱】① `hitTest` 里查询 `UIEvent` 的全量触摸集合（初次落笔常常取不到该触摸）；
//     ② 对 `canvasView.drawing` 的**内容访问点回潮** —— 本门禁断言它恰好 3 处
//     （snapshot 读一份 + setDrawing 换 strokes + installDrawing 整份写），
//     且整份赋值恰好 1 处：多一处即意味着新的旁路在按旧版本对账，被撤销的笔画会复活。
//     断言 4 用计数护栏钉死两者。
//
//  【per-mode 手势暂存读错模式只给垃圾几何】断言 0 钉住 `SelectionGestureScratch` 的形状：
//     基准与手势种类绑定在同一个值里，取值前必须先匹配 case。
//
//  运行：swift scripts/verify_selection_state.swift [--strict]
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

// MARK: - 被测逻辑（生产代码的镜像，Linux 上无需 CoreGraphics）

enum MirrorPhase: Equatable {
    case none
    case image(id: UUID)
    case composite
    case compositeTransform
    case cropping(id: UUID)

    var shapeTag: Int {
        switch self {
        case .none: return 0
        case .composite: return 1
        case .image: return 2
        case .compositeTransform: return 3
        case .cropping: return 4
        }
    }
}

/// 生产 `SelectionStatePolicy.phase(...)` 的镜像。
func policyPhase(imageIDs: [UUID], strokeCount: Int,
                 isGroupTransforming: Bool, croppingID: UUID?) -> MirrorPhase {
    if let croppingID {
        return .cropping(id: croppingID)
    }
    if isGroupTransforming, !imageIDs.isEmpty || strokeCount > 0 {
        return .compositeTransform
    }
    if imageIDs.count == 1, strokeCount == 0 {
        return .image(id: imageIDs[0])
    }
    if imageIDs.isEmpty, strokeCount == 0 {
        return .none
    }
    return .composite
}

func policyEntersGroupTransform(strokeCount: Int) -> Bool { strokeCount > 0 }

func policyCanCrop(imageIDs: [UUID]) -> Bool { imageIDs.count == 1 }

/// 旧 `notifySelection()` 的 if-else 链**原样镜像** —— 用于逐位等价断言。
enum LegacyKind: Equatable {
    case none
    case composite
    case image(UUID)
    case compositeTransform
    case cropping(UUID)
}

func legacyKind(imageIDs: [UUID], strokeCount: Int,
                isGroupTransforming: Bool, croppingID: UUID?) -> LegacyKind {
    if let croppingID {
        return .cropping(croppingID)
    } else if isGroupTransforming, !imageIDs.isEmpty || strokeCount > 0 {
        return .compositeTransform
    } else if imageIDs.count == 1, strokeCount == 0 {
        return .image(imageIDs[0])
    } else if imageIDs.isEmpty, strokeCount == 0 {
        return .none
    } else {
        return .composite
    }
}

func asLegacy(_ phase: MirrorPhase) -> LegacyKind {
    switch phase {
    case .none: return .none
    case .composite: return .composite
    case .image(let id): return .image(id)
    case .compositeTransform: return .compositeTransform
    case .cropping(let id): return .cropping(id)
    }
}

/// 破坏变体：把裁剪的优先级降到**最低**（真实误改形状）。
func brokenPhaseCroppingLast(imageIDs: [UUID], strokeCount: Int,
                             isGroupTransforming: Bool, croppingID: UUID?) -> MirrorPhase {
    if isGroupTransforming, !imageIDs.isEmpty || strokeCount > 0 {
        return .compositeTransform
    }
    if imageIDs.count == 1, strokeCount == 0 {
        return .image(id: imageIDs[0])
    }
    if imageIDs.isEmpty, strokeCount == 0 {
        if let croppingID { return .cropping(id: croppingID) }   // ← 裁剪被压到最后
        return .none
    }
    return .composite
}

// MARK: 交互相位镜像

enum MirrorInteractionPhase: Equatable {
    case idle
    case toolSession
    case adjustingSelection

    var allowsOverlayRebuild: Bool {
        switch self {
        case .idle, .toolSession: return true
        case .adjustingSelection: return false
        }
    }

    var isAdjusting: Bool { self == .adjustingSelection }
}

enum MirrorInteractionEvent: Equatable {
    case toolSessionBegan
    case toolSessionEnded
    case selectionAdjustingBegan
    case selectionAdjustingEnded
}

func policyInteractionReduce(_ phase: MirrorInteractionPhase,
                             event: MirrorInteractionEvent) -> MirrorInteractionPhase {
    switch event {
    case .toolSessionBegan:
        return .toolSession
    case .toolSessionEnded:
        return phase == .toolSession ? .idle : phase
    case .selectionAdjustingBegan:
        return .adjustingSelection
    case .selectionAdjustingEnded:
        return phase == .adjustingSelection ? .idle : phase
    }
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

// MARK: - 断言 0：与生产源码同源（单行字面量护栏）

func verifySourceGuardrails() {
    // ---- 纯逻辑相位机文件 ----
    let policy = productionSource("SeeingCalendar/Canvas/SelectionStatePolicy.swift") ?? ""
    check(policy.contains("import Foundation"), "纯逻辑相位机必须只 import Foundation")
    check(!policy.contains("import UIKit"), "纯逻辑相位机不得 import UIKit")
    check(policy.contains("enum SelectionPhase: Equatable, Sendable"),
          "SelectionPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy.contains("case image(id: UUID)"), "SelectionPhase 必须保留 .image(id:)（带载荷）")
    check(policy.contains("case compositeTransform"), "SelectionPhase 必须保留 .compositeTransform")
    check(policy.contains("case cropping(id: UUID)"), "SelectionPhase 必须保留 .cropping(id:)（带载荷）")
    check(policy.contains("var shapeTag: Int {"), "SelectionPhase 必须暴露 shapeTag")
    check(policy.contains("static let noneShapeTag = 0"), "none 的 tag 必须仍是 0")
    check(policy.contains("static let compositeShapeTag = 1"), "composite 的 tag 必须仍是 1")
    check(policy.contains("static let imageShapeTag = 2"), "image 的 tag 必须仍是 2")
    check(policy.contains("static let compositeTransformShapeTag = 3"), "compositeTransform 的 tag 必须仍是 3")
    check(policy.contains("static let croppingShapeTag = 4"), "cropping 的 tag 必须仍是 4")

    check(policy.contains("enum SelectionStatePolicy"), "必须存在推导策略枚举")
    check(policy.contains("static func phase(imageIDs: [UUID], strokeCount: Int,"),
          "必须存在唯一的相位推导入口（像素级签名）")
    check(policy.contains("static func entersGroupTransform(strokeCount: Int) -> Bool"),
          "必须存在变形态准入的独立纯函数")
    check(policy.contains("static func canCrop(imageIDs: [UUID]) -> Bool"),
          "必须存在裁剪准入的独立纯函数")

    check(policy.contains("enum InteractionPhase: Equatable, Sendable"),
          "InteractionPhase 必须仍是 Equatable + Sendable")
    check(policy.contains("var allowsOverlayRebuild: Bool {"),
          "必须把「拖拽期间不重建手柄」固化成 allowsOverlayRebuild")
    check(policy.contains("enum InteractionEvent: Equatable, Sendable"),
          "InteractionEvent 必须仍是 Equatable + Sendable")
    check(policy.contains("case selectionAdjustingBegan"), "必须保留 selectionAdjustingBegan 事件")
    check(policy.contains("case selectionAdjustingEnded"), "必须保留 selectionAdjustingEnded 事件")
    check(policy.contains("enum InteractionPolicy"), "必须存在交互相位机")
    check(policy.contains("static func reduce(_ phase: InteractionPhase, event: InteractionEvent) -> InteractionPhase"),
          "必须存在交互相位的转移函数")
    check(policy.contains("return phase == .toolSession ? .idle : phase"),
          "toolSessionEnded 只允许收尾工具会话相，不得误清拖拽相")
    check(policy.contains("return phase == .adjustingSelection ? .idle : phase"),
          "selectionAdjustingEnded 只允许收尾拖拽相")

    check(policy.contains("enum SelectionGestureScratch: Equatable"),
          "手势暂存必须是一个带类型的枚举")
    check(policy.contains("case moveImage(base: CGAffineTransform)"), "必须保留 .moveImage 暂存")
    check(policy.contains("case crop(crop: CGRect, transform: CGAffineTransform, natural: CGSize)"),
          "必须保留 .crop 暂存（基准三件套绑在同一个 case）")
    check(policy.contains("case group(bounds: CGRect, transforms: [UUID: CGAffineTransform], accumulated: CGAffineTransform?)"),
          "必须保留 .group 暂存（bounds / transforms / accumulated 三件套）")

    check(policy.contains("enum LassoCapturePhase: Equatable, Sendable"),
          "套索捕获必须显式成相位")
    check(policy.contains("var isCapturing: Bool { self == .capturing }"),
          "isCapturing 投影必须严格等价于 .capturing")

    // ---- 容器视图（M2 + M11 的写入点 / 读点）----
    let container = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") ?? ""
    check(container.contains("private(set) var selectionPhase: SelectionPhase = .none"),
          "selectionPhase 必须是单一真值入口")
    check(container.contains("var selectionKind: CanvasSelectionKind {"),
          "selectionKind 必须降级为只读计算投影")
    check(container.contains("func notifySelection(broadcast: Bool = true)"),
          "notifySelection 必须显式区分「更新状态」与「对外广播」")
    check(container.contains("selectionPhase = SelectionStatePolicy.phase("),
          "相位必须由推导策略重建")
    check(container.contains("if broadcast { onSelectionChange?(selectionKind) }"),
          "broadcast 只允许控制对外回调")
    check(container.contains("private(set) var interactionPhase: InteractionPhase = .idle"),
          "interactionPhase 必须是单一真值入口")
    check(container.contains("func noteInteraction(_ event: InteractionEvent)"),
          "必须存在交互相位的唯一写入点（与 noteMenuActionSelected 同形）")
    check(container.contains("interactionPhase = InteractionPolicy.reduce(interactionPhase, event: event)"),
          "唯一写入点必须走 InteractionPolicy.reduce")
    check(container.contains("var isAdjustingSelection: Bool { interactionPhase.isAdjusting }"),
          "isAdjustingSelection 必须降级为只读投影")
    check(container.contains("private var isToolSessionActive: Bool { interactionPhase == .toolSession }"),
          "isToolSessionActive 必须降级为只读投影")
    check(container.contains("private var programmaticDepth = 0"),
          "程序化写入标志必须是嵌套深度计数器")
    check(container.contains("var gestureScratch: SelectionGestureScratch = .none"),
          "5 个扁平暂存字段必须收敛成一个带类型的值")
    check(container.contains("guard programmaticDepth == 0 else { return }"),
          "canvasViewDrawingDidChange 必须读深度计数，而非裸 bool")

    // ---- 选区扩展（commitSelection / discardSelection / refreshSelectionOverlay）----
    let selection = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift") ?? ""
    check(selection.contains("func commitSelection(notify: Bool = true)"),
          "commitSelection 签名必须保持（既有调用点零改动）")
    check(selection.contains("notifySelection(broadcast: notify)"),
          "commitSelection 必须把 notify 收窄为「是否对外广播」")
    check(selection.contains("notifySelection(broadcast: false)"),
          "discardSelection 必须复用同一推导入口（不再直写镜像）")
    check(selection.contains("if !interactionPhase.allowsOverlayRebuild {"),
          "refreshSelectionOverlay 必须读 allowsOverlayRebuild（#241 语义）")
    check(selection.contains("noteInteraction(.selectionAdjustingBegan)"),
          "拖拽开始必须改走交互相位事件（经单一写入点）")
    check(selection.contains("noteInteraction(.selectionAdjustingEnded)"),
          "拖拽结束必须改走交互相位事件（经单一写入点）")
    check(selection.contains("gestureScratch = .crop(crop: entity.cropRect,"),
          "裁剪手势必须把基准存进 .crop 暂存")
    check(selection.contains("gestureScratch = .moveImage(base: entity.worldTransform)"),
          "单图缩放手势必须把基准存进 .moveImage 暂存")
    check(selection.contains("gestureScratch = .group(bounds: selectionBounds(),"),
          "整体变换手势必须把基准存进 .group 暂存")
    check(selection.contains("private func groupBaseTransformsSnapshot() -> [UUID: CGAffineTransform]"),
          "基准采集必须收成一个具名函数")

    // ---- 渲染层（shapeTag 委派 + 套索相位）----
    let overlay = productionSource("SeeingCalendar/Canvas/SelectionOverlayView.swift") ?? ""
    check(overlay.contains("case .none: return SelectionPhase.noneShapeTag"),
          "Mode.shapeTag 必须委派给 SelectionPhase，不得再自持编号表")
    check(overlay.contains("case .cropping: return SelectionPhase.croppingShapeTag"),
          "Mode.shapeTag 必须委派给 SelectionPhase（cropping）")
    check(overlay.contains("private var lassoCapturePhase: LassoCapturePhase = .idle"),
          "套索捕获必须显式成相位（取代裸 bool）")
    check(overlay.contains("lassoCapturePhase = .capturing"), "进入套索必须置 .capturing")
    check(overlay.contains("lassoCapturePhase.isCapturing"), "套索读取必须走相位投影")
}

// MARK: - 断言 1：负向护栏（旧形状不得回潮）

func verifyNegativeGuardrails() {
    let container = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") ?? ""
    let selection = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainer+Selection.swift") ?? ""
    let overlay = productionSource("SeeingCalendar/Canvas/SelectionOverlayView.swift") ?? ""

    // 裸存储旗标一律不得回来。
    check(!container.contains("private var isProgrammatic = false"),
          "★ 不得回退为 `private var isProgrammatic = false` 存储旗标")
    check(!container.contains("var isAdjustingSelection = false"),
          "★ 不得回退为 `var isAdjustingSelection = false` 存储旗标")
    check(!container.contains("var isToolSessionActive = false"),
          "★ 不得回退为 `var isToolSessionActive = false` 存储旗标")
    check(!container.contains("var selectionKind: CanvasSelectionKind = .none"),
          "★ 不得回退为 `var selectionKind = .none` 存储镜像")
    check(!overlay.contains("private var isCapturingLasso"),
          "★ 不得回退为 `isCapturingLasso` 裸 bool")

    // 跨文件扩展不得直接写 private(set) 真值（否则 Xcode 编译不过）。
    check(!selection.contains("interactionPhase = "),
          "★ 跨文件扩展不得直接写 interactionPhase，只能走 noteInteraction")

    // 5 个扁平暂存字段不得回来。
    check(!container.contains("var gestureBaseTransform:"),
          "★ 不得回退为 gestureBaseTransform 扁平字段")
    check(!container.contains("var cropBase:"),
          "★ 不得回退为 cropBase 扁平字段")
    check(!container.contains("var groupBaseBounds:"),
          "★ 不得回退为 groupBaseBounds 扁平字段")
    check(!container.contains("var groupBaseTransforms:"),
          "★ 不得回退为 groupBaseTransforms 扁平字段")
    check(!container.contains("var groupAccumulatedDelta:"),
          "★ 不得回退为 groupAccumulatedDelta 扁平字段")

    // 精确到函数体：commitSelection / discardSelection 不得再直写镜像。
    if let body = declarationBody(of: "func commitSelection(notify: Bool = true)", in: selection) {
        check(!body.contains("selectionKind = "),
              "★ commitSelection 体内不得再直写 selectionKind（相位必须走唯一写者）")
        check(!body.contains("selectionOverlay.update(mode: .none)"),
              "★ commitSelection 体内不得再直写覆盖层形态（应走 notifySelection）")
        check(body.contains("notifySelection(broadcast: notify)"),
              "commitSelection 必须委派给 notifySelection(broadcast:)")
    } else {
        check(false, "无法定位 commitSelection 的函数体 —— 签名改了吗？")
    }

    if let body = declarationBody(of: "func discardSelection()", in: selection) {
        check(!body.contains("selectionKind = "),
              "★ discardSelection 体内不得再直写 selectionKind")
        check(!body.contains("selectionOverlay.update(mode: .none)"),
              "★ discardSelection 体内不得再直写覆盖层形态")
        check(body.contains("notifySelection(broadcast: false)"),
              "discardSelection 必须复用同一推导入口")
    } else {
        check(false, "无法定位 discardSelection 的函数体 —— 签名改了吗？")
    }
}

// MARK: - 断言 2：相位推导穷举 + 优先级逐位等价

private let idA = UUID()
private let idB = UUID()
private let idC = UUID()

private let imageIDSets: [[UUID]] = [[], [idA], [idA, idB]]
private let strokeCounts = [0, 1, 3]
private let transformFlags = [false, true]
private let croppingIDs: [UUID?] = [nil, idC]

func verifyPhaseExhaustive() {
    var combos = 0
    for ids in imageIDSets {
        for strokes in strokeCounts {
            for transforming in transformFlags {
                for cropping in croppingIDs {
                    combos += 1
                    let actual = policyPhase(imageIDs: ids, strokeCount: strokes,
                                             isGroupTransforming: transforming, croppingID: cropping)
                    let label = "ids=\(ids.count) strokes=\(strokes) transforming=\(transforming) cropping=\(cropping != nil)"

                    // ★ 与旧 notifySelection() 的 if-else 链逐位等价。
                    checkEqual(asLegacy(actual),
                               legacyKind(imageIDs: ids, strokeCount: strokes,
                                          isGroupTransforming: transforming, croppingID: cropping),
                               "\(label)：推导必须与旧 if-else 链逐位等价")

                    // 优先级：裁剪最高。
                    if let cropping {
                        checkEqual(actual, .cropping(id: cropping), "\(label)：裁剪优先级必须最高")
                    }

                    // 只有「无选区」才可能是 none；有对象存在时绝不落 none。
                    if ids.isEmpty, strokes == 0 {
                        if cropping == nil, !transforming {
                            checkEqual(actual, .none, "\(label)：空选区必须落 none")
                        }
                    } else if cropping == nil {
                        check(actual != .none, "\(label)：有对象存在时不得落 none")
                    }

                    // shapeTag 与 case 一一对应。
                    if case .none = actual { checkEqual(actual.shapeTag, 0, "\(label)：none tag") }
                    if case .image = actual { checkEqual(actual.shapeTag, 2, "\(label)：image tag") }
                    if case .composite = actual { checkEqual(actual.shapeTag, 1, "\(label)：composite tag") }
                    if case .compositeTransform = actual { checkEqual(actual.shapeTag, 3, "\(label)：transform tag") }
                    if case .cropping = actual { checkEqual(actual.shapeTag, 4, "\(label)：cropping tag") }
                }
            }
        }
    }
    check(combos == 36, "穷举组合数必须是 3×3×2×2 = 36（实际 \(combos)）")

    // 优先级逐条显式钉死。
    checkEqual(policyPhase(imageIDs: [idA, idB], strokeCount: 1, isGroupTransforming: true, croppingID: idC),
               .cropping(id: idC), "cropping 必须压过 compositeTransform")
    checkEqual(policyPhase(imageIDs: [idA], strokeCount: 2, isGroupTransforming: false, croppingID: idC),
               .cropping(id: idC), "cropping 必须压过 composite")
    checkEqual(policyPhase(imageIDs: [idA, idB], strokeCount: 0, isGroupTransforming: true, croppingID: nil),
               .compositeTransform, "compositeTransform 必须压过 composite")
    checkEqual(policyPhase(imageIDs: [idA], strokeCount: 1, isGroupTransforming: true, croppingID: nil),
               .compositeTransform, "单图 + 笔迹 + 变形态 → compositeTransform（不是 image）")
    checkEqual(policyPhase(imageIDs: [idA], strokeCount: 0, isGroupTransforming: false, croppingID: nil),
               .image(id: idA), "纯单图 → image")
    checkEqual(policyPhase(imageIDs: [idA, idB], strokeCount: 0, isGroupTransforming: false, croppingID: nil),
               .composite, "纯多图 → composite")
    checkEqual(policyPhase(imageIDs: [], strokeCount: 1, isGroupTransforming: false, croppingID: nil),
               .composite, "纯笔迹 → composite")
    checkEqual(policyPhase(imageIDs: [], strokeCount: 0, isGroupTransforming: false, croppingID: nil),
               .none, "空选区 → none")
    checkEqual(policyPhase(imageIDs: [], strokeCount: 0, isGroupTransforming: true, croppingID: nil),
               .none, "无对象时即使 isGroupTransforming 为真也必须落 none（旧链如此）")
}

// MARK: - 断言 3：准入真值表 + 交互相位穷举

func verifyAdmissionAndInteraction() {
    // entersGroupTransform 真值表（#242：含笔迹即默认进入变形态）。
    check(!policyEntersGroupTransform(strokeCount: 0), "无笔迹不得进入变形态")
    check(policyEntersGroupTransform(strokeCount: 1), "含 1 条笔迹即进入变形态")
    check(policyEntersGroupTransform(strokeCount: 5), "含多条笔迹即进入变形态")
    for count in 1...5 {
        check(policyEntersGroupTransform(strokeCount: count), "含 \(count) 条笔迹必须进入变形态")
    }

    // canCrop 真值表：裁剪只对单张贴图成立。
    check(!policyCanCrop(imageIDs: []), "空选区不可裁剪")
    check(policyCanCrop(imageIDs: [idA]), "单张贴图可裁剪")
    check(!policyCanCrop(imageIDs: [idA, idB]), "多张贴图不可裁剪")

    // 交互相位穷举（3 × 4 = 12 组合）。
    let phases: [MirrorInteractionPhase] = [.idle, .toolSession, .adjustingSelection]
    let events: [MirrorInteractionEvent] = [
        .toolSessionBegan, .toolSessionEnded, .selectionAdjustingBegan, .selectionAdjustingEnded
    ]
    for phase in phases {
        for event in events {
            let next = policyInteractionReduce(phase, event: event)
            let label = "\(phase) × \(event)"

            if case .toolSessionBegan = event {
                checkEqual(next, .toolSession, "\(label)：落笔必须进入工具会话相")
            }
            if case .selectionAdjustingBegan = event {
                checkEqual(next, .adjustingSelection, "\(label)：拖拽必须进入拖拽相")
            }
            if case .toolSessionEnded = event {
                checkEqual(next, phase == .toolSession ? .idle : phase,
                           "\(label)：只收尾工具会话相，不得误清其它相")
                if phase != .toolSession {
                    checkEqual(next, phase, "\(label)：非工具会话相时 ended 必须原样返回")
                }
            }
            if case .selectionAdjustingEnded = event {
                checkEqual(next, phase == .adjustingSelection ? .idle : phase,
                           "\(label)：只收尾拖拽相，不得误清其它相")
                if phase != .adjustingSelection {
                    checkEqual(next, phase, "\(label)：非拖拽相时 ended 必须原样返回")
                }
            }

            // ★ #241：只有拖拽相禁止重建覆盖层。
            checkEqual(next.allowsOverlayRebuild, next != .adjustingSelection,
                       "\(label)：allowsOverlayRebuild 必须恰好等价于「非拖拽相」")
            checkEqual(next.isAdjusting, next == .adjustingSelection,
                       "\(label)：isAdjusting 必须恰好等价于拖拽相")
        }
    }

    // 结论性纪律：拖拽中收到工具会话结束，绝不能被踢出保护区。
    checkEqual(policyInteractionReduce(.adjustingSelection, event: .toolSessionEnded),
               .adjustingSelection, "★ 拖拽中收到 toolSessionEnded 必须原样返回（否则违反 #241）")
    check(!policyInteractionReduce(.adjustingSelection, event: .toolSessionEnded).allowsOverlayRebuild,
          "★ 拖拽相在任何事件后都不许放开覆盖层重建")
    checkEqual(policyInteractionReduce(.idle, event: .selectionAdjustingEnded), .idle,
               "idle 收到 selectionAdjustingEnded 必须原样返回")
}

// MARK: - 断言 4：两个已知陷阱护栏

func verifyKnownTraps() {
    let container = productionSource("SeeingCalendar/Canvas/CompositeCanvasContainerView.swift") ?? ""
    let overlay = productionSource("SeeingCalendar/Canvas/SelectionOverlayView.swift") ?? ""

    // 陷阱①：hitTest 里查询 UIEvent 的全量触摸集合。
    let containerAll = container.components(separatedBy: "allTouches").count - 1
    let overlayAll = overlay.components(separatedBy: "allTouches").count - 1
    checkEqual(containerAll, 0, "★ CompositeCanvasContainerView 不得出现 allTouches")
    checkEqual(overlayAll, 0, "★ SelectionOverlayView 不得出现 allTouches")

    // 陷阱②：drawing 的整份赋值必须唯一（换页），页内写入必须只换 strokes。
    // ★ 与既有 verify_undo_history 的判据一致（整份 1 处 / strokes 1 处）：
    //   整份赋值回潮 ＝ 按下旧版本对账 ⇒ 被撤销的笔画复活。
    let wholeAssignments = container.components(separatedBy: "canvasView.drawing =").count - 1
    let strokeAssignments = container.components(separatedBy: "canvasView.drawing.strokes =").count - 1
    checkEqual(wholeAssignments, 1, "★ 整份赋值只允许 1 处（换页），实际 \(wholeAssignments) 处")
    checkEqual(strokeAssignments, 1, "★ 页内写入必须只换 strokes，实际 \(strokeAssignments) 处")
    checkEqual(wholeAssignments + strokeAssignments, 2,
               "★ 对 canvasView.drawing 的写入漏斗必须恰好 2 处（setDrawing + installDrawing）")

    // canvasView.drawing 的**内容访问点**必须是 3 处：
    //   snapshot() 读一份、setDrawing 换 strokes、installDrawing 整份写。
    //   「canvasView.drawingPolicy」是绘制策略、不是内容访问，故排除。
    //   多于 3 处即意味着有新的旁路在碰 drawing —— 那是 CRDT 对账回潮的前兆。
    let drawingReferences = container.components(separatedBy: "canvasView.drawing").count - 1
    let policyReferences = container.components(separatedBy: "canvasView.drawingPolicy").count - 1
    checkEqual(drawingReferences - policyReferences, 3,
               "★ canvasView.drawing 的内容访问点必须恰好 3 处（读 1 + 写 2），实际 \(drawingReferences - policyReferences) 处")
    check(container.contains("func setDrawing(_ drawing: PKDrawing)"),
          "页内写入漏斗 setDrawing 必须仍在")
    check(container.contains("func installDrawing(_ drawing: PKDrawing)"),
          "换页写入漏斗 installDrawing 必须仍在")
}

// MARK: - 断言 5：反证 —— 破坏变体必须被抓到

func verifyBrokenVariantsAreCaught() {
    // ① 裁剪优先级被降到最低。
    var divergence = 0
    for ids in imageIDSets {
        for strokes in strokeCounts {
            for transforming in transformFlags {
                for cropping in croppingIDs {
                    let good = policyPhase(imageIDs: ids, strokeCount: strokes,
                                           isGroupTransforming: transforming, croppingID: cropping)
                    let bad = brokenPhaseCroppingLast(imageIDs: ids, strokeCount: strokes,
                                                      isGroupTransforming: transforming, croppingID: cropping)
                    if good != bad { divergence += 1 }
                }
            }
        }
    }
    check(divergence > 0, "★「裁剪优先级降到最低」的破坏变体必须与正确实现分歧（检查器不得退化）")

    let goodCrop = policyPhase(imageIDs: [idA], strokeCount: 0, isGroupTransforming: false, croppingID: idC)
    let badCrop = brokenPhaseCroppingLast(imageIDs: [idA], strokeCount: 0, isGroupTransforming: false, croppingID: idC)
    checkEqual(goodCrop, .cropping(id: idC), "正确实现：单图裁剪态必须落 cropping")
    checkEqual(badCrop, .image(id: idA), "破坏变体：裁剪被压到最后，误落 image")
    check(goodCrop != badCrop, "★ 正反两实现必须在裁剪优先级上分歧")

    // ② 变形态准入恒为 false（真实误改：忘记「含笔迹即进变形态」）。
    let goodEnters = policyEntersGroupTransform(strokeCount: 2)
    let badEnters = false
    check(goodEnters, "正确实现：含笔迹必须进变形态")
    check(!badEnters, "破坏变体：恒不进变形态")
    check(goodEnters != badEnters, "★「恒不进变形态」的破坏变体必须在含笔迹时分歧")

    // ③ 拖拽结束误清工具会话相（把两个 ended 混为一谈）。
    let goodEnded = policyInteractionReduce(.toolSession, event: .selectionAdjustingEnded)
    let badEnded = MirrorInteractionPhase.idle   // 误把任何 ended 都当总复位
    checkEqual(goodEnded, .toolSession, "正确实现：拖拽结束不得碰工具会话相")
    check(goodEnded != badEnded, "★「ended 即总复位」的破坏变体必须分歧")

    // 门禁不得退化成恒真。
    check(checks > 60, "断言数量必须足够大（实际 \(checks) 条），否则等于没查")
}

// MARK: - 运行

verifySourceGuardrails()
verifyNegativeGuardrails()
verifyPhaseExhaustive()
verifyAdmissionAndInteraction()
verifyKnownTraps()
verifyBrokenVariantsAreCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 选区相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
