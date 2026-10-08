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
    case monoline
    case marker
    case pencil
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .monoline: return "自动铅笔"
        case .marker: return "马克笔"
        case .pencil: return "铅笔"
        case .eraser: return "橡皮"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .monoline: return "pencil.line"
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
    /// 墨色出厂默认值（黑色，看齐 iOS 备忘录首选）。
    nonisolated static let defaultPenColor = "#000000"

    nonisolated static func defaultColor(for tool: CanvasTool) -> String {
        switch tool {
        case .marker: return "#FFCC00"
        default: return defaultPenColor
        }
    }

    nonisolated static func defaultWidth(for tool: CanvasTool) -> CGFloat {
        switch tool {
        case .pen: return 5
        case .monoline: return 3
        case .marker: return 16
        case .pencil: return 5
        case .eraser: return 26
        }
    }

    let day: DayRecord
    let workspace: Workspace
    let repository: PageRepository

    /// 工具栏偏好（墨色 / 笔宽 / 橡皮模式 / 橡皮大小）的持久化归宿。
    private let settings = ToolSettingsStore()

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
    /// 当前页面已锁定的贴图数量（供「解锁全部贴图」菜单项显示与可用性）。
    var lockedImageCount = 0
    /// 下拉返回主页面（画纸留白处 / 顶部标签行触发）。
    var onRequestDismiss: (() -> Void)?
    /// Pencil 硬件交互请求切换/展开调色盘。
    var onRequestToggleColorPicker: (() -> Void)?
    var isReplacingImage = false
    var replaceTargetID: UUID?
    var note: String

    // 二次编辑状态
    var editingItemID: UUID?
    var editingItemPayload: CanvasItemPayload?
    var editingTextConfig: TextItemConfig?
    var isEditingText: Bool = false
    var editingShapeConfig: ShapeItemConfig?
    var isEditingShape: Bool = false

    /// nil = 导航态（未选中任何工具，只平移缩放）。
    /// 注意：这些属性**不依赖属性观察器**驱动工具下发 ——
    /// 变更请走 `select(tool:)` / `updatePenColor(_:)` 等显式方法（它们会立即下发），
    /// 或依赖 `syncUIKitState` 的幂等签名比较兜底。
    var activeTool: CanvasTool? = .pen
    /// **当前这支笔**的墨色（界面取色圆点、画布笔色都取它）。
    /// 每支笔在 `ToolSettingsStore` 里有自己的槽位，切笔时由 `adoptPenColor(for:)` 换上来。
    var penColorHex: String = EditorModel.defaultPenColor
    /// 墨色当前归属哪支笔：橡皮与导航态都不改变它 ——
    /// 这样"橡皮 → 取色"仍然改的是上一支笔，语义上更符合直觉。
    private(set) var currentInkTool: CanvasTool = .pen
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
        restoreToolSettings()
    }

    /// 从 `ToolSettingsStore` 恢复上次的工具栏偏好。
    ///
    /// 放在 `init` 而不是 `attach(host:)`：恢复只改模型状态，
    /// 真正的工具下发由 `attach` 里的 `appliedToolSignature = ""` 强制完成一次。
    private func restoreToolSettings() {
        currentInkTool = .pen
        adoptPenSettings(for: currentInkTool)
        if let mode = settings.eraserMode { eraserMode = mode }
        if let width = settings.eraserWidth { eraserWidth = CGFloat(width) }
    }

    /// 换上台面指定笔自己的墨色与笔宽（每支笔独立记忆）。
    private func adoptPenSettings(for tool: CanvasTool) {
        guard tool != .eraser else { return }
        currentInkTool = tool
        let hex = settings.penColor(for: tool) ?? Self.defaultColor(for: tool)
        if penColorHex != hex { penColorHex = hex }
        let width = settings.penWidth(for: tool) ?? Double(Self.defaultWidth(for: tool))
        penWidth = CGFloat(width)
    }

    var currentPage: DrawingPage? {
        guard pageIndex >= 0, pageIndex < pages.count else { return pages.first }
        return pages[pageIndex]
    }

    var pageCount: Int { pages.count }

    var date: Date { day.date ?? Date() }

    var title: String { CalendarUtils.dayTitle(date) }

    /// 包含当日天气的标题：{日期} 天气{晴/多云/暴雨等} 气温{min}~{max}摄氏度
    var titleWithWeather: String { WeatherService.shared.fullTitle(for: date) }

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
        host.canvas.onRequestItemEdit = { [weak self] id, payload in
            guard let self else { return }
            self.editingItemID = id
            self.editingItemPayload = payload
            switch payload {
            case .text(let config):
                self.editingTextConfig = config
                self.isEditingText = true
            case .shape(let config):
                self.editingShapeConfig = config
                self.isEditingShape = true
            }
        }
        host.onRequestDismiss = { [weak self] in
            self?.onRequestDismiss?()
        }
        host.canvas.onLockedCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self else { return }
                if self.lockedImageCount != count {
                    self.lockedImageCount = count
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
        host.onPencilSwitchTool = { [weak self] in
            guard let self else { return }
            if self.activeTool == .eraser {
                self.select(tool: self.currentInkTool)
            } else {
                self.select(tool: .eraser)
            }
        }
        host.onPencilShowPalette = { [weak self] in
            self?.onRequestToggleColorPicker?()
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
        case .monoline:
            host.setTool(PKInkingTool(.monoline, color: color, width: penWidth))
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
        refreshThumbnails(for: page)
    }

    /// 内容已落盘后重算缩略图。
    ///
    /// 两个关键点：
    ///
    /// 1. **清空也算内容变更**。旧实现里合成函数遇到「无笔迹且无贴图」直接返回 nil，
    ///    于是旧 PNG 原封不动地留在磁盘上 —— 清空当前页后月历上挂着清空前的缩略图，
    ///    内容与图不符。现在 `ThumbnailRenderer` 会区分「确认为空」与「读不到」，
    ///    「确认为空」走 `ThumbnailLoadPolicy.clear`：删磁盘 PNG、收走缓存条目、推进代次。
    /// 2. **封面判定问模型，不复述规则**。旧写法是 `page.index == 0` —— 而「谁是封面」
    ///    是由 `applyPageOrder` / `reindex` / `syncPageCount` 共同维持的不变量，
    ///    在这里重写一遍它迟早会对不上（重排后就对不上）。直接问 `day.coverPage`。
    private func refreshThumbnails(for page: DrawingPage) {
        let isCover = day.coverPage?.uuid == page.uuid
        Task {
            if isCover { await ThumbnailStore.shared.regenerate(page.coverSlot, page: page) }
            // 抽屉里的单页预览永远跟着刷新（它按页 uuid 独立缓存）。
            await ThumbnailStore.shared.regenerate(page.pageSlot, page: page)
        }
    }

    func finishEditing() {
        flushPendingSave()
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
            Task { await ThumbnailStore.shared.regenerate(cover.coverSlot, page: cover) }
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
            Task { await ThumbnailStore.shared.regenerate(cover.coverSlot, page: cover) }
        }
    }

    // MARK: - 贴图导入与二次编辑

    func importImage(data: Data, fileExtension: String, payload: CanvasItemPayload? = nil) {
        guard let host = canvasHost, let image = UIImage(data: data) else { return }
        let fileName = repository.storeAsset(data: data, preferredExtension: fileExtension)
        host.canvas.addImage(image, fileName: fileName, payload: payload)
        markDirty()
    }

    func updateEditedItem(id: UUID, data: Data, payload: CanvasItemPayload) {
        guard let host = canvasHost, let image = UIImage(data: data) else { return }
        host.canvas.updateImageItem(id: id, image: image, payload: payload)
        editingItemID = nil
        editingItemPayload = nil
        isEditingText = false
        isEditingShape = false
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
        // 撤销是「已定型」的动作，不是输入中的中间态：不能走 2s 去抖。
        // 否则在存盘前退出/崩溃，磁盘上留着的还是被撤销掉的内容，
        // 重新打开又看到它 —— 而且分不清是“没撤销”还是“撤销没落盘”。
        flushPendingSave()
    }

    func redo() {
        canvasHost?.canvas.redo()
        flushPendingSave()
    }

    /// 立即落盘，并撤掉还在去抖中的那次写盘（否则 2s 后会重复写一遍同样的内容）。
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    func clearPage() {
        canvasHost?.canvas.clearAll()
        // 「用户把这一页清空了」是不需要离线合成就能下结论的事实，所以立刻收图：
        // 旧缩略图当场从月历与抽屉消失，不必等 `markDirty()` 那个 2 秒防抖 +
        // 一遍后台 PNG 合成。随后的 `save()` 会得出同样的 `.empty` 结论，幂等。
        if let page = currentPage {
            ThumbnailStore.shared.forget(page.pageSlot, fileName: page.thumbnailFileName)
            if day.coverPage?.uuid == page.uuid {
                ThumbnailStore.shared.forget(page.coverSlot, fileName: page.thumbnailFileName)
            }
        }
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

    /// 笔刷 / 自动铅笔 / 马克笔 / 铅笔 / 橡皮 —— 与套索互斥；再次点按当前工具即取消它（进入导航态）。
    /// 同时把目标笔的专属墨色与笔宽换上台面。
    func select(tool: CanvasTool) {
        if isLassoActive {
            isLassoActive = false
        }
        // 是否"取消选中"看当前工具，换墨色/笔宽看目标工具 —— 两者语义不同，别混用。
        let next: CanvasTool? = (activeTool == tool) ? nil : tool
        adoptPenSettings(for: tool)
        activeTool = next
        applyToolImmediately()
    }

    /// 墨色 —— 存入**当前这支笔**的槽位（每支笔独立记忆）。
    func updatePenColor(_ hex: String) {
        guard let normalized = ToolSettingsStore.normalizedHex(hex) else { return }
        penColorHex = normalized
        settings.setPenColor(normalized, for: currentInkTool)
        applyToolImmediately()
    }

    /// 笔宽 —— 存入**当前这支笔**的槽位（每支笔独立记忆）。
    func updatePenWidth(_ width: CGFloat) {
        penWidth = width
        settings.setPenWidth(Double(width), for: currentInkTool)
        applyToolImmediately()
    }

    /// 橡皮模式（整体擦除 / 范围擦除）
    func updateEraserMode(_ mode: EraserMode) {
        eraserMode = mode
        settings.eraserMode = mode
        applyToolImmediately()
    }

    /// 橡皮有效范围
    func updateEraserWidth(_ width: CGFloat) {
        eraserWidth = width
        settings.eraserWidth = Double(width)
        applyToolImmediately()
    }

    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { activeTool == nil }

    /// 是否选中了单张贴图（用于「锁定选中贴图」菜单项）。
    var isSingleImageSelected: Bool {
        if case .image = selectionKind { return true }
        return false
    }

    /// 锁定当前选中的贴图。
    func lockSelectedImages() {
        canvasHost?.canvas.lockSelectedImages()
    }

    /// 解锁本页全部贴图。
    func unlockAllImages() {
        canvasHost?.canvas.unlockAllImages()
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
        let page = pages[index]
        // 装载可能当场合成（缓冲区外的那一页），给足够的时间预算再回读缓存。
        await ThumbnailStore.shared.load(page.pageSlot, page: page)
        return ThumbnailStore.shared.image(page.pageSlot)
    }
}
