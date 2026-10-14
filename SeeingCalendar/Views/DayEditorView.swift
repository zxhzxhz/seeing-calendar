import PhotosUI
import PencilKit
import SwiftData
import SwiftUI
import UIKit

/// 单日画布编辑器（1:1 正方形虚拟画布 1400×1400，多页，Page 1 为月历封面）。
struct DayEditorView: View {
    let day: DayRecord
    let workspace: Workspace
    let context: ModelContext
    let initialPageIndex: Int
    let isFingerDrawingEnabled: Bool
    /// 编辑器内的触控模式切换会回写为全局默认值。
    let onFingerDrawingChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: EditorModel
    @State private var photoItem: PhotosPickerItem?
    @State private var replacementItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var isClearConfirmPresented = false
    @State private var isDeletePageConfirmPresented = false
    @State private var isColorPickerPresented = false
    @State private var isPageManagerPresented = false
    @State private var isWeatherSheetPresented = false
    @State private var isAddTextPresented = false
    @State private var isAddStickerPresented = false
    @State private var isAddSignaturePresented = false
    @State private var isAddShapePresented = false
    @State private var isEdgeDoubleTapSettingsPresented = false
    @Namespace private var pageStripNamespace

    init(day: DayRecord,
         workspace: Workspace,
         context: ModelContext,
         initialPageIndex: Int,
         isFingerDrawingEnabled: Bool,
         onFingerDrawingChanged: @escaping (Bool) -> Void) {
        self.day = day
        self.workspace = workspace
        self.context = context
        self.initialPageIndex = initialPageIndex
        self.isFingerDrawingEnabled = isFingerDrawingEnabled
        self.onFingerDrawingChanged = onFingerDrawingChanged

        let created = EditorModel(day: day, workspace: workspace, context: context)
        created.setInitialPage(initialPageIndex)
        created.isFingerDrawingEnabled = isFingerDrawingEnabled
        self._model = State(initialValue: created)
    }

    var body: some View {
        content(model: model)
            .onAppear {
                model.onRequestDismiss = { dismiss() }
                model.onRequestToggleColorPicker = {
                    isColorPickerPresented.toggle()
                }
            }
            .task {
                await WeatherService.shared.fetchWeather(for: model.date)
            }
    }

    // MARK: - 主体

