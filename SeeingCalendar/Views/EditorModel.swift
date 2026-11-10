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

    nonisolated static func widthPresets(for tool: CanvasTool) -> [CGFloat] {
        switch tool {
        case .monoline:
            return [1, 2, 3, 5, 8]
        case .pen:
            return [1, 3, 6, 12, 20]
        case .pencil:
            return [2, 5, 9, 16, 24]
        case .marker:
            return [6, 12, 18, 24, 28]
        case .eraser:
            return [12, 24, 48, 80]
        }
    }

    var currentWidthPresets: [CGFloat] {
        Self.widthPresets(for: activeTool ?? .pen)
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
    var toastMessage: String?

    // 二次编辑状态：`editSession` 是唯一真值，下列投影全部从它派生
    // （payload 单独就能判别编辑态种类与配置，其余只是镜像）。
    var editSession: CanvasEditSession = .none

    /// 二次编辑目标图元 id（派生投影，真值在 `editSession`）。
    var editingItemID: UUID? { editSession.itemID }
    /// 二次编辑载荷（派生投影，真值在 `editSession`）。
    var editingItemPayload: CanvasItemPayload? { editSession.payload }
    /// 文本配置（派生投影，真值在 `editSession`）。
    var editingTextConfig: TextItemConfig? { editSession.textConfig }
    /// 形状配置（派生投影，真值在 `editSession`）。
    var editingShapeConfig: ShapeItemConfig? { editSession.shapeConfig }

    /// 是否正在编辑文本。
    ///
    /// **可写**是为了兼容 `DayEditorView` 的 `Binding<Bool>` setter：用户下滑关闭
    /// 表单时 SwiftUI 会把 binding 置 `false`，此时收敛到 `.none`。置 `true`
    /// **不改动** —— 编辑态的真值来源是 payload，而不是这个布尔镜像。
    var isEditingText: Bool {
        get { editSession.isEditingText }
        set { if !newValue { editSession = .none } }
    }

    /// 是否正在编辑形状（setter 语义与 `isEditingText` 相同：置 false 收敛，置 true 不改）。
    var isEditingShape: Bool {
        get { editSession.isEditingShape }
        set { if !newValue { editSession = .none } }
    }

    /// 画布输入模式的**单一真值**：7 个互斥状态（导航 / 4 种笔 / 橡皮 / 套索）。
    ///
    /// 旧实现用 `activeTool` × `isLassoActive` 两个独立字段编码这 7 态，合法组合没有任何
    /// 类型约束；现在两者都降级为**只读计算投影**，`inputMode` 才是唯一可写真值。
    /// 变更请走 `select(tool:)` / `toggleLasso()` / `switchTo(target:)` 等显式方法 —— 它们统一
    /// 走「构造转移 → 应用 → 持久化 → 下发」的单一管线，**不依赖属性观察器**驱动副作用
    /// （见 `scripts/verify_observation_semantics.swift`：@Observable 可能丢弃 didSet）。
    var inputMode: CanvasInputMode = .ink(.pen)

    /// 旧 `activeTool` 的**只读投影**：导航 / 套索态为 nil，橡皮为 `.eraser`，笔为其自身。
    var activeTool: CanvasTool? { inputMode.tool }
    /// 旧 `isLassoActive` 的**只读投影**。
    var isLassoActive: Bool { inputMode.isLassoActive }
    /// **当前这支笔**的墨色（界面取色圆点、画布笔色都取它）。
    /// 每支笔在 `ToolSettingsStore` 里有自己的槽位，切笔时由 `adoptPenColor(for:)` 换上来。
    var penColorHex: String = EditorModel.defaultPenColor
    /// 墨色当前归属哪支笔：橡皮与导航态都不改变它 ——
    /// 这样"橡皮 → 取色"仍然改的是上一支笔，语义上更符合直觉。
    private(set) var currentInkTool: CanvasTool = .pen
    var penWidth: CGFloat = 5
    /// 墨水透明度（0.1...1.0，每支笔独立记忆）
    var penOpacity: Double = 1.0
    var eraserMode: EraserMode = .wholeStroke
    /// 橡皮有效范围直径（画布世界坐标）；同时决定 PKEraserTool.width 与指示圈直径。
    var eraserWidth: CGFloat = 26
    /// 画布纸张底色（默认纯白，支持切换复古和纸色 `#FBF9F5` 等护眼底色并持久化）。
    var paperStyle: CanvasPaperStyle = .pureWhite

    // 边缘双击快捷切换
    var edgeDoubleTapSettings: EdgeDoubleTapSettings = EdgeDoubleTapSettings()
    var previousToolType: EdgeSwitchTargetTool = .eraser
    private var savedToolBeforeDesignated: EdgeSwitchTargetTool = .pen

    /// 当前模式对应的边缘切换目标类型（导航 / 套索 / 各工具）。
    var currentActiveToolType: EdgeSwitchTargetTool {
        CanvasInputModePolicy.edgeTarget(of: inputMode)
    }

    weak var canvasHost: CanvasHostView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 自动保存相位（唯一真值）：「脏」由相位表达，不再隐式藏在 `saveTask != nil` 里。
    /// 转移一律走显式方法（`markDirty` / `save` / `flushPendingSave`），
    /// 不得依赖属性观察器 —— 见 `scripts/verify_observation_semantics.swift` 的结论。
    @ObservationIgnored private(set) var savePhase: SavePhase = .clean
    /// 已下发的工具指纹：`syncUIKitState` 在**下发之后**写入，是唯一的写点。
    ///
    /// 为什么保留存储属性、而不降级为 `CanvasInputModePolicy.signature(of: inputMode)` 的纯计算式：
    /// 指纹的语义是「**已下发的是什么**」，不是「现在是什么」。`updatePenColor(_:)` /
    /// `updatePenWidth(_:)` / `updatePenOpacity(_:)` / `updateEraserMode(_:)` 等只改**载荷**
    /// （颜色 / 笔宽 / 橡皮配置）、不改模式，它们的重新下发完全依赖「已下发指纹 ≠ 期望指纹」
    /// 这条比较 —— 若把它变成随 `inputMode` 纯计算的式子，则只要模式没变，比较恒为假，
    /// 改颜色/笔宽就再也下不去。（改成「模式 + 载荷」的纯计算式也无解：那样任何一次 sync
    /// 都会判定不相等而不停重复下发。）因此保留存储副本，但把**期望值**里的模式部分
    /// 改为由 `inputMode` 计算得出（见 `toolSignature`）。
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
    ///
    /// **迁移策略（M1 第二份副本）**：新键 `editorTool.inputMode` 缺失时，用旧键
    /// `lastSelectedTool` / `lastIsLassoActive` 合成模式，随后写回新键 —— 一次性迁移。
    /// 旧键**只读、不删除**：万一回滚到旧版本，它仍能读到（可能略旧）的值而不崩。
    private func restoreToolSettings() {
        let mode = settings.inputMode ?? Self.migratedInputMode(from: settings)
        if settings.inputMode == nil {
            settings.inputMode = mode      // 写回新键（一次性迁移）
        }
        // 当前台面笔：模式本身就带笔时取它，否则取旧键里最后一次选过的笔（导航/套索态）。
        let savedTool = settings.lastSelectedTool ?? .pen
        let seed = mode.tool ?? savedTool
        currentInkTool = (seed == .eraser) ? .pen : seed
        adoptPenSettings(for: currentInkTool)
        if let savedEraserMode = settings.eraserMode { eraserMode = savedEraserMode }
        if let savedEraserWidth = settings.eraserWidth { eraserWidth = CGFloat(savedEraserWidth) }
        paperStyle = settings.paperStyle
        edgeDoubleTapSettings = settings.edgeDoubleTapSettings
        inputMode = mode
    }

    /// 旧键 → 模式的一次性迁移（逐位等价旧 `restoreToolSettings` 的合成规则）。
    private static func migratedInputMode(from settings: ToolSettingsStore) -> CanvasInputMode {
        if settings.lastIsLassoActive { return .lasso }
        let tool = settings.lastSelectedTool ?? .pen
        return tool == .eraser ? .eraser : .ink(tool)
    }

    /// 换上台面指定笔自己的墨色与笔宽（每支笔独立记忆）。
    private func adoptPenSettings(for tool: CanvasTool) {
        guard tool != .eraser else { return }
        currentInkTool = tool
        let hex = settings.penColor(for: tool) ?? Self.defaultColor(for: tool)
        if penColorHex != hex { penColorHex = hex }
        let width = settings.penWidth(for: tool) ?? Double(Self.defaultWidth(for: tool))
        penWidth = CGFloat(width)
        let opacity = settings.penOpacity(for: tool) ?? 1.0
        penOpacity = opacity
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
            // 唯一入口：payload 决定会话种类与配置，不再手工同步 6 个平行字段。
            self.editSession = CanvasEditSession.session(id: id, payload: payload)
        }
        host.canvas.onSaveItemAsSticker = { [weak self] entity in
            self?.saveEntityAsCustomSticker(entity)
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
        host.onEdgeDoubleTap = { [weak self] side in
            self?.handleEdgeDoubleTap(side: side)
        }
        host.isLeftEdgeEnabled = edgeDoubleTapSettings.left.isEnabled
        host.isRightEdgeEnabled = edgeDoubleTapSettings.right.isEnabled
        host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        host.canvas.inputMode = inputMode
        host.canvas.isLassoActive = isLassoActive
        host.canvas.paperStyle = paperStyle
        appliedToolSignature = ""          // 强制首次下发
        syncUIKitState(of: host)
        // 延后到下一轮运行循环：避免在 SwiftUI 视图更新期间修改可观察状态。
        Task { @MainActor [weak self] in
            self?.loadCurrentPage()
        }
    }

    /// 期望状态指纹：**输入模式签名** + 工具载荷（颜色 / 透明度 / 笔宽 / 橡皮配置）。
    ///
    /// 模式部分由 `CanvasInputModePolicy.signature(of:)` 纯计算得出（7 态各不相同），
    /// 不再是两个独立字段的字符串拼接；载荷部分仍需要，因为 `updatePenColor(_:)` 等
    /// 只改载荷、不改模式，却必须触发重新下发。
    private var toolSignature: String {
        "\(CanvasInputModePolicy.signature(of: inputMode))|\(penColorHex)|\(penOpacity)|\(penWidth)|\(eraserMode.rawValue)|\(eraserWidth)"
    }

    func syncUIKitState(of host: CanvasHostView?) {
        guard let host else { return }
        if host.isLeftEdgeEnabled != edgeDoubleTapSettings.left.isEnabled {
            host.isLeftEdgeEnabled = edgeDoubleTapSettings.left.isEnabled
        }
        if host.isRightEdgeEnabled != edgeDoubleTapSettings.right.isEnabled {
            host.isRightEdgeEnabled = edgeDoubleTapSettings.right.isEnabled
        }
        if host.canvas.isFingerDrawingEnabled != isFingerDrawingEnabled {
            host.canvas.isFingerDrawingEnabled = isFingerDrawingEnabled
        }
        if host.canvas.inputMode != inputMode {
            host.canvas.inputMode = inputMode
        }
        if host.canvas.isLassoActive != isLassoActive {
            host.canvas.isLassoActive = isLassoActive
        }
        if host.canvas.paperStyle != paperStyle {
            host.canvas.paperStyle = paperStyle
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
        let baseColor = UIColor(hex: penColorHex) ?? .label
        let color = baseColor.withAlphaComponent(CGFloat(penOpacity))
        // 导航态：禁止落笔、单指平移（逐位等价旧 `guard let activeTool` 的 setNavigationMode(true) 分支）。
        guard inputMode.drawsWithFinger else {
            host.setNavigationMode(true)
            host.canvas.isEraserActive = false
            return
        }
        host.setNavigationMode(false)
        host.canvas.eraserWidth = eraserWidth
        host.canvas.isEraserActive = (inputMode == .eraser)
        // 套索态不下发 PencilKit 工具：保持上一支笔不变，落笔由 `isLassoActive` 门控。
        guard let tool = inputMode.tool else { return }
        switch tool {
        case .pen:
            host.setTool(PKInkingTool(.pen, color: color, width: penWidth))
        case .monoline:
            host.setTool(PKInkingTool(.monoline, color: color, width: penWidth))
        case .marker:
            host.setTool(PKInkingTool(.marker, color: color.withAlphaComponent(CGFloat(penOpacity * 0.45)), width: penWidth * 2.4))
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
        guard let page = currentPage else { return }
        // 显式方法驱动相位转移（不得依赖 didSet / 属性观察器）。
        savePhase = SavePolicy.reduce(savePhase, event: .contentChanged(pageUUID: page.uuid))
        let pageUUID = page.uuid
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: SavePolicy.debounce)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 相位 + 页身份双重校验：只有「仍在为同一页去抖」才允许落盘。
            // 换页时 `save()` 已经把相位推进过，这次 2 秒后的写盘于是被自然拦下 ——
            // 这正是「防抖任务误写换页后的另一页」的修法。
            guard SavePolicy.shouldCommit(phase: self.savePhase, pageUUID: pageUUID) else { return }
            self.save()
        }
    }

    /// 立即同步落盘。
    ///
    /// 相位机纪律（不变量 2）：进入 `.saving(pageUUID:)` → 落盘 → `.saveCompleted`
    /// 回到 `.clean`，全程不允许把相位留在脏态。换页类操作（`selectPage` / `addPage` /
    /// `movePages`…）走的就是它 —— 落盘完成后，之前那次去抖任务在 2 秒后到点时，
    /// `shouldCommit` 会发现相位已不是 `.debouncing`，于是不再重复写盘。
    ///
    /// 注意：本方法**刻意不取消**在途去抖任务（取消是 `flushPendingSave` 的职责），
    /// 重复写盘由相位 + 页身份校验天然消除，而不是靠取消副作用。
    func save() {
        guard let page = currentPage else { return }
        savePhase = .saving(pageUUID: page.uuid)
        saveNow()
        savePhase = SavePolicy.reduce(savePhase, event: .saveCompleted)
    }

    /// 真正的同步落盘（不含相位转移，供 `save()` 调用）。
    private func saveNow() {
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
        // 会话收敛到 .none（等价于旧的 4 个字段逐个清零，但只写一个真值）。
        editSession = .none
        markDirty()
    }

    func saveEntityAsCustomSticker(_ entity: ImageEntityView) {
        guard let stickerImg = entity.renderStickerImage(),
              let data = stickerImg.pngData() else { return }
        let fp = entity.stickerFingerprint
        _ = CustomStickerStore.shared.addSticker(imageData: data, fingerprint: fp)
        toastMessage = "已保存为贴纸"
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
        // 先把在途去抖收编为落盘相位（不变量 2：flush 之后必到 .saving）。
        savePhase = SavePolicy.reduce(savePhase, event: .flushRequested)
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
        let prevType = currentActiveToolType
        let nextMode = CanvasInputModePolicy.selecting(tool: tool, from: inputMode)
        // 是否“取消选中”看当前模式，换墨色/笔宽看目标工具 —— 两者语义不同，别混用。
        adoptPenSettings(for: tool)
        // remembered（M13）：只有在「落到某个绘制工具」且目标与上一支不同时才记下上一支；
        // 取消到导航态（nextMode == .navigation）不动它 —— 逐位等价旧 select 的
        // `if nextTool != nil && nextTarget != prev`。
        if nextMode != .navigation {
            let nextTarget = CanvasInputModePolicy.edgeTarget(of: nextMode)
            if nextTarget != prevType {
                previousToolType = prevType
            }
        }
        applyInputMode(nextMode)
    }

    /// 输入模式的**唯一应用管线**：应用模式 → 持久化 → 立即下发。
    ///
    /// 为什么集中成一处：旧实现把「改哪个字段、写哪份持久化、要不要刷新」散在三处手写代码里，
    /// 三处的 remembered 规则还各不相同。现在所有转移都经过这里，`inputMode` 是唯一真值。
    private func applyInputMode(_ mode: CanvasInputMode) {
        inputMode = mode
        settings.inputMode = mode
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

    /// 墨水透明度 —— 存入**当前这支笔**的槽位（每支笔独立记忆，0.05...1.0）。
    func updatePenOpacity(_ opacity: Double) {
        penOpacity = opacity
        settings.setPenOpacity(opacity, for: currentInkTool)
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

    /// 切换画布纸张底色（并持久化到 ToolSettingsStore）。
    func updatePaperStyle(_ style: CanvasPaperStyle) {
        paperStyle = style
        settings.paperStyle = style
        canvasHost?.canvas.paperStyle = style
        toastMessage = "已切换纸张：\(style.shortTitle)"
    }

    /// 是否处于「无工具 / 导航」状态。
    var isNavigating: Bool { inputMode == .navigation }

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
        let prevType = currentActiveToolType
        let nextMode = CanvasInputModePolicy.togglingLasso(from: inputMode)
        // remembered（M13，与 select 规则**刻意不同**）：进入套索记下进入前的模式，
        // 退出套索记下「套索」本身 —— 逐位等价旧 toggleLasso 的 if/else。
        // 不许与 select 统一：否则边缘双击的「切回上一个」手感会变（现网行为）。
        if nextMode == .lasso {
            if prevType != .lasso { previousToolType = prevType }
        } else {
            previousToolType = .lasso
        }
        applyInputMode(nextMode)
    }

    // MARK: - 边缘双击快捷切换

    func updateEdgeDoubleTapSettings(_ newSettings: EdgeDoubleTapSettings) {
        edgeDoubleTapSettings = newSettings
        settings.edgeDoubleTapSettings = newSettings
        syncEdgeDoubleTapState()
    }

    func syncEdgeDoubleTapState() {
        guard let host = canvasHost else { return }
        host.isLeftEdgeEnabled = edgeDoubleTapSettings.left.isEnabled
        host.isRightEdgeEnabled = edgeDoubleTapSettings.right.isEnabled
    }

    func handleEdgeDoubleTap(side: CanvasEdgeSide) {
        let config = (side == .left ? edgeDoubleTapSettings.left : edgeDoubleTapSettings.right)
        guard config.isEnabled else { return }

        let current = currentActiveToolType
        // 双击会发生什么，全部由纯决策函数给出（不再在两个分支里各自手写 remembered 更新）。
        let decision = CanvasInputModePolicy.switching(
            from: inputMode,
            action: config.mode,
            remembered: previousToolType,
            designated: config.designatedTool,
            savedBeforeDesignated: savedToolBeforeDesignated
        )
        previousToolType = decision.remembered
        savedToolBeforeDesignated = decision.savedBeforeDesignated
        let target = CanvasInputModePolicy.edgeTarget(of: decision.mode)
        // 仍走 switchTo，以保留「再点一次取消」的 toggle 语义（逐位等价旧实现）。
        switchTo(target: target)
        switch config.mode {
        case .switchToPrevious:
            toastMessage = "已切换至\(target.title)"
        case .switchToDesignated:
            toastMessage = (current != config.designatedTool)
                ? "已切换至\(target.title)" : "已切回\(target.title)"
        }
    }

    func switchTo(target: EdgeSwitchTargetTool) {
        switch target {
        case .lasso:
            // 直接进套索（不 toggle）——逐位等价旧 switchTo(.lasso)：**不更新** previousToolType。
            applyInputMode(CanvasInputModePolicy.transition(from: inputMode, to: .lasso))
        case .eraser, .pen, .monoline, .marker, .pencil:
            // 走 select 的 toggle 语义（逐位等价旧 switchTo 对各笔/橡皮的处理）。
            if let tool = CanvasTool(rawValue: target.rawValue) {
                select(tool: tool)
            }
        }
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
