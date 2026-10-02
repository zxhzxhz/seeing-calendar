#!/usr/bin/env swift
//
//  verify_subscription_management.swift
//  订阅源与维度管理门禁（CI 以 --strict 执行）。
//
//  钉住四件用户看得见的约定，任何一条回退都让构建失败：
//
//  ① 内置凭据（放假 / 调休）恒定居底 —— 排序必须是**稳定分区**，不得换成全量排序：
//     全量排序会把用户自建项的顺序一起改写，重启后列表自己重排，用户会以为丢订阅。
//  ② 内置凭据不可删除、不可改名 —— 滑动删除的开关与程序化删除的守卫**两条路径都要拦**：
//     只删开关只能挡住手势，挡不住别处调 `delete(at:)`。
//  ③ 列表渲染与滑动删除必须吃**同一份**排序结果 —— 否则删除落到错行，是数据丢失级问题，
//     也是 SwiftUI List 上最容易悄悄发生的一种回退。
//  ④ 自建订阅可改名称与作用域；维度可重命名，且不得删到只剩零个维度。
//
//      swift scripts/verify_subscription_management.swift --strict
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

// MARK: - 源码读取

let root = FileManager.default.currentDirectoryPath

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 折叠所有空白，便于跨行断言。
func normalizeWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
}

// MARK: - 被测逻辑（生产代码的镜像）
//
// `ICSSubscription.displayOrder` 就是「稳定分区」：非内置段在前、内置段在后，
// 两段都原样保留输入顺序（输入来自 `@Query(sort: \.createdAt)`）。

struct SubscriptionRow: Equatable {
    let name: String
    let isBuiltIn: Bool
}

func displayOrderMirror(_ items: [SubscriptionRow]) -> [SubscriptionRow] {
    items.filter { !$0.isBuiltIn } + items.filter { $0.isBuiltIn }
}

let userSchedule = SubscriptionRow(name: "我的课表", isBuiltIn: false)
let userRoadmap = SubscriptionRow(name: "项目排期", isBuiltIn: false)
let builtInOffDay = SubscriptionRow(name: "中国大陆放假", isBuiltIn: true)
let builtInMakeUpWork = SubscriptionRow(name: "中国大陆调休", isBuiltIn: true)

func verifyBuiltInSourcesSinkToBottom() {
    // 内置夹在中间：仍然全部沉底，且两段各自保序。
    let mixed = [builtInOffDay, userSchedule, builtInMakeUpWork, userRoadmap]
    checkEqual(displayOrderMirror(mixed), [userSchedule, userRoadmap, builtInOffDay, builtInMakeUpWork],
               "★ 内置凭据必须沉底，且两段内部保持输入顺序")

    // 已沉底的列表再排一次不得变化（幂等）：否则每次重绘列表都会跳一下。
    let settled = displayOrderMirror(mixed)
    checkEqual(displayOrderMirror(settled), settled, "★ 排序必须幂等（重复渲染不得让列表跳动）")

    // 最后一行必须是内置凭据：滑动删除时用户看到的行序与删除目标不能错位。
    let ordered = displayOrderMirror(mixed)
    check(ordered.last?.isBuiltIn == true, "最后一行必须是内置凭据（置底）")
    check(ordered.prefix(2).allSatisfy { !$0.isBuiltIn }, "内置凭据不得挤进自建段")

    // 退化输入：全内置 / 全自建 / 空表都原样返回。
    checkEqual(displayOrderMirror([builtInMakeUpWork, builtInOffDay]), [builtInMakeUpWork, builtInOffDay],
               "全内置时保持输入顺序")
    checkEqual(displayOrderMirror([userRoadmap, userSchedule]), [userRoadmap, userSchedule],
               "全自建时保持输入顺序")
    checkEqual(displayOrderMirror([]), [], "空表返回空表")
}

func verifySortingIsAStablePartition() {
    guard let models = productionSource("SeeingCalendar/Models/Models.swift") else {
        check(false, "读不到 SeeingCalendar/Models/Models.swift")
        return
    }
    let code = normalizeWhitespace(models)

    check(code.contains("static func displayOrder(_ items: [ICSSubscription]) -> [ICSSubscription]"),
          "displayOrder 必须吃整份列表并返回整份列表")

    // ★ 这是本门禁最重要的一条：实现必须是 filter + filter 的稳定分区。
    // 换成 sorted(by:) 会连用户自建项的顺序一起改写。
    check(code.contains("items.filter { !$0.isBuiltIn } + items.filter(\\.isBuiltIn)"),
          "★ 排序必须是稳定分区（filter + filter），不得换成 sorted(by:)")

    check(code.contains("var isBuiltIn: Bool = false"),
          "内置标记必须带默认值：老库升级依赖 SwiftData 轻量迁移")
}