    private func content(model: EditorModel) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                pageStrip(model: model)
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                CanvasRepresentable(model: model)
                    .overlay(alignment: .top) {
                        VStack(spacing: 6) {
                            toastBanner(model: model)
                                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: model.toastMessage)
                            hintBanner(model: model)
                                .animation(.spring(response: 0.22, dampingFraction: 0.84), value: model.selectionKind != .none)
                        }
                    }
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                toolBar(model: model)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent(model: model) }
            // 系统的交互式消失手势无法按区域开关，且动态开关本身不可靠 —— 一律禁用，
            // 改为在指定区域自实现下拉返回：顶部标签行 / 页条 / 画纸四周留白。
            // （画纸之内绝不响应，避免绘制与拖动手势被误判为返回。）
            .interactiveDismissDisabled(true)
            .onDisappear {
                model.finishEditing()
                // 编辑过程中不回写全局开关（会触发外层重渲染并打断 UIKit 状态），关闭时统一回写。
                onFingerDrawingChanged(model.isFingerDrawingEnabled)
            }
        }
        .photosPicker(isPresented: photoPickerBinding(model: model), selection: $photoItem, matching: .images)
        .photosPicker(isPresented: replacementPickerBinding(model: model), selection: $replacementItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await importPicked(newValue, model: model) }
        }
        .onChange(of: replacementItem) { _, newValue in
            guard let newValue else { return }
            Task { await importReplacement(newValue, model: model) }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.94) {
                    model.importImage(data: data, fileExtension: "jpg")
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                model.importImage(fromURL: url)
            }
        }
        .sheet(isPresented: $isPageManagerPresented) {
            PageManagerSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isWeatherSheetPresented) {
            WeatherLocationSheet(date: model.date)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isAddTextPresented) {
            AddTextSheet { data, config in
                model.importImage(data: data, fileExtension: "png", payload: .text(config))
            }
        }
        .sheet(isPresented: $isAddStickerPresented) {
            AddStickerSheet { data in
                model.importImage(data: data, fileExtension: "png")
            }
        }
        .sheet(isPresented: $isAddSignaturePresented) {
            AddSignatureSheet { data in
                model.importImage(data: data, fileExtension: "png")
            }
        }
        .sheet(isPresented: $isAddShapePresented) {
            AddShapeSheet { data, config in
                model.importImage(data: data, fileExtension: "png", payload: .shape(config))
            }
        }
        .sheet(isPresented: editTextBinding(model: model)) {
            AddTextSheet(initialConfig: model.editingTextConfig) { data, config in
                if let id = model.editingItemID {
                    model.updateEditedItem(id: id, data: data, payload: .text(config))
                }
            }
        }
        .sheet(isPresented: editShapeBinding(model: model)) {
            AddShapeSheet(initialConfig: model.editingShapeConfig) { data, config in
                if let id = model.editingItemID {
                    model.updateEditedItem(id: id, data: data, payload: .shape(config))
                }
            }
        }
        .sheet(isPresented: $isEdgeDoubleTapSettingsPresented) {
            EdgeDoubleTapSettingsSheet(settings: model.edgeDoubleTapSettings) { newSettings in
                model.updateEdgeDoubleTapSettings(newSettings)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("确认清空当前页所有笔迹与贴图？", isPresented: $isClearConfirmPresented, titleVisibility: .visible) {
            Button("清空当前页", role: .destructive) { model.clearPage() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除当前页？该页笔迹与贴图将不可恢复。", isPresented: $isDeletePageConfirmPresented, titleVisibility: .visible) {
            Button("删除 Page \(model.pageIndex + 1)", role: .destructive) { model.deleteCurrentPage() }
            Button("取消", role: .cancel) {}
        }
    }

    private func photoPickerBinding(model: EditorModel) -> Binding<Bool> {
        Binding(get: { model.isReplacingImage == false && isPhotoPickerRequested },
                set: { isPhotoPickerRequested = $0 })
    }

    private func replacementPickerBinding(model: EditorModel) -> Binding<Bool> {
        Binding(get: { model.isReplacingImage },
                set: { model.isReplacingImage = $0 })
    }

    private func editTextBinding(model: EditorModel) -> Binding<Bool> {
        Binding(get: { model.isEditingText },
                set: { model.isEditingText = $0 })
    }

    private func editShapeBinding(model: EditorModel) -> Binding<Bool> {
        Binding(get: { model.isEditingShape },
                set: { model.isEditingShape = $0 })
    }

    @State private var isPhotoPickerRequested = false

    // MARK: - 页面条

    private func pageStrip(model: EditorModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.pages.enumerated()), id: \.element.uuid) { index, page in
                    let isSelected = model.pageIndex == index
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            model.selectPage(index)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Page \(index + 1)")
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            if index == 0 {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 9))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "activePageIndicator", in: pageStripNamespace)
                            } else {
                                Capsule()
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(page.index == 0 ? "月历封面页" : "第 \(index + 1) 页")
                    // 长按拖动即可调整页面顺序（系统拖放），拖到首位即成为月历封面。
                    .draggable(page.uuid.uuidString) {
                        Text("Page \(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                        withAnimation(.snappy) {
                            model.movePage(id: id, toIndex: index)
                        }
                        return true
                    }
                }

                Button {
                    model.addPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)

                Button {
                    isPageManagerPresented = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("页面排序")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 页条同样支持下拉返回（横向滚动由 ScrollView 负责，纵向拖动交给这里）
        .simultaneousGesture(pullDownToDismiss)
    }

    // MARK: - 提示条与 Toast
    @ViewBuilder
    private func toastBanner(model: EditorModel) -> some View {
        if let msg = model.toastMessage {
            Text(msg)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 6, y: 2)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            model.toastMessage = nil
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func hintBanner(model: EditorModel) -> some View {
        if model.selectionKind != .none {
            Text(hintText(for: model.selectionKind))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .padding(.top, 8)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private func hintText(for kind: CanvasSelectionKind) -> String {
        switch kind {
        case .none: return ""
        case .composite: return "已框选笔迹/贴图 · 使用上方菜单操作"
        case .compositeTransform: return "拖拽手柄整体缩放 · 顶部锚点旋转"
        case .image: return "贴图编辑态 · 四角等比 / 四边裁剪 / 顶部旋转"
        case .cropping: return "裁剪视窗中 · 原始码流保持不变"
        }
    }

    // MARK: - 工具栏

    private func toolBar(model: EditorModel) -> some View {
        HStack(spacing: 12) {
            // 模式级动作（裁剪 / 变形）放在底部工具条：不遮挡任何手柄。
            contextualActions(model: model)

            // 撤销 / 重做组
            HStack(spacing: 2) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                }
                .disabled(!model.canUndo)

                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                }
                .disabled(!model.canRedo)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill).opacity(0.5))
            )

            Divider().frame(height: 20)

            // 画笔工具组
            HStack(spacing: 4) {
                ForEach(CanvasTool.allCases) { tool in
                    let isSelected = model.activeTool == tool && !model.isLassoActive
                    Button {
                        model.select(tool: tool)
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                    }
                    .accessibilityLabel(tool.title + "（再次点按可取消）")
                }

                Button {
                    isColorPickerPresented.toggle()
                } label: {
                    if model.activeTool == .eraser {
                        Image(systemName: model.eraserMode.symbol)
                            .font(.system(size: 14))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill).opacity(0.6))
                            )
                    } else {
                        Circle()
                            .fill(Color(hex: model.penColorHex, fallback: .blue))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5))
                            .frame(width: 34, height: 34)
                    }
                }
                .accessibilityLabel(model.activeTool == .eraser ? "橡皮设置" : "墨色与笔宽")
                .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                    penSettings(model: model)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill).opacity(0.4))
            )

            Divider().frame(height: 20)

            // 套索与触控
            HStack(spacing: 4) {
                Button {
                    model.toggleLasso()
                } label: {
                    Image(systemName: "lasso")
                        .font(.system(size: 15, weight: model.isLassoActive ? .semibold : .regular))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(model.isLassoActive ? Color.accentColor : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(model.isLassoActive ? Color.accentColor.opacity(0.20) : Color.clear)
                        )
                }
                .accessibilityLabel("统一套索")

                Button {
                    model.isFingerDrawingEnabled.toggle()
                } label: {
                    Image(systemName: model.isFingerDrawingEnabled ? "hand.draw.fill" : "hand.draw")
                        .font(.system(size: 15))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(model.isFingerDrawingEnabled ? Color.accentColor : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(model.isFingerDrawingEnabled ? Color.accentColor.opacity(0.20) : Color.clear)
                        )
                }
                .accessibilityLabel("手指书写开关")
            }

            // 添加元素菜单
            Menu {
                Button {
                    isAddTextPresented = true
                } label: {
                    Label("添加文本", systemImage: "character.textbox")
                }

                Button {
                    isAddStickerPresented = true
                } label: {
                    Label("添加贴纸", systemImage: "face.smiling")
                }

                Button {
                    isAddSignaturePresented = true
                } label: {
                    Label("添加签名", systemImage: "signature")
                }

                Button {
                    isAddShapePresented = true
                } label: {
                    Label("添加形状", systemImage: "square.on.circle")
                }

                Divider()

                Button {
                    isPhotoPickerRequested = true
                } label: {
                    Label("添加照片", systemImage: "photo")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )
            }
            .accessibilityLabel("添加元素（文本、贴纸、签名、形状、图片）")

            Spacer(minLength: 0)

            if model.isLassoActive {
                Text("套索")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            } else if model.isNavigating {
                Text("导航")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            Button {
                model.toggleCanvasZoom()
            } label: {
                Image(systemName: model.isCanvasExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(model.isCanvasExpanded ? Color.accentColor : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.isCanvasExpanded ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill).opacity(0.6))
                    )
            }
            .accessibilityLabel(model.isCanvasExpanded ? "缩小画布" : "最大化画布")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private func contextualActions(model: EditorModel) -> some View {
        switch model.selectionKind {
        case .cropping:
            Button("取消") { model.performSelectionAction(.cancelCrop) }
                .font(.system(size: 13))
            Button("完成裁剪") { model.performSelectionAction(.finishCrop) }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Divider().frame(height: 22)
        case .compositeTransform:
            Button("完成变形") { model.performSelectionAction(.finishTransform) }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Divider().frame(height: 22)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func penSettings(model: EditorModel) -> some View {
        if model.activeTool == .eraser {
            eraserSettings(model: model)
        } else {
            inkSettings(model: model)
        }
    }

    private func eraserSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("橡皮模式").font(.headline)
            VStack(spacing: 6) {
                ForEach(EraserMode.allCases) { mode in
                    let isSelected = model.eraserMode == mode
                    Button {
                        model.updateEraserMode(mode)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 15))
                                .frame(width: 24)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                Text(mode.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill).opacity(0.4))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Text("橡皮大小")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(model.eraserWidth)) pt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.eraserWidth }, set: { model.updateEraserWidth($0) }),
                       in: 8...160,
                       step: 2)
                Image(systemName: "circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 270)

            Text("触碰画布时会显示同等大小的空心圆圈，圈内即为擦除范围。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 270, alignment: .leading)
        }
        .padding(16)
        .frame(width: 302)
    }

    private func inkSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("墨色").font(.headline)
            PencilColorPaletteView(selectedHex: model.penColorHex) { hex in
                model.updatePenColor(hex)
            }
            .padding(.vertical, 2)

            Divider()

            HStack {
                Text("不透明度")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(round(model.penOpacity * 100)))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.penOpacity }, set: { model.updatePenOpacity($0) }),
                    in: 0.1...1.0,
                    step: 0.05
                )
                Image(systemName: "circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 270)

            Divider()

            HStack {
                Text("笔宽")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(model.penWidth)) pt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "scribble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.penWidth }, set: { model.updatePenWidth($0) }), in: 1...28, step: 1)
                Image(systemName: "scribble.variable")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 270)

            // 固定粗细预设档位
            let presets = model.currentWidthPresets
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    let isCurrent = abs(model.penWidth - preset) < 0.5
                    Button {
                        model.updatePenWidth(preset)
                    } label: {
                        Text("\(Int(preset)) pt")
                            .font(.system(size: 12, weight: isCurrent ? .bold : .medium, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 270, alignment: .leading)
        }
        .padding(16)
        .frame(width: 302)
    }

    /// 顶部标签行 / 页条的下拉返回手势：
    /// 只认「向下为主」的拖动，位移 > 90pt 或预测位移 > 180pt 即返回主页面。
    private var pullDownToDismiss: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let dy = value.translation.height
                let dx = value.translation.width
                guard dy > abs(dx) else { return }
                let projected = value.predictedEndTranslation.height
                guard dy > 90 || projected > 180 else { return }
                dismiss()
            }
    }

    @ToolbarContentBuilder
    private func toolbarContent(model: EditorModel) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                isWeatherSheetPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(CalendarUtils.dayTitle(model.date))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    if let weather = WeatherService.shared.weather(for: model.date) {
                        HStack(spacing: 4) {
                            Image(systemName: weather.systemSymbol)
                                .font(.system(size: 11.5, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.accentColor)
                            Text("天气\(weather.conditionDescription) 气温\(Int(weather.tempMin.rounded()))~\(Int(weather.tempMax.rounded()))℃")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                        .foregroundStyle(Color.accentColor)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gesture(pullDownToDismiss)
            .accessibilityLabel("日期与天气信息，点击可管理城市与定位")
        }

        ToolbarItem(placement: .topBarLeading) {
            Button("完成") {
                model.finishEditing()
                dismiss()
            }
            .fontWeight(.semibold)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Section("手势与快捷操作") {
                    Button {
                        isEdgeDoubleTapSettingsPresented = true
                    } label: {
                        Label("边缘双击快捷切换", systemImage: "hand.tap")
                    }
                }

                Section("纸张底色") {
                    Menu {
                        ForEach(CanvasPaperStyle.allCases) { style in
                            Button {
                                model.updatePaperStyle(style)
                            } label: {
                                if model.paperStyle == style {
                                    Label(style.title, systemImage: "checkmark")
                                } else {
                                    Text(style.title)
                                }
                            }
                        }
                    } label: {
                        Label("护眼纸张色（\(model.paperStyle.shortTitle)）", systemImage: "doc.plaintext")
                    }
                }

                Section("插入贴图") {
                    Button {
                        isPhotoPickerRequested = true
                    } label: {
                        Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        isCameraPresented = true
                    } label: {
                        Label("拍照即贴图", systemImage: "camera")
                    }
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                }
                Section("贴图锁定") {
                    Button {
                        model.lockSelectedImages()
                    } label: {
                        Label("锁定选中贴图", systemImage: "lock.fill")
                    }
                    .disabled(!model.isSingleImageSelected)

                    Button {
                        model.unlockAllImages()
                    } label: {
                        Label("解锁全部贴图（\(model.lockedImageCount)）", systemImage: "lock.open.fill")
                    }
                    .disabled(model.lockedImageCount == 0)
                }
                Section("画布") {
                    Button {
                        model.paste()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!model.hasClipboard)

                    Button {
                        model.deleteSelection()
                    } label: {
                        Label("删除选区", systemImage: "trash")
                    }
                    .disabled(model.selectionKind == .none)
                }
                Section("本页") {
                    Button(role: .destructive) {
                        isClearConfirmPresented = true
                    } label: {
                        Label("清空当前页", systemImage: "eraser.line.dashed")
                    }
                    Button(role: .destructive) {
                        isDeletePageConfirmPresented = true
                    } label: {
                        Label("删除当前页", systemImage: "trash.slash")
                    }
                    .disabled(model.pageCount <= 1)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 导入

    private func importPicked(_ item: PhotosPickerItem, model: EditorModel) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        model.importImage(data: data, fileExtension: AppPaths.imageExtension(for: data))
    }

    private func importReplacement(_ item: PhotosPickerItem, model: EditorModel) async {
        defer { replacementItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        model.applyReplacement(data: data, fileExtension: AppPaths.imageExtension(for: data))
    }
}

/// 页面排序面板：使用系统 List + onMove（原生拖动手柄），长按拖动即排序。
private struct PageManagerSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.pages, id: \.uuid) { page in
                    HStack(spacing: 12) {
                        Text("Page \(page.index + 1)")
                            .font(.system(size: 14, weight: page.uuid == model.currentPage?.uuid ? .semibold : .regular))
                        if page.index == 0 {
                            Text("月历封面")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Text("\(page.images.count) 张贴图")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectPage(page.index)
                        dismiss()
                    }
                }
                .onMove { source, destination in
                    model.movePages(from: source, to: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("页面排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("长按拖动可调整顺序；排到第一位的页面将成为月历封面缩略图。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
            }
        }
    }
}

/// 相机 / 相册兜底选择器。
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

// MARK: - 天气与城市选择面板

struct WeatherLocationSheet: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var weatherService = WeatherService.shared
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("当日天气") {
                    let info = weatherService.weather(for: date)
                    HStack(spacing: 14) {
                        Image(systemName: info?.systemSymbol ?? "cloud.sun.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(weatherService.currentLocation.displayName)
                                .font(.headline)
                            if let info {
                                Text("\(info.conditionDescription) · 气温 \(Int(info.tempMin.rounded()))℃ ~ \(Int(info.tempMax.rounded()))℃")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(weatherService.isFetching ? "正在拉取最新天气..." : "暂无缓存天气")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            Task { await weatherService.fetchWeather(for: date) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .disabled(weatherService.isFetching)
                    }
                    .padding(.vertical, 4)
                }

                Section("位置获取方式") {
                    Toggle("自动定位 (系统 GPS)", isOn: $weatherService.useAutoLocation)
                }

                Section("搜索并手动选取城市") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("输入城市名称（如北京、上海、广州）", text: $searchText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                Task { await weatherService.searchCities(query: searchText) }
                            }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if weatherService.isSearching {
                        HStack {
                            Spacer()
                            ProgressView("正在搜索...")
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if !weatherService.searchResults.isEmpty {
                        ForEach(weatherService.searchResults) { loc in
                            Button {
                                weatherService.selectLocation(loc)
                                Task { await weatherService.fetchWeather(for: date) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(loc.name)
                                            .font(.body)
                                        if let admin = loc.admin1, admin != loc.name {
                                            Text(admin)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if weatherService.currentLocation.id == loc.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("天气与地点设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                await weatherService.fetchWeather(for: date)
            }
        }
    }
}
