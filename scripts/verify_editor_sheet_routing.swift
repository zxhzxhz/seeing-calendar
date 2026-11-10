#!/usr/bin/env swift
//
//  verify_editor_sheet_routing.swift
//  编辑器模态路由门禁（CI 以 --strict 执行）
//
//  钉三类用户实测报回来的回退：
//
//  【「点了没反应」的静默丢模态】旧实现用 13 个平行 `@State` 布尔表达「哪个模态在屏」，
//     它们可以任意同真。SwiftUI 对「多个 sheet 同真」的行为是把其中一个**静默丢弃** ——
//     用户看到的就是「点了没反应」。本门禁从两个方向钉死它：
//     ① 路由互斥机的纯逻辑语义：`accepts` 的 (12 × 12) 穷举真值表 —— 同路由幂等接受、
//        异路由一律拒绝、关闭请求恒接受、无模态时任意请求接受；
//     ② 生产源码不得再出现任何旧布尔名（断言 0 的 13 名字负向护栏）。
//
//  【「编辑文本」「编辑形状」各自开门】旧实现两个 sheet 由 model 的两个布尔分别驱动，
//     可以同屏。本门禁断言二者经 `derivedRoute` 归一到同一条路由，两者皆真有确定的
//     tie-break（文本优先），并断言关闭二次编辑路由必须回写 model（`requiresModelCleanup`）。
//
//  【Identifiable 路由 id 重复】`EditorSheetRoute` 是 `.sheet(item:)` 的身份来源，
//     两个 case 共用 id 会让 SwiftUI 把不同的 sheet 认成同一个。本门禁断言 11 个
//     case 的 id 去重后仍是 11 —— 这是 Identifiable 路由最易退化的一项。
//
//  运行：swift scripts/verify_editor_sheet_routing.swift [--strict]
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

/// 镜像 SeeingCalendar/Views/EditorSheetRouting.swift 的 EditorSheetRoute。
enum SheetRoute: Equatable, Identifiable {
    case camera
    case fileImporter
    case pageManager
    case weather
    case addText
    case addSticker
    case addSignature
    case addShape
    case edgeDoubleTapSettings
    case editText
    case editShape

    var id: String {
        switch self {
        case .camera: return "camera"
        case .fileImporter: return "fileImporter"
        case .pageManager: return "pageManager"
        case .weather: return "weather"
        case .addText: return "addText"
        case .addSticker: return "addSticker"
        case .addSignature: return "addSignature"
        case .addShape: return "addShape"
        case .edgeDoubleTapSettings: return "edgeDoubleTapSettings"
        case .editText: return "editText"
        case .editShape: return "editShape"
        }
    }

    var isDerivedFromModel: Bool {
        switch self {
        case .editText, .editShape: return true
        case .camera, .fileImporter, .pageManager, .weather, .addText,
             .addSticker, .addSignature, .addShape, .edgeDoubleTapSettings:
            return false
        }
    }
}

/// 镜像 EditorDialogRoute。
enum DialogRoute: Equatable, Identifiable {
    case clearPageConfirm
    case deletePageConfirm

    var id: String {
        switch self {
        case .clearPageConfirm: return "clearPageConfirm"
        case .deletePageConfirm: return "deletePageConfirm"
        }
    }
}

/// 镜像 PhotoPickerRoute。
enum PhotoRoute: Equatable {
    case none
    case importNew
    case replaceExisting

    var isPresented: Bool {
        switch self {
        case .none: return false
        case .importNew, .replaceExisting: return true
        }
    }
}

/// 镜像 ColorPickerRoute。
enum ColorRoute: Equatable {
    case hidden
    case presented

    mutating func toggle() {
        self = (self == .presented) ? .hidden : .presented
    }
}

/// 镜像 EditorSheetRoutingPolicy。
enum Policy {
    static func accepts(current: SheetRoute?, requested: SheetRoute?) -> Bool {
        guard let requested = requested else { return true }
        guard let current = current else { return true }
        return current == requested
    }

    static func derivedRoute(isEditingText: Bool, isEditingShape: Bool) -> SheetRoute? {
        if isEditingText { return .editText }
        if isEditingShape { return .editShape }
        return nil
    }

    static func requiresModelCleanup(_ route: SheetRoute) -> Bool {
        switch route {
        case .editText, .editShape: return true
        case .camera, .fileImporter, .pageManager, .weather, .addText,
             .addSticker, .addSignature, .addShape, .edgeDoubleTapSettings:
            return false
        }
    }
}

