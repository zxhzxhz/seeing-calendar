#!/usr/bin/env swift
//
//  verify_subscription_management.swift
//  订阅源与维度管理门禁（CI 以 --strict 执行）。
//
//  钉住用户看得见的约定，任何一条回退都让构建失败：
//
//  ① 内置凭据（放假 / 调休）恒定居底 —— 排序必须是**稳定分区**，不得换成全量排序：
//     全量排序会把用户自建项的顺序一起改写，重启后列表自己重排，用户会以为丢订阅。
//  ② 内置凭据不可删除、不可改名 —— 滑动删除的开关与程序化删除的守卫**两条路径都要拦**：
//     只删开关只能挡住手势，挡不住别处调 `delete(at:)`。
//  ③ 列表渲染与滑动删除必须吃**同一份**排序结果 —— 否则删除落到错行，是数据丢失级问题，
//     也是 SwiftUI List 上最容易悄悄发生的一种回退。
//  ④ 自建订阅可改名称与作用域；维度可重命名，且不得删到只剩零个维度。
//  ⑤ ★ 作用域必须**真的筛** —— 1.0.23 之前 `applies(to:)` 全仓库无人调用，
//     `SubscriptionSnapshot.workspaceUUID` 从未被读，作用域只是个装饰字段。
//     多选之后这条尤其要紧：一个不生效的多选比一个不生效的单选更像"做完了"。
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

// `ICSSubscription.displayOrder` 就是「稳定分区」：非内置段在前、内置段在后，
// 两段都原样保留输入顺序（输入来自 `@Query(sort: \.createdAt)`）。

struct SubscriptionRow: Equatable {
    let name: String
    let isBuiltIn: Bool
}

func displayOrderMirror(_ items: [SubscriptionRow]) -> [SubscriptionRow] {
    items.filter { !$0.isBuiltIn } + items.filter { $0.isBuiltIn }
}

/// 作用域判定的镜像（`SubscriptionScope`）：**空 = 全局**。
///
/// 抽成 enum 而不是散在各处，是因为订阅模型与事件快照都要判同一件事 ——
/// 两边各写一份，总有一边会先改。
enum ScopeMirror {
    static func applies(_ scope: [UUID], to workspace: UUID) -> Bool {
        scope.isEmpty || scope.contains(workspace)
    }

