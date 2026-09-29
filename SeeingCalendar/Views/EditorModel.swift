import Observation
import PencilKit
import SwiftData
import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable, Identifiable {
    case pen
    case marker
    case pencil
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .marker: return "马克笔"
        case .pencil: return "铅笔"
        case .eraser: return "橡皮"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        }
    }
}

/// 单日编辑器状态机：页面装载 / 自动保存 / 工具与选区同步。
@MainActor
@Observable
final class EditorModel {
    let day: DayRecord
    let workspace: Workspace
    let repository: PageRepository

    private(set) var pages: [DrawingPage] = []
    private(set) var pageIndex: Int = 0

    var isFingerDrawingEnabled: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }
    var isLassoActive: Bool = false {
        didSet { syncUIKitState(of: canvasHost) }
    }
    private(set) var selectionKind: CanvasSelectionKind = .none
    private(set) var canUndo = false
    private(set) var canRedo = false
    var hasClipboard = false
    var isCanvasExpanded = false
    var isReplacingImage = false
    var replaceTargetID: UUID?
    var note: String

    var activeTool: CanvasTool = .pen {
        didSet { toolNeedsApply = true }
    }
    var penColorHex: String = "#1F6FB2" {
        didSet { toolNeedsApply = true }
    }
    var penWidth: CGFloat = 5 {
        didSet { toolNeedsApply = true }
    }

    weak var canvasHost: CanvasHostView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toolNeedsApply = true
    @ObservationIgnored private var loadedPageUUID: UUID?

    init(day: DayRecord, workspace: Workspace, context: ModelContext) {
        self.day = day
        self.workspace = workspace
        self.repository = PageRepository(context: context)
        self.note = day.note
        self.pages = day.orderedPages
    }

    var currentPage: DrawingPage? {
        guard pageIndex >= 0, pageIndex < pages.count else { return pages.first }
        return pages[pageIndex]
    }

    var pageCount: Int { pages.count }

    var date: Date { day.date ?? Date() }

    var title: String { CalendarUtils.dayTitle(date) }

    // MARK: - 桥接

    func attach(host: CanvasHostView) {
        canvasHost = host
        host.canvas.onContentChange = { [weak self] in
            self?.markDirty()
        }
        host.canvas.onSelectionChange = { [weak self] kind in
            guard let self else { return }
            self.selectionKind = kind
            self.hasClipboard = self.canvasHost?.canvas.hasClipboardContent ?? false
        }
        host.canvas.onHistoryChange = { [weak self] undo, redo in
            self?.canUndo = undo
            self?.canRedo = redo
        }
        host.canvas.onRequestImageReplace = { [weak self] id in
            guard let self else { return }
            self.replaceTargetID = id
            self.isReplacingImage = true
        }
        host.onZoomChange = { [weak self] scale, fit in
            // 首帧布局期间 UIKit 仍处于 SwiftUI 的更新回合内，延后一拍回写状态。
            Task { @MainActor in
                guard let self else { return }
                let expanded = fit > 0 && scale > fit * 1.05
                if self.isCanvasExpanded != expanded {
                    self.isCanvasExpanded = expanded
                }
            }
        }
        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.isLassoActive = isLassoActive
        toolNeedsApply = true
        // 延后到下一轮运行循环：避免在 SwiftUI 视图更新期间修改可观察状态。
        Task { @MainActor [weak self] in
            self?.loadCurrentPage()
        }
    }

    func syncUIKitState(of host: CanvasHostView?) {
        guard let host else { return }
        if host.canvas.isFingerDrawingEnabled != isFingerDrawingEnabled {
            host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        }
        if host.canvas.isLassoActive != isLassoActive {
            host.canvas.isLassoActive = isLassoActive
        }
        if toolNeedsApply {
            toolNeedsApply = false
            applyTool(on: host)
        }
    }

    private func applyTool(on host: CanvasHostView) {
        let color = UIColor(hex: penColorHex) ?? .label
        switch activeTool {
        case .pen:
            host.setTool(PKInkingTool(.pen, color: color, width: penWidth))
        case .marker:
            host.setTool(PKInkingTool(.marker, color: color.withAlphaComponent(0.45), width: penWidth * 2.4))
        case .pencil:
            host.setTool(PKInkingTool(.pencil, color: color, width: penWidth * 0.9))
        case .eraser:
            host.setTool(PKEraserTool(.vector))
        }
    }

    // MARK: - 页面装载与保存

    func loadCurrentPage() {
        guard let host = canvasHost else { return }
        pages = day.orderedPages
        if pages.isEmpty {
            repository.ensureCoverPage(for: day)
            pages = day.orderedPages
        }
        if pageIndex >= pages.count { pageIndex = max(0, pages.count - 1) }
        guard let page = currentPage else { return }
        let drawing = repository.loadDrawing(for: page)
        let items = repository.loadImageItems(for: page)
        host.canvas.load(drawing: drawing, items: items)
        loadedPageUUID = page.uuid
    }

    func markDirty() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let host = canvasHost, let page = currentPage else { return }
        let snapshot = host.canvas.snapshot()
        repository.writeDrawing(snapshot.drawing, for: page)
        repository.saveImageItems(snapshot.items, for: page)
        day.updatedAt = .now
        if page.index == 0 {
            Task { await ThumbnailStore.shared.regenerate(page: page) }
        }
    }

    func finishEditing() {
        saveTask?.cancel()
        saveTask = nil
        save()
        repository.cleanupOrphanAssets()
    }

    // MARK: - 页面操作

    func selectPage(_ index: Int) {
        guard index != pageIndex, index >= 0, index < pages.count else { return }
        save()
        pageIndex = index
        loadCurrentPage()
    }

    /// 打开编辑器时定位到指定页（在 attach 之前调用）。
    func setInitialPage(_ index: Int) {
        pages = day.orderedPages
        guard index >= 0, index < pages.count else { return }
        pageIndex = index
    }

    func addPage() {
        save()
        let page = repository.addPage(to: day)
        pages = day.orderedPages
        pageIndex = pages.firstIndex { $0.uuid == page.uuid } ?? pages.count - 1
        loadCurrentPage()
    }

    func deleteCurrentPage() {
        guard pages.count > 1, let page = currentPage else { return }
        saveTask?.cancel()
        repository.deletePage(page)
        pages = day.orderedPages
        pageIndex = min(pageIndex, max(0, pages.count - 1))
        loadCurrentPage()
        if let cover = pages.first {
            Task { await ThumbnailStore.shared.regenerate(page: cover) }
        }
    }

    // MARK: - 贴图导入

    func importImage(data: Data, fileExtension: String) {
        guard let host = canvasHost, let image = UIImage(data: data) else { return }
        let fileName = repository.storeAsset(data: data, preferredExtension: fileExtension)
        host.canvas.addImage(image, fileName: fileName)
        markDirty()
    }

    func importImage(fromURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        importImage(data: data, fileExtension: AppPaths.fileExtension(of: url))
    }

    func applyReplacement(data: Data, fileExtension: String) {
        guard let host = canvasHost, let id = replaceTargetID, let image = UIImage(data: data) else { return }
        let fileName = repository.storeAsset(data: data, preferredExtension: fileExtension)
        host.canvas.replaceImage(id: id, image: image, fileName: fileName)
        replaceTargetID = nil
        isReplacingImage = false
        markDirty()
    }

    func applyReplacement(fromURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        applyReplacement(data: data, fileExtension: AppPaths.fileExtension(of: url))
    }

    // MARK: - 画布指令

    func undo() {
        canvasHost?.canvas.undo()
    }

    func redo() {
        canvasHost?.canvas.redo()
    }

    func clearPage() {
        canvasHost?.canvas.clearAll()
        markDirty()
    }

    func deleteSelection() {
        canvasHost?.canvas.deleteSelection()
    }

    func copySelection() {
        canvasHost?.canvas.copySelectionToClipboard()
        hasClipboard = canvasHost?.canvas.hasClipboardContent ?? false
    }

    func cutSelection() {
        canvasHost?.canvas.copySelectionToClipboard()
        canvasHost?.canvas.deleteSelection()
        hasClipboard = canvasHost?.canvas.hasClipboardContent ?? false
    }

    func paste() {
        canvasHost?.canvas.pasteClipboard()
    }

    func zoomToFit() {
        canvasHost?.zoomToFit(animated: true)
    }

    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥。
    func select(tool: CanvasTool) {
        activeTool = tool
        if isLassoActive {
            isLassoActive = false
        }
    }

    /// 套索 —— 与笔墨工具互斥。
    func toggleLasso() {
        isLassoActive.toggle()
    }

    /// 「最大化 / 缩小」画布视口。
    func toggleCanvasZoom() {
        canvasHost?.toggleExpanded(animated: true)
    }

    func updateNote(_ text: String) {
        note = text
        repository.updateNote(text, for: day)
    }

    func thumbnail(forPageAt index: Int) async -> UIImage? {
        guard index >= 0, index < pages.count else { return nil }
        return await ThumbnailStore.shared.thumbnail(for: pages[index])
    }
}