/// 破坏变体：恒接受 —— 旧实现「13 个布尔各自独立、谁都能开」的行为形状。
enum BrokenRoutingPolicy {
    static func accepts(current: SheetRoute?, requested: SheetRoute?) -> Bool {
        true
    }
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 11 个路由 case 的全集。
private let allRoutes: [SheetRoute] = [
    .camera, .fileImporter, .pageManager, .weather, .addText,
    .addSticker, .addSignature, .addShape, .edgeDoubleTapSettings,
    .editText, .editShape
]

/// 穷举取值：11 个路由 + nil（关闭请求）。
private let routeChoices: [SheetRoute?] = [nil] + allRoutes.map { Optional($0) }

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    guard let routingSource = productionSource("SeeingCalendar/Views/EditorSheetRouting.swift") else {
        check(false, "读不到生产文件 EditorSheetRouting.swift")
        return
    }
    guard let editorSource = productionSource("SeeingCalendar/Views/DayEditorView.swift") else {
        check(false, "读不到生产文件 DayEditorView.swift")
        return
    }

    // —— 路由枚举的形状 ——
    check(routingSource.contains("enum EditorSheetRoute: Equatable, Identifiable"),
          "EditorSheetRoute 必须仍是 Equatable + Identifiable 的纯值类型")
    check(routingSource.contains("case camera"), "必须保留 .camera")
    check(routingSource.contains("case fileImporter"), "必须保留 .fileImporter")
    check(routingSource.contains("case pageManager"), "必须保留 .pageManager")
    check(routingSource.contains("case weather"), "必须保留 .weather")
    check(routingSource.contains("case addText"), "必须保留 .addText")
    check(routingSource.contains("case addSticker"), "必须保留 .addSticker")
    check(routingSource.contains("case addSignature"), "必须保留 .addSignature")
    check(routingSource.contains("case addShape"), "必须保留 .addShape")
    check(routingSource.contains("case edgeDoubleTapSettings"), "必须保留 .edgeDoubleTapSettings")
    check(routingSource.contains("case editText"), "必须保留 .editText")
    check(routingSource.contains("case editShape"), "必须保留 .editShape")
    check(routingSource.contains("var id: String {"), "id 必须是稳定字符串 id（Identifiable）")
    check(routingSource.contains("var isDerivedFromModel: Bool {"),
          "必须能判定路由是否由 EditorModel 派生")

    // —— 其余三个路由枚举 ——
    check(routingSource.contains("enum EditorDialogRoute: Equatable, Identifiable"),
          "确认框必须独立成路由枚举")
    check(routingSource.contains("case clearPageConfirm"), "必须保留 clearPageConfirm")
    check(routingSource.contains("case deletePageConfirm"), "必须保留 deletePageConfirm")
    check(routingSource.contains("enum PhotoPickerRoute: Equatable"),
          "相册选择必须收敛为单一枚举（消除交叉条件）")
    check(routingSource.contains("case importNew"), "必须保留 importNew（新建导入）")
    check(routingSource.contains("case replaceExisting"), "必须保留 replaceExisting（原地替换）")
    check(routingSource.contains("var isPresented: Bool {"), "isPresented 必须是路由的派生投影")
    check(routingSource.contains("enum ColorPickerRoute: Equatable"),
          "调色盘必须独立成 toggle 枚举")
    check(routingSource.contains("case hidden"), "必须保留 hidden")
    check(routingSource.contains("case presented"), "必须保留 presented")
    check(routingSource.contains("mutating func toggle() {"), "调色盘必须提供 toggle 语义")

    // —— 互斥机的形状与不变量 ——
    check(routingSource.contains("enum EditorSheetRoutingPolicy {"),
          "模态互斥机必须独立成策略类型")
    check(routingSource.contains("static func accepts(current: EditorSheetRoute?, requested: EditorSheetRoute?) -> Bool"),
          "accepts 必须是独立可测的纯函数")
    check(routingSource.contains("return current == requested"),
          "★ accepts 的准入判据必须是「同路由相等」——这是「至多一屏」的类型化表达")
    check(routingSource.contains("static func derivedRoute(isEditingText: Bool, isEditingShape: Bool) -> EditorSheetRoute?"),
          "derivedRoute 必须是独立可测的纯函数")
    check(routingSource.contains("if isEditingText { return .editText }"),
          "★ derivedRoute 必须文本优先（两会话同真的确定 tie-break）")
    check(routingSource.contains("if isEditingShape { return .editShape }"),
          "derivedRoute 必须能给出形状路由")
    check(routingSource.contains("static func requiresModelCleanup(_ route: EditorSheetRoute) -> Bool"),
          "requiresModelCleanup 必须是独立可测的纯函数")
    check(routingSource.contains("case .editText, .editShape: return true"),
          "★ 只有二次编辑路由需要回写 model（其余为假）")

