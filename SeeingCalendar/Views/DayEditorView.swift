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
    @State private var model: EditorModel?
    @State private var photoItem: PhotosPickerItem?
    @State private var replacementItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var isClearConfirmPresented = false
    @State private var isDeletePageConfirmPresented = false
    @State private var isColorPickerPresented = false

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if model == nil {
                let created = EditorModel(day: day, workspace: workspace, context: context)
                created.setInitialPage(initialPageIndex)
                created.isFingerDrawingEnabled = isFingerDrawingEnabled
                model = created
            }
        }
    }

    // MARK: - 主体

    private func content(model: EditorModel) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                pageStrip(model: model)
                Divider()
                CanvasRepresentable(model: model)
                    .overlay(alignment: .top) { hintBanner(model: model) }
                Divider()
                toolBar(model: model)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent(model: model) }
            .onChange(of: model.isFingerDrawingEnabled) { _, newValue in
                onFingerDrawingChanged(newValue)
            }
            .onDisappear { model.finishEditing() }
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

    @State private var isPhotoPickerRequested = false

    // MARK: - 页面条

    private func pageStrip(model: EditorModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.pages.enumerated()), id: \.element.uuid) { index, page in
                    Button {
                        model.selectPage(index)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Page \(index + 1)")
                                .font(.system(size: 12, weight: model.pageIndex == index ? .semibold : .regular))
                            if index == 0 {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 9))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(model.pageIndex == index
                                           ? Color.accentColor.opacity(0.18)
                                           : Color(uiColor: .secondarySystemBackground))
                        )
                        .overlay(
                            Capsule().strokeBorder(model.pageIndex == index ? Color.accentColor : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(page.index == 0 ? "月历封面页" : "第 \(index + 1) 页")
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 提示条

    @ViewBuilder
    private func hintBanner(model: EditorModel) -> some View {
        if model.selectionKind != .none {
            Text(hintText(for: model.selectionKind))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
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
        HStack(spacing: 14) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)

            Divider().frame(height: 22)

            ForEach(CanvasTool.allCases) { tool in
                Button {
                    model.select(tool: tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(model.activeTool == tool && !model.isLassoActive
                                      ? Color.accentColor.opacity(0.18)
                                      : .clear)
                        )
                }
                .accessibilityLabel(tool.title + "（再次点按可取消）")
            }

            Button {
                isColorPickerPresented.toggle()
            } label: {
                Circle()
                    .fill(Color(hex: model.penColorHex, fallback: .blue))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            }
            .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                penSettings(model: model)
            }

            Divider().frame(height: 22)

            Button {
                model.toggleLasso()
            } label: {
                Image(systemName: "lasso")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isLassoActive ? Color.accentColor.opacity(0.20) : .clear)
                    )
            }
            .accessibilityLabel("统一套索")

            Button {
                model.isFingerDrawingEnabled.toggle()
            } label: {
                Image(systemName: model.isFingerDrawingEnabled ? "hand.draw.fill" : "hand.draw")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isFingerDrawingEnabled ? Color.accentColor.opacity(0.20) : .clear)
                    )
            }
            .accessibilityLabel("手指书写开关")

            Spacer(minLength: 0)

            if model.isLassoActive {
                Text("套索")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else if model.isNavigating {
                Text("导航")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                model.toggleCanvasZoom()
            } label: {
                Image(systemName: model.isCanvasExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isCanvasExpanded ? Color.accentColor.opacity(0.18) : .clear)
                    )
            }
            .accessibilityLabel(model.isCanvasExpanded ? "缩小画布" : "最大化画布")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private func penSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("墨色").font(.headline)
            HStack(spacing: 10) {
                ForEach(SubscriptionPalette.colors, id: \.self) { hex in
                    Button {
                        model.penColorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(model.penColorHex == hex ? Color.primary : .clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("笔宽 \(Int(model.penWidth))")
                .font(.subheadline)
            Slider(value: Binding(get: { model.penWidth }, set: { model.penWidth = $0 }), in: 1...28, step: 1)
                .frame(width: 240)
        }
        .padding(16)
    }

    @ToolbarContentBuilder
    private func toolbarContent(model: EditorModel) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") {
                model.finishEditing()
                dismiss()
            }
            .fontWeight(.semibold)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
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