    static func toggling(_ scope: [UUID], _ workspace: UUID) -> [UUID] {
        scope.contains(workspace) ? scope.filter { $0 != workspace } : scope + [workspace]
    }
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

// MARK: - 断言：作用域语义（纯逻辑镜像）

/// 作用域的全部语义都在这几条里；界面只是它的表现。
func verifyScopeSemantics() {
    let alpha = UUID()
    let beta = UUID()
    let gamma = UUID()

    check(ScopeMirror.applies([], to: alpha), "空作用域必须命中任意维度（全局）")
    check(ScopeMirror.applies([alpha, beta], to: beta), "作用域内的维度必须命中")
    check(!ScopeMirror.applies([alpha, beta], to: gamma),
          "★ 作用域外的维度不得命中 —— 这正是 1.0.23 之前完全不生效的那条判定")

    // 全局态下的第一次勾选是「脱离全局」，不是「在空的上面追加」。
    checkEqual(ScopeMirror.toggling([], alpha), [alpha], "全局态下勾选某维度应从「只选这一个」开始")
    checkEqual(ScopeMirror.toggling([alpha], beta), [alpha, beta], "再勾一个应是追加")
    checkEqual(ScopeMirror.toggling([alpha, beta], alpha), [beta], "取消勾选只摘掉那一个")
    checkEqual(ScopeMirror.toggling([alpha], alpha), [], "取消到最后一个即回到全局（空）")
    check(ScopeMirror.applies(ScopeMirror.toggling([alpha], alpha), to: beta),
          "回到空作用域后必须重新对所有维度可见（不是变成谁都不命中）")

    // 可逆：连点两次回到原状，用户不会越点越乱。
    checkEqual(ScopeMirror.toggling(ScopeMirror.toggling([alpha], beta), beta), [alpha],
               "勾选必须可逆（同一维度连点两次回到原状）")

    // 互斥的可见表现：「全局」行选中（作用域为空）时不可能同时"选了某个维度"。
    check(ScopeMirror.applies([], to: alpha) && ScopeMirror.applies([], to: beta),
          "「全局」行选中必须对所有维度可见")
    checkEqual(ScopeMirror.toggling([], alpha).isEmpty, false,
               "点过维度之后不得再是全局态（两行不可能同时选中）")
}

// MARK: - 断言 ⑤：作用域必须真的参与筛选

func verifyScopeIsEnforced() {
    guard let rootView = productionSource("SeeingCalendar/Views/RootView.swift") else {
        check(false, "读不到 SeeingCalendar/Views/RootView.swift")
        return
    }
    let viewCode = normalizeWhitespace(rootView)

    check(viewCode.contains("SubscriptionScope.applies($0.scope, to: workspaceUUID)"),
          "★ 月历必须按作用域筛选事件（否则作用域又变成装饰字段）")
    check(viewCode.contains("private func scopedEvents(on date: Date) -> [CalendarEvent]"),
          "抽屉必须走按作用域筛过的出口")
    check(viewCode.contains("events: scopedEvents(on: selectedDate)"),
          "★ 抽屉必须调用 scopedEvents —— 只管月历不管抽屉的话，同一天两个界面会给出不同答案")
    check(viewCode.contains("workspace?.uuid.uuidString.hashValue"),
          "★ 当前维度必须参与内容指纹：否则切维度时事件数量恰好相同时月历不重绘，接着画上一块画板的彩点")

    guard let event = productionSource("SeeingCalendar/Models/CalendarEvent.swift") else {
        check(false, "读不到 SeeingCalendar/Models/CalendarEvent.swift")
        return
    }
    let eventCode = normalizeWhitespace(event)

    check(eventCode.contains("static func applies(_ scope: [UUID], to workspaceUUID: UUID) -> Bool"),
          "作用域判定只能有一份实现（SubscriptionScope），两个类型不得各写一遍")
    check(code.contains("static func toggling(_ scope: [UUID], _ workspaceUUID: UUID) -> [UUID]"),
          "勾选切换必须也是共享实现（模型与界面不得各判一次）")
    check(eventCode.contains("static func summary(_ scope: [UUID]) -> String"),
          "作用域摘要也必须共享（界面不得自己拼「N 个维度」）")
    check(eventCode.contains("var scope: [UUID] = []"),
          "事件快照必须携带作用域")
    check(eventCode.contains("scope = try container.decodeIfPresent([UUID].self, forKey: .scope) ?? []"),
          "★ 旧缓存没有 scope 键时必须按「全局」解码（decodeIfPresent），不得 keyNotFound 让整个缓存失效")
    check(eventCode.contains("case location, start, end, isAllDay, isHoliday, scope"),
          "CodingKeys 必须含 scope，否则手写解码取不到这一项")

    guard let store = productionSource("SeeingCalendar/ICS/CalendarEventStore.swift") else {
        check(false, "读不到 SeeingCalendar/ICS/CalendarEventStore.swift")
        return
    }
    let storeCode = normalizeWhitespace(store)

    check(storeCode.contains("scope: subscription.workspaceUUIDs"),
          "订阅聚合必须把多选作用域放进快照")
    check(storeCode.contains("scope: snapshot.scope"),
          "事件必须带上快照作用域（显示层才有得筛）")
    check(!storeCode.contains("workspaceUUID: subscription.workspaceUUID"),
          "旧单选字段不得再进快照（两套作用域并存必然漂移）")
}

// MARK: - 断言：作用域写入唯一入口 + 维度删除清理

func verifyScopeWritePath() {
    guard let models = productionSource("SeeingCalendar/Models/Models.swift") else {
        check(false, "读不到 SeeingCalendar/Models/Models.swift")
        return
    }
    let code = normalizeWhitespace(models)

    check(code.contains("func setScope(_ scope: [UUID])"), "作用域写入必须走唯一入口 setScope")
    check(code.contains("func removeFromScope(_ workspaceUUID: UUID) -> Bool"),
          "维度被删除后必须能把它的 uuid 从作用域里摘掉")
    check(code.contains("SubscriptionScope.applies(workspaceUUIDs, to: workspaceUUID)"),
          "订阅模型必须复用共享判定，不得自己复述一遍")
    check(code.contains("static func summary(_ scope: [UUID]) -> String"),
          "摘要必须由共享约定给出（列表行与控件摘要不得分叉）")
    check(code.contains("var workspaceUUIDs: [UUID] = []"),
          "多选作用域必须带默认值：老库升级依赖 SwiftData 轻量迁移")

    // 唯一写入口的护栏：这几个文件都不得直接给 `workspaceUUIDs` 赋值。
    let guarded = [
        ("SeeingCalendar/Views/SubscriptionsView.swift", "设置页"),
        ("SeeingCalendar/App/AppDataStack.swift", "启动迁移"),
        ("SeeingCalendar/ICS/CalendarEventStore.swift", "订阅聚合"),
        ("SeeingCalendar/Store/BackupService.swift", "备份导出"),
        ("SeeingCalendar/Store/RestoreService.swift", "备份恢复")
    ]
    for (path, label) in guarded {
        guard let source = productionSource(path) else {
            check(false, "读不到 \(path)")
            continue
        }
        let flat = normalizeWhitespace(source)
        check(!flat.contains("workspaceUUIDs ="),
              "★ \(label)不得直接给 workspaceUUIDs 赋值 —— 唯一写入口是 setScope（顺带清空旧字段）")
    }
}

func verifyMigrationAndBackup() {
    guard let stack = productionSource("SeeingCalendar/App/AppDataStack.swift") else {
        check(false, "读不到 SeeingCalendar/App/AppDataStack.swift")
        return
    }
    let stackCode = normalizeWhitespace(stack)

    check(stackCode.contains("static func migrateSubscriptionScopes(in container: ModelContainer)"),
          "必须有一次性迁移入口")
    check(stackCode.contains("all.filter { $0.workspaceUUID != nil }"),
          "迁移只处理「旧字段非空」的记录 —— 幂等性靠这一点，也靠 setScope 顺手腾空旧字段")
    check(stackCode.contains("subscription.setScope(subscription.workspaceUUID.map { [$0] } ?? [])"),
          "迁移必须走 setScope 而不是直接写数组（顺带腾空旧字段，重复迁移不会把旧值盖回来）")

    guard let app = productionSource("SeeingCalendar/App/SeeingCalendarApp.swift") else {
        check(false, "读不到 SeeingCalendar/App/SeeingCalendarApp.swift")
        return
    }
    check(normalizeWhitespace(app).contains("AppDataStack.migrateSubscriptionScopes(in: container)"),
          "★ 迁移必须在 App.init 里跑：早于任何视图读模型，升级后第一帧就是正确作用域")

    guard let dto = productionSource("SeeingCalendar/Store/BackupModels.swift") else {
        check(false, "读不到 SeeingCalendar/Store/BackupModels.swift")
        return
    }
    let dtoCode = normalizeWhitespace(dto)
    check(dtoCode.contains("var workspaceUUIDs: [UUID]? = nil"),
          "备份 DTO 必须带多选作用域，且声明为可选 —— 旧备份缺这个键才不会 keyNotFound")
    check(dtoCode.contains("var workspaceUUID: UUID? = nil"),
          "旧版单选字段必须留着（只在读旧备份时用）")

    guard let restore = productionSource("SeeingCalendar/Store/RestoreService.swift") else {
        check(false, "读不到 SeeingCalendar/Store/RestoreService.swift")
        return
    }
    check(normalizeWhitespace(restore).contains("dto.workspaceUUIDs ?? dto.workspaceUUID.map { [$0] } ?? []"),
          "★ 恢复：新备份读多选、旧备份回退单选；空数组（全局）不得被当成「没写」而回退")

    guard let repo = productionSource("SeeingCalendar/Store/PageRepository.swift") else {
        check(false, "读不到 SeeingCalendar/Store/PageRepository.swift")
        return
    }
    check(normalizeWhitespace(repo).contains("subscription.removeFromScope(workspace.uuid)"),
          "★ 删除维度必须摘掉作用域里的引用：否则只绑该维度的订阅哪个维度都不命中，静默失效")
}

// MARK: - 断言 ④：列表 / 编辑面板 / 维度重命名

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