    // —— 负向护栏：13 个旧布尔名一个都不许再出现（var 声明形 / $绑定形）——
    let legacyBoolNames = [
        "isCameraPresented", "isFileImporterPresented", "isClearConfirmPresented",
        "isDeletePageConfirmPresented", "isColorPickerPresented", "isPageManagerPresented",
        "isWeatherSheetPresented", "isAddTextPresented", "isAddStickerPresented",
        "isAddSignaturePresented", "isAddShapePresented", "isEdgeDoubleTapSettingsPresented",
        "isPhotoPickerRequested"
    ]
    checkEqual(legacyBoolNames.count, 13, "旧布尔名清单必须覆盖 13 项")
    for name in legacyBoolNames {
        check(editorSource.contains("var " + name) != true,
              "★ 旧布尔 \(name) 不得再以 var 存储形式出现")
        check(editorSource.contains("$" + name) != true,
              "★ 旧布尔 \(name) 不得再以 $绑定 形式出现")
    }

    // —— 正向护栏：四个路由存储声明必须存在 ——
    check(editorSource.contains("@State private var sheetRoute: EditorSheetRoute?"),
          "sheetRoute 必须是模态路由的单一存储")
    check(editorSource.contains("@State private var dialogRoute: EditorDialogRoute?"),
          "dialogRoute 必须是确认框路由的单一存储")
    check(editorSource.contains("@State private var photoRoute: PhotoPickerRoute = .none"),
          "photoRoute 必须是相册选择路由的单一存储")
    check(editorSource.contains("@State private var colorRoute: ColorPickerRoute = .hidden"),
          "colorRoute 必须是调色盘路由的单一存储")

    // —— 正向护栏：呈现路径必须经路由 ——
    check(editorSource.contains(".sheet(item: sheetPresentationBinding(model: model))"),
          "sheet 必须收敛为单一 .sheet(item:)，否则互斥性无从落地")
    check(editorSource.contains("EditorSheetRoutingPolicy.derivedRoute("),
          "视图必须经 derivedRoute 读取 model 派生的二次编辑路由")
    check(editorSource.contains("EditorSheetRoutingPolicy.accepts("),
          "视图必须经 accepts 做模态准入判定")
    check(editorSource.contains("EditorSheetRoutingPolicy.requiresModelCleanup("),
          "关闭二次编辑路由必须经 requiresModelCleanup 判定是否回写 model")
    check(editorSource.contains("case .editText:"), "switch 必须处理 editText 分支")
    check(editorSource.contains("case .editShape:"), "switch 必须处理 editShape 分支")
}

// MARK: - 断言 1：accepts 的 (12 × 12) 穷举真值表

func verifyAcceptsExhaustive() {
    for current in routeChoices {
        for requested in routeChoices {
            let accepted = Policy.accepts(current: current, requested: requested)
            let label = "accepts(current: \(String(describing: current)), requested: \(String(describing: requested)))"
            if requested == nil {
                check(accepted, "\(label)：关闭请求任意时刻都必须接受")
            } else if current == nil {
                check(accepted, "\(label)：没有模态在屏时任意请求都必须接受")
            } else if current == requested {
                check(accepted, "\(label)：同路由重复请求必须幂等接受")
            } else {
                check(!accepted, "\(label)：★ 异路由必须拒绝（至多一个模态在屏）")
            }
        }
    }

    // 四个边界显式化。
    check(Policy.accepts(current: nil, requested: nil), "无模态时的关闭请求必须接受")
    check(Policy.accepts(current: .camera, requested: nil), "关闭请求必须接受")
    check(Policy.accepts(current: nil, requested: .weather), "无模态时任意打开请求必须接受")
    check(Policy.accepts(current: .weather, requested: .weather), "同路由重复请求必须幂等接受")
    check(!Policy.accepts(current: .camera, requested: .weather), "异路由必须拒绝")
}

// MARK: - 断言 2：derivedRoute 的四种真值组合

func verifyDerivedRoute() {
    checkEqual(Policy.derivedRoute(isEditingText: true, isEditingShape: true), .editText,
               "★ 两者皆真必须文本优先（确定的 tie-break，不再靠 SwiftUI 的未定义行为）")
    checkEqual(Policy.derivedRoute(isEditingText: true, isEditingShape: false), .editText,
               "仅文本会话必须路由到 .editText")
    checkEqual(Policy.derivedRoute(isEditingText: false, isEditingShape: true), .editShape,
               "仅形状会话必须路由到 .editShape")
    checkEqual(Policy.derivedRoute(isEditingText: false, isEditingShape: false), nil,
               "两者皆假必须无模态")
    check(Policy.derivedRoute(isEditingText: true, isEditingShape: true) != .editShape,
          "★ 文本优先时不得同时给出形状路由 —— 两个二次编辑模态不可能同屏")
}

// MARK: - 断言 3：requiresModelCleanup 的全 case 真值表

