import Observation
import PencilKit
import SwiftData
import SwiftUI
import UIKit

/// 橡皮模式：整体擦除（整笔） / 范围擦除（擦除范围内部分笔画）。
enum EraserMode: String, CaseIterable, Identifiable {
    case wholeStroke
    case rangeErase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wholeStroke: return "整体擦除"
        case .rangeErase: return "范围擦除"
        }
    }

    var detail: String {
        switch self {
        case .wholeStroke: return "碰到即擦掉整条笔画"
        case .rangeErase: return "只擦掉橡皮范围内的那一部分"
        }
    }

    var symbol: String {
        switch self {
        case .wholeStroke: return "eraser"
        case .rangeErase: return "eraser.line.dashed"
        }
    }

    /// PencilKit 原生对应：.vector = 整笔擦除；.bitmap = 按范围像素级擦除。
    var pencilKitType: PKEraserTool.EraserType {
        switch self {
        case .wholeStroke: return .vector
        case .rangeErase: return .bitmap
        }
    }
}

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

    /// 打开编辑器时的全局默认手指书写值（关闭时回写，避免编辑过程中触发外层重渲染）。
    private(set) var fingerDrawingAtLaunch: Bool = false
    private(set) var selectionKind: CanvasSelectionKind = .none
    private(set) var canUndo = false
    private(set) var canRedo = false
    var hasClipboard = false
    var isCanvasExpanded = false
    /// 是否有触摸落在画纸（可绘画区域）内（由 CanvasHostView 上报）。
    var isPaperTouchActive = false
    /// 是否有选区手势进行中（拖动/裁剪/缩放，由容器上报）。
    var isSelectionGestureActive = false
    var isReplacingImage = false
    var replaceTargetID: UUID?
    var note: String

    /// nil = 导航态（未选中任何工具，只平移缩放）。
    /// 注意：这些属性**不依赖属性观察器**驱动工具下发 ——
    /// 变更请走 `select(tool:)` / `updatePenColor(_:)` 等显式方法（它们会立即下发），
    /// 或依赖 `syncUIKitState` 的幂等签名比较兜底。
    var activeTool: CanvasTool? = .pen
    var penColorHex: String = "#1F6FB2"
    var penWidth: CGFloat = 5
    var eraserMode: EraserMode = .wholeStroke
    /// 橡皮有效范围直径（画布世界坐标）；同时决定 PKEraserTool.width 与指示圈直径。
    var eraserWidth: CGFloat = 26

    weak var canvasHost: CanvasHostView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 已下发的工具指纹：与期望指纹不一致时才重新下发。
    /// 之所以不用「设置-清除标志位」，是因为它依赖属性观察器能否触发；
    /// 幂等比较无论如何都能收敛到正确状态。
    @ObservationIgnored private var appliedToolSignature: String = ""
    @ObservationIgnored private var loadedPageUUID: UUID?

    init(day: DayRecord, workspace: Workspace, context: ModelContext) {
        self.day = day
        self.workspace = workspace
        self.repository = PageRepository(context: context)
        self.note = day.note
        self.pages = day.orderedPages
        self.fingerDrawingAtLaunch = false
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
        host.onPaperTouchChanged = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                if self.isPaperTouchActive != active {
                    self.isPaperTouchActive = active
                }
            }
        }
        host.canvas.onAdjustingSelectionChanged = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                if self.isSelectionGestureActive != active {
                    self.isSelectionGestureActive = active
                }
            }
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
        appliedToolSignature = ""          // 强制首次下发
        syncUIKitState(of: host)
        // 延后到下一轮运行循环：避免在 SwiftUI 视图更新期间修改可观察状态。
        Task { @MainActor [weak self] in
            self?.loadCurrentPage()
        }
    }

    /// 期望状态指纹：工具类型 + 颜色 + 笔宽 + 橡皮模式/大小 + 套索开关。
    private var toolSignature: String {
        let tool = activeTool?.rawValue ?? "none"
        return "\(tool)|\(penColorHex)|\(penWidth)|\(eraserMode.rawValue)|\(eraserWidth)|\(isLassoActive)"
    }

    func syncUIKitState(of host: CanvasHostView?) {
        guard let host else { return }
        if host.canvas.isFingerDrawingEnabled != isFingerDrawingEnabled {
            host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        }
        if host.canvas.isLassoActive != isLassoActive {
            host.canvas.isLassoActive = isLassoActive
        }
        let signature = toolSignature
        if signature != appliedToolSignature {
            appliedToolSignature = signature
            applyTool(on: host)
        }
    }

    /// 立即下发（不等 SwiftUI 更新回合）。
    func applyToolImmediately() {
        syncUIKitState(of: canvasHost)
    }

    private func applyTool(on host: CanvasHostView) {
        let color = UIColor(hex: penColorHex) ?? .label
        guard let activeTool else {
            host.setNavigationMode(true)
            host.canvas.isEraserActive = false
            return
        }
        host.setNavigationMode(false)
        host.canvas.eraserWidth = eraserWidth
        host.canvas.isEraserActive = (activeTool == .eraser)
        switch activeTool {
        case .pen:
            host.setTool(PKInkingTool(.pen, color: color, width: penWidth))
        case .marker:
            host.setTool(PKInkingTool(.marker, color: color.withAlphaComponent(0.45), width: penWidth * 2.4))
        case .pencil:
            host.setTool(PKInkingTool(.pencil, color: color, width: penWidth * 0.9))
        case .eraser:
            // 整体擦除 = PKEraserTool(.vector)；范围擦除 = .bitmap
            host.setTool(PKEraserTool(eraserMode.pencilKitType, width: eraserWidth))
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

    // MARK: - 页面排序（Page 1 即月历封面）

    /// 原生 List.onMove 入口。
    func movePages(from source: IndexSet, to destination: Int) {
        save()
        var ordered = day.orderedPages
        ordered.move(fromOffsets: source, toOffset: destination)
        repository.applyPageOrder(ordered, in: day)
        reloadAfterReorder()
    }

    /// 拖放入口：把某页移动到目标位置。
    func movePage(id: UUID, toIndex index: Int) {
        var ordered = day.orderedPages
        guard let from = ordered.firstIndex(where: { $0.uuid == id }) else { return }
        let clamped = max(0, min(index, ordered.count - 1))
        guard from != clamped else { return }
        save()
        let page = ordered.remove(at: from)
        ordered.insert(page, at: min(clamped, ordered.count))
        repository.applyPageOrder(ordered, in: day)
        reloadAfterReorder()
    }

    private func reloadAfterReorder() {
        let currentUUID = currentPage?.uuid
        pages = day.orderedPages
        if let currentUUID, let index = pages.firstIndex(where: { $0.uuid == currentUUID }) {
            pageIndex = index
        } else {
            pageIndex = min(pageIndex, max(0, pages.count - 1))
        }
        loadCurrentPage()
        // 新的 Page 1 成为月历封面：立即重算它的缩略图。
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

    /// 选区动作统一入口（浮动菜单与底部工具条共用）。
    func performSelectionAction(_ action: SelectionAction) {
        canvasHost?.canvas.perform(action)
    }

    /// 笔刷 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥；再次点按当前工具即取消它（进入导航态）。
    func select(tool: CanvasTool) {
        if isLassoActive {
            isLassoActive = false
        }
        activeTool = (activeTool == tool) ? nil : tool
        applyToolImmediately()
    }

    /// 墨色
    func updatePenColor(_ hex: String) {
        penColorHex = hex
        applyToolImmediately()
    }

    /// 笔宽
    func updatePenWidth(_ width: CGFloat) {
        penWidth = width
        applyToolImmediately()
    }

    /// 橡皮模式（整体擦除 / 范围擦除）
    func updateEraserMode(_ mode: EraserMode) {
        eraserMode = mode
        applyToolImmediately()
    }

    /// 橡皮有效范围
    func updateEraserWidth(_ width: CGFloat) {
        eraserWidth = width
        applyToolImmediately()
    }

    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { activeTool == nil }

    /// 是否应锁住「交互式下拉返回」。
    /// 命中条件：① 落笔在画纸（可绘画区域）内；② 或贴图/选区手势正在继续
    /// —— 后者覆盖"贴图被拖到画纸之外仍在编辑"的例外情况。
    /// 页条 / 工具栏 / 画布留白处不满足任一条件 → 照常可下拉返回主页面。
    var isCanvasInteractionActive: Bool {
        isPaperTouchActive || isSelectionGestureActive
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