    // ④ 自建订阅可改名称 + 作用域（多选）。
    check(code.contains(".sheet(item: $editingSubscription)"),
          "编辑面板必须由 editingSubscription 驱动")
    check(code.contains("subscription.name = trimmed"),
          "编辑必须写回名称")
    check(code.contains("subscription.setScope(scope)"),
          "编辑必须走唯一入口 setScope")
    check(!code.contains("subscription.workspaceUUID = scope"),
          "编辑不得再写旧单选字段（旧字段非空只该意味着「还没迁移」）")
    check(code.contains("guard !trimmed.isEmpty else { return }"),
          "空名必须被编辑面板拒绝")
    check(code.contains("subscriptionScopeRows(scope: $scope,"),
          "★ 编辑面板必须用共享多选行构造器")
    check(code.contains("subscriptionScopeRows(scope: $newScope,"),
          "★ 新增区必须用同一个共享构造器 —— 两处各写一遍，语义迟早分叉")
    check(code.contains("@State private var isNewScopeExpanded = false"),
          "新增区必须自己持有展开状态（共享构造器是无状态函数）")
    check(code.contains("@State private var isScopeExpanded = false"),
          "编辑面板必须自己持有展开状态")
    check(code.contains("@State private var newScope: [UUID] = []"),
          "新增区作用域必须是数组（多选）")
    check(code.contains("scope: newScope"), "新增订阅必须把多选作用域写进模型")
    check(!code.contains("Picker(\"作用域\""),
          "★ 不得回退到单选 Picker：它的 selection 是单值，多选表达不了")