func verifyListViewWiring() {
    guard let view = productionSource("SeeingCalendar/Views/SubscriptionsView.swift") else {
        check(false, "读不到 SeeingCalendar/Views/SubscriptionsView.swift")
        return
    }
    let code = normalizeWhitespace(view)

    check(code.contains("@Query(sort: \\ICSSubscription.createdAt) private var subscriptions"),
          "订阅列表必须按 createdAt 取数 —— 稳定分区依赖这个输入顺序")

    // ③ 渲染与删除共用同一份排序结果。
    check(code.contains("private var orderedSubscriptions: [ICSSubscription] {"),
          "必须存在唯一的排序出口 orderedSubscriptions")
    check(code.contains("ICSSubscription.displayOrder(subscriptions)"),
          "orderedSubscriptions 必须走 displayOrder")
    check(code.contains("ForEach(orderedSubscriptions) { subscription in"),
          "★ 列表渲染必须吃排序结果（否则屏幕上看到的顺序与删除目标不一致）")
    check(code.contains("let subscription = orderedSubscriptions[index]"),
          "★ 滑动删除必须索引同一份排序结果（错位即删错订阅）")

    // ② 内置凭据两条删除路径都要拦。
    check(code.contains(".deleteDisabled(subscription.isBuiltIn)"),
          "内置凭据不得出现滑动删除开关")
    check(code.contains("guard !subscription.isBuiltIn else { continue }"),
          "★ 程序化删除也必须跳过内置凭据（只删开关挡不住这条路径）")

    // ② 内置凭据不得进入编辑面板。
    check(code.contains(".disabled(subscription.isBuiltIn)"),
          "内置凭据不得进入编辑面板（行首按钮对 isBuiltIn 禁用）")

    // ④ 自建订阅可改名称 + 作用域。
    check(code.contains(".sheet(item: $editingSubscription)"),
          "编辑面板必须由 editingSubscription 驱动")
    check(code.contains("subscription.name = trimmed"),
          "编辑必须写回名称")
    check(code.contains("subscription.workspaceUUID = scope"),
          "编辑必须写回作用域")
    check(code.contains("guard !trimmed.isEmpty else { return }"),
          "空名必须被编辑面板拒绝")
    check(code.contains("Picker(\"作用域\", selection: $scope)"),
          "编辑面板必须有作用域选择器")
    check(code.contains("Text(\"全局\").tag(UUID?.none)"),
          "作用域必须能改回「全局」（nil = 所有维度可见）")
    check(code.contains("Text(workspace.name).tag(UUID?.some(workspace.uuid))"),
          "作用域必须能指定到某个维度")

    // ④ 维度重命名 + 不得删到零个维度。
    check(code.contains("repository.renameWorkspace(workspace, to: trimmed)"),
          "维度重命名必须走仓储唯一入口")
    check(code.contains("guard !trimmed.isEmpty, trimmed != workspace.name else { return }"),
          "空名与同名必须在提交前早退")
    check(code.contains("guard workspaces.count > targets.count else { return }"),
          "★ 不得删到只剩零个维度")
}

func verifyWorkspaceRename() {
    guard let repo = productionSource("SeeingCalendar/Store/PageRepository.swift") else {
        check(false, "读不到 SeeingCalendar/Store/PageRepository.swift")
        return
    }
    let code = normalizeWhitespace(repo)

    check(code.contains("func renameWorkspace(_ workspace: Workspace, to name: String) -> Bool"),
          "PageRepository.renameWorkspace 必须存在且回传是否落库")
    check(code.contains("let trimmed = name.trimmingCharacters(in: .whitespaces)"),
          "维度名必须先修剪空白")
    check(code.contains("guard !trimmed.isEmpty else { return false }"),
          "空白维度名必须被拒绝")
    check(code.contains("workspace.name = trimmed"),
          "重命名只写 name 字段")
}

// MARK: - 运行

verifyBuiltInSourcesSinkToBottom()
verifySortingIsAStablePartition()
verifyListViewWiring()
verifyWorkspaceRename()

let strict = CommandLine.arguments.contains("--strict")

print("")
if failures.isEmpty {
    print("PASS  订阅源与维度管理门禁（内置置底 / 不可删除 / 可编辑）— \(checks) 项断言")
} else {
    print("FAIL  订阅源与维度管理门禁 — \(failures.count)/\(checks) 项断言失败")
    for failure in failures {
        print("      • \(failure)")
    }
}

if strict, !failures.isEmpty {
    exit(1)
}
exit(0)