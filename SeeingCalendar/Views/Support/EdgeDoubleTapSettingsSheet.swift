import SwiftUI

/// 画布边缘双击快捷切换工具设置面板
struct EdgeDoubleTapSettingsSheet: View {
    @State private var settings: EdgeDoubleTapSettings
    let onSave: (EdgeDoubleTapSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    init(settings: EdgeDoubleTapSettings, onSave: @escaping (EdgeDoubleTapSettings) -> Void) {
        self._settings = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    sideSection(title: "左侧边缘感应区", config: $settings.left)
                } header: {
                    Label("左侧感应区", systemImage: "arrow.left.to.line")
                } footer: {
                    Text("画布左侧留白区域，适合双手操作时左手拇指双击快速切换。")
                }

                Section {
                    sideSection(title: "右侧边缘感应区", config: $settings.right)
                } header: {
                    Label("右侧感应区", systemImage: "arrow.right.to.line")
                } footer: {
                    Text("画布右侧留白区域，适合右手握笔时闲置手指双击快速切换。")
                }

                Section("防误触与响应说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• 仅响应手指触摸，完全忽略 Apple Pencil 笔尖触控。")
                        Text("• 感应区位于画纸外侧留白边缘。当画布放大至超过屏幕边界时，热区将自动停用以防误触。")
                        Text("• 选择「切换至指定工具」时，再次双击将切回原工具。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("边缘双击快捷切换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func sideSection(title: String, config: Binding<EdgeTapSideConfig>) -> some View {
        Toggle("开启双击响应", isOn: config.isEnabled)

        if config.wrappedValue.isEnabled {
            Picker("动作模式", selection: config.mode) {
                Text(EdgeTapActionMode.switchToPrevious.title).tag(EdgeTapActionMode.switchToPrevious)
                Text(EdgeTapActionMode.switchToDesignated.title).tag(EdgeTapActionMode.switchToDesignated)
            }
            .pickerStyle(.segmented)

            if config.wrappedValue.mode == .switchToDesignated {
                Picker("指定目标工具", selection: config.designatedTool) {
                    ForEach(EdgeSwitchTargetTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(tool)
                    }
                }
            }
        }
    }
}