    // ④ 维度重命名 + 不得删到零个维度。
    check(code.contains("repository.renameWorkspace(workspace, to: trimmed)"),
          "维度重命名必须走仓储唯一入口")
    check(code.contains("guard !trimmed.isEmpty, trimmed != workspace.name else { return }"),
          "空名与同名必须在提交前早退")
    check(code.contains("guard workspaces.count > targets.count else { return }"),
          "★ 不得删到只剩零个维度")
}

// MARK: - 断言：多选控件本身（贴合 App 风格）

func verifyScopePickerWiring() {
    guard let picker = productionSource("SeeingCalendar/Views/SubscriptionScopeRows.swift") else {
        check(false, "读不到 SeeingCalendar/Views/SubscriptionScopeRows.swift")
        return
    }
    let code = normalizeWhitespace(picker)

    check(code.contains("@ViewBuilder func subscriptionScopeRows(scope: Binding<[UUID]>"),
          "★ 必须是 @ViewBuilder 函数：List / Form 只展开 ViewBuilder 直接产出的容器")
    check(!code.contains("struct SubscriptionScopePicker: View"),
          "★ 不得改回自定义 View：自定义 View 是行边界，展开出的勾选项会被塞进同一个单元格里")
    check(code.contains("scope: Binding<[UUID]>"), "控件必须吃数组绑定（多选）")
    check(code.contains("isSelected: scope.wrappedValue.isEmpty"),
          "「全局」行的选中态＝作用域为空 —— 互斥在界面上是可见的，不是靠文案解释")
    check(code.contains("scope.wrappedValue = []"), "点「全局」必须清空其余选择")
    check(code.contains("SubscriptionScope.summary(scope.wrappedValue)"),
          "摘要必须走共享实现，不得在界面里再拼一遍")
    check(!code.contains("个维度\""),
          "★ 不得在界面里重写「N 个维度」文案：两处文案一旦分叉，两屏看起来就是两个功能")
    check(code.contains("SubscriptionScope.toggling(scope.wrappedValue, workspace.uuid)"),
          "维度行必须走共享切换逻辑")
    check(code.contains("ForEach(workspaces)"), "维度必须是多选行，而不是单选器")
    check(code.contains("checkmark.circle.fill"), "选中态必须有勾选标记")
    check(code.contains("Color.accentColor"), "选中态用 accentColor（与 App 既有高亮一致）")
    check(code.contains(".accessibilityAddTraits"), "勾选态必须有无障碍语义")
    check(code.contains("withAnimation"), "展开 / 收起必须有动画")
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
verifyScopeSemantics()
verifySortingIsAStablePartition()
verifyScopeIsEnforced()
verifyScopeWritePath()
verifyMigrationAndBackup()
verifyListViewWiring()
verifyScopePickerWiring()
verifyWorkspaceRename()

let strict = CommandLine.arguments.contains("--strict")

print("")
if failures.isEmpty {
    print("PASS  订阅源与维度管理门禁（内置置底 / 不可删除 / 多选作用域真的生效）— \(checks) 项断言")
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