func verifyRequiresModelCleanup() {
    for route in allRoutes {
        let expected = (route == .editText || route == .editShape)
        checkEqual(Policy.requiresModelCleanup(route), expected,
                   "\(route) 的 model 清理判定必须恰好与其派生性一致")
    }
    checkEqual(Policy.requiresModelCleanup(.editText), true, "editText 关闭必须回写 model")
    checkEqual(Policy.requiresModelCleanup(.editShape), true, "editShape 关闭必须回写 model")
    checkEqual(Policy.requiresModelCleanup(.pageManager), false, "pageManager 关闭不得碰 model")
    checkEqual(Policy.requiresModelCleanup(.camera), false, "camera 关闭不得碰 model")
    checkEqual(Policy.requiresModelCleanup(.fileImporter), false, "fileImporter 关闭不得碰 model")
    checkEqual(Policy.requiresModelCleanup(.edgeDoubleTapSettings), false,
               "edgeDoubleTapSettings 关闭不得碰 model")
}

// MARK: - 断言 4：路由 id 唯一性（Identifiable 最易退化的一项）

func verifyRouteIdentity() {
    let ids = allRoutes.map { $0.id }
    checkEqual(ids.count, 11, "EditorSheetRoute 必须有 11 个 case")
    checkEqual(Set(ids).count, ids.count,
               "★ 任意两个 case 不得共用同一个 id（否则 SwiftUI 会把不同 sheet 认成同一个）")
    checkEqual(Set(ids).count, 11, "★ 11 个 case 的 id 去重后仍必须是 11")

    let derivedCount = allRoutes.filter { $0.isDerivedFromModel }.count
    checkEqual(derivedCount, 2, "只有二次编辑两个路由由 model 派生")
    checkEqual(Policy.derivedRoute(isEditingText: true, isEditingShape: false), .editText,
               "派生路由必须覆盖 editText")
    checkEqual(Policy.derivedRoute(isEditingText: false, isEditingShape: true), .editShape,
               "派生路由必须覆盖 editShape")
}

// MARK: - 断言 4b：三个辅助路由的派生投影

func verifyAuxiliaryRoutes() {
    // PhotoPickerRoute.isPresented：只有 importNew / replaceExisting 在屏。
    checkEqual(PhotoRoute.none.isPresented, false, "相册选择：none 不得呈现")
    checkEqual(PhotoRoute.importNew.isPresented, true, "相册选择：importNew 必须呈现")
    checkEqual(PhotoRoute.replaceExisting.isPresented, true, "相册选择：replaceExisting 必须呈现")

    // ColorPickerRoute.toggle：toggle 语义必须自反。
    var color = ColorRoute.hidden
    checkEqual(color, .hidden, "调色盘初始必须是 hidden")
    color.toggle()
    checkEqual(color, .presented, "toggle 一次必须变为 presented")
    color.toggle()
    checkEqual(color, .hidden, "再 toggle 必须回到 hidden")

    // EditorDialogRoute：两个确认框 id 不得重复。
    let dialogIDs = [DialogRoute.clearPageConfirm.id, DialogRoute.deletePageConfirm.id]
    checkEqual(Set(dialogIDs).count, 2, "两个确认框的 id 去重后必须是 2")
}

// MARK: - 断言 5：反证 —— 恒接受的破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    var divergent = false
    var brokenAlwaysTrue = true
    var goodHasRejection = false
    for current in routeChoices {
        for requested in routeChoices {
            let good = Policy.accepts(current: current, requested: requested)
            let bad = BrokenRoutingPolicy.accepts(current: current, requested: requested)
            if good != bad { divergent = true }
            if !bad { brokenAlwaysTrue = false }
            if !good { goodHasRejection = true }
        }
    }
    check(divergent, "★ 恒接受的破坏变体必须与正确实现在异路由组合上分歧（检查器不得退化成恒真）")
    check(brokenAlwaysTrue, "破坏变体确实恒为 true —— 反证对象有效")
    check(goodHasRejection, "★ 正确实现必须存在「拒绝」情形，否则准入判定退化成恒真")

    // 显式反证：异路由组合上两个实现必然分歧。
    checkEqual(Policy.accepts(current: .camera, requested: .weather), false,
               "正确实现必须拒绝异路由")
    checkEqual(BrokenRoutingPolicy.accepts(current: .camera, requested: .weather), true,
               "破坏变体确实会放行异路由 —— 反证有效")
    check(Policy.accepts(current: .camera, requested: .weather) != BrokenRoutingPolicy.accepts(current: .camera, requested: .weather),
          "正反两实现必须在异路由组合上分歧")
}

// MARK: - 运行

verifySourceGuardrails()
verifyAcceptsExhaustive()
verifyDerivedRoute()
verifyRequiresModelCleanup()
verifyRouteIdentity()
verifyAuxiliaryRoutes()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 编辑器模态路由：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
