import SwiftUI

extension View {
    /// 订阅作用域多选：**行内可展开的勾选列表**，直接产出多行。
    ///
    /// 为什么是 `@ViewBuilder` 函数而不是一个自定义 `View`：`List` / `Form` 只把
    /// ViewBuilder 直接产出的容器（`ForEach`、`if` 分支、以及函数返回的 variadic 视图）
    /// 展开成多行，**自定义 `View` 是一个行边界**。写成 `struct … : View` 的话，
    /// 展开出来的一排勾选项会被塞进同一个单元格里挤成一行，
    /// 而且编译期毫无提示 —— 这是本文件最容易被"顺手重构"掉的一条约束。
    ///
    /// 语义：**空作用域 = 全局**。「全局」那行与维度行互斥：点「全局」清空选择；
    /// 全局态下点某个维度即从「只选这一个」开始（见 `SubscriptionScope.toggling`）。
    ///
    /// 新增区与编辑面板共用这一份实现 —— 判定语义与勾选外观都只写一处。
    @ViewBuilder
    func subscriptionScopeRows(scope: Binding<[UUID]>,
                               workspaces: [Workspace],
                               isExpanded: Binding<Bool>) -> some View {
        // 摘要行：右侧只报数量，不拼维度名 —— 用户自建的维度名可能很长，
        // 拼进来会让这一行的高度随名字变化，列表看起来在抖。
        Button {
            withAnimation(.snappy(duration: 0.22)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Text("作用域")
                Spacer(minLength: 12)
                Text(SubscriptionScope.summary(scope.wrappedValue))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isExpanded.wrappedValue {
            scopeOptionRow(title: "全局（所有维度）", isSelected: scope.wrappedValue.isEmpty) {
                scope.wrappedValue = []
            }
            ForEach(workspaces) { workspace in
                scopeOptionRow(title: workspace.name,
                               isSelected: scope.wrappedValue.contains(workspace.uuid),
                               indent: true) {
                    scope.wrappedValue = SubscriptionScope.toggling(scope.wrappedValue, workspace.uuid)
                }
            }
            Text("只有勾选的维度会显示这条订阅的日程；「全局」＝ 所有维度可见。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// 单个勾选行。走 `Button` + `contentShape`：整行可点，而不只是图标那一小块。
    @ViewBuilder
    private func scopeOptionRow(title: String,
                                isSelected: Bool,
                                indent: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
