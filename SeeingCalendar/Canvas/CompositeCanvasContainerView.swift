import PencilKit
import UIKit

/// 复合画布容器（Layer 0~6 的宿主）。
/// 核心职责：① 层级装配；② 触碰第一纳秒的贴图命中截流；③ 历史栈；④ 选区状态机入口。
@MainActor
final class CompositeCanvasContainerView: UIView {
    static let canvasSize = CGSize(width: 1400, height: 1400)

    let paperView = PaperBackgroundView()
    /// 笔迹之下的贴图层。
    let imageContainerView = UIView()
    let canvasView = TrackingCanvasView()
    /// 笔迹之上的贴图层（“置顶”后进入此层）。
    let imageFrontContainerView = UIView()
    /// 浮动选区内容（被取出的笔迹位图预览）。
    let selectionContentContainer = UIView()
    /// 选中贴图的**临时置顶**容器：保证选中态永远压在最上层，取消选中后归位。
    let selectionTopContainerView = UIView()
    let eraserIndicator = EraserIndicatorView()
    let selectionOverlay = SelectionOverlayView()

    var onContentChange: (() -> Void)?
    var onSelectionChange: ((CanvasSelectionKind) -> Void)?
    var onHistoryChange: ((Bool, Bool) -> Void)?
    var onRequestImageReplace: ((UUID) -> Void)?
    var onRequestItemEdit: ((UUID, CanvasItemPayload) -> Void)?
    var onSaveItemAsSticker: ((ImageEntityView) -> Void)?

    var imageViews: [ImageEntityView] = []

    // 历史栈
    private var history: [CanvasSnapshot] = []
    private var redoStack: [CanvasSnapshot] = []
    private let historyLimit = 30
    /// 程序化写入 drawing 的**嵌套深度计数器**。
    ///
    /// 为什么是计数器而不是 bool：**嵌套的程序化写入**（例如 `apply(_:)` 内部先后触发
    /// `discardSelection()` 与 `setDrawing(...)`，或未来任何在一次程序化写入里再发起
    /// 另一次写入的路径）会在内层 `defer` 退出时把布尔标志**提前放行**，于是
    /// `canvasViewDrawingDidChange` 会把程序化写入误判成「用户在用笔/橡皮」，
    /// 进而清掉选区、让重做栈失效。计数到 0 才算程序化结束，嵌套不会漏放行。
    private var programmaticDepth = 0

    /// `isProgrammatic` 的**引用计数式投影**（存储真值是上面的 `programmaticDepth`）。
    ///
    /// 为什么保留这个名字与「= true / = false」的读写形状：`scripts/verify_undo_history.swift`
    /// 把 `setDrawing` 的文本 `isProgrammatic = true defer { isProgrammatic = false }`
    /// 当不变量钉死（它守护的是「页内写入只换 strokes、绝不整份换」）。为不动既有门禁，
    /// 这里让赋值本身成立数动作：`= true` 深度 +1、`= false` 深度 -1。
    /// 于是「计数」语义真实成立（嵌套可重入），而既有调用点与门禁文本都不变。
    private var isProgrammatic: Bool {
        get { programmaticDepth > 0 }
        set { programmaticDepth += newValue ? 1 : -1 }
    }

    /// 常驻交互相位的**单一真值**（有笔按在画布上 / 正在拖拽选区）。
    ///
    /// 旧实现是两台各自没有类型的 bool（`isToolSessionActive` / `isAdjustingSelection`），
    /// 混住在同一批字段里、谁真谁假全凭调用点约定。现在由 `InteractionPolicy` 驱动，
    /// `isAdjustingSelection` / `isToolSessionActive` 降级为只读计算投影。
    private(set) var interactionPhase: InteractionPhase = .idle
    /// 原生菜单退场冷却相位的**单一真值**。
    ///
    /// 旧实现用 `menuActionGuardUntil: Date` 当状态：挂钟时间不是状态（`Date()` 抖一下、
    /// 主线程卡顿一下行为就变），且公开可写、语义靠约定、不可穷举。
    /// 现在由触摸生命周期驱动相位机：菜单选中动作 → `.coasting`，
    /// 透传下来的**一次**画布点击消费掉它 → `.open`。
    private(set) var menuGuardPhase: MenuGuardPhase = .open

    /// 兼容只读投影：旧 `menuActionGuardUntil` 的等价物（冷却中 = 远未来，否则 = 远过去）。
    /// 保留它只为零破坏迁移，任何**新**代码请直接读 `menuGuardPhase.blocksCanvasTap`。
    var menuActionGuardUntil: Date {
        menuGuardPhase == .coasting ? .distantFuture : .distantPast
    }

    /// 菜单冷却相位的**唯一写入点**：菜单里点选一个动作即进入透传保护。
    func noteMenuActionSelected() {
        menuGuardPhase = MenuGuardPolicy.reduce(menuGuardPhase, event: .menuActionSelected)
    }

    /// 交互相位的**唯一写入点**：把事件喂给 `InteractionPolicy`。
    ///
    /// 为什么不直接写 `interactionPhase`：它的 setter 是 `private(set)`，
    /// 而拖拽相关的事件都发生在另一个文件的扩展（`CompositeCanvasContainer+Selection.swift`）里。
    /// 经这个同形方法的单写者接入，既满足「真值只能由相位机推进」，
    /// 又让跨文件扩展无需放宽 `private(set)`。
    func noteInteraction(_ event: InteractionEvent) {
        interactionPhase = InteractionPolicy.reduce(interactionPhase, event: event)
    }

    // 选区状态
    var selectedImageIDs: [UUID] = []
    var selectedStrokes: [PKStroke] = []
    /// 选区语义相位的**单一真值**。唯一写者是 `notifySelection(broadcast:)`。
    private(set) var selectionPhase: SelectionPhase = .none
    var isGroupTransforming = false

    /// 选区相位的**只读计算投影**：5 个 case 与 `SelectionPhase` 一一对应。
    ///
    /// 保留它是为了让 `EditorModel` 与 `SelectionOverlayView` 的全部既有调用点**零改动**；
    /// 它没有 setter —— 任何想改选区的人都必须去写**原始事实**并调 `notifySelection()`。
    var selectionKind: CanvasSelectionKind {
        switch selectionPhase {
        case .none: return .none
        case .composite: return .composite
        case .image(let id): return .image(id)
        case .compositeTransform: return .compositeTransform
        case .cropping(let id): return .cropping(id)
        }
    }

    /// 是否正在拖拽选区（手柄 / 贴图位移 / 整体变换）。旧 `isAdjustingSelection` 的只读投影。
    var isAdjustingSelection: Bool { interactionPhase.isAdjusting }
    /// 是否有笔正按在画布上。旧 `isToolSessionActive` 的只读投影。
    private var isToolSessionActive: Bool { interactionPhase == .toolSession }

    /// 锁定贴图数量变化回调（供编辑器的「解锁全部贴图」菜单项显示数量与可用性）。
    var onLockedCountChanged: ((Int) -> Void)?
    var croppingImageID: UUID?
    var floatingPreview: UIImageView?
    /// 手势进行中的基准暂存（per-mode scratch）：5 个扁平字段已收进这个带类型的值。
    var gestureScratch: SelectionGestureScratch = .none
    /// 手势的起始点。缩放 / 旋转 / 内部拖拽都要拿它算「相对起点的位移 / 夹角」。
    ///
    /// 它**不**进 `SelectionGestureScratch`：它是三种手势共用的同一个原始量，
    /// 含义不随手势种类改变（都是「手指落下的那一点」），收进枚举反而要在每个 case 里抄一遍。
    var gestureBasePoint: CGPoint = .zero
    var clipboard: CanvasClipboard?

    /// 绘制策略或手指书写开关变化回调（供宿主视图同步平移手势的最低触控指树限制）。
    var onDrawingPolicyChanged: (() -> Void)?

    /// 是否允许在画布上落笔（取消全部工具后即为「导航态」：只平移缩放）。
    var isDrawingEnabled: Bool = true {
        didSet {
            guard oldValue != isDrawingEnabled else { return }
            updateInteractionPolicy()
            onDrawingPolicyChanged?()
        }
    }

    var isFingerDrawingEnabled: Bool = false {
        didSet {
            guard oldValue != isFingerDrawingEnabled else { return }
            updateDrawingPolicy()
            onDrawingPolicyChanged?()
        }
    }

    /// 画布输入模式（导航 / 4 种笔 / 橡皮 / 套索）。由 `EditorModel` 下发，供宿主视图
    /// 决定单指归属（见 `TouchRoutingPolicy`）。
    ///
    /// 为什么在容器上再放一份：宿主视图 `CanvasHostView` 不持有 `EditorModel`，沿用的就是
    /// `isFingerDrawingEnabled` / `isDrawingEnabled` 这条路 —— 由模型主动赋值推送，不新建机制。
    var inputMode: CanvasInputMode = .navigation {
        didSet {
            guard oldValue != inputMode else { return }
            onDrawingPolicyChanged?()
        }
    }

    var isLassoActive: Bool = false {
        didSet {
            guard oldValue != isLassoActive else { return }
            selectionOverlay.isLassoActive = isLassoActive
            updateInteractionPolicy()
            if isLassoActive, !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
                // 套索与笔墨互斥：进入套索即退出选区编辑态。
                // 延后一拍执行，避免在 SwiftUI 更新回合内回调可观察状态。
                Task { @MainActor [weak self] in
                    guard let self, self.isLassoActive else { return }
                    self.commitSelection(notify: true)
                }
            }
        }
    }

    var overlayScale: CGFloat = 1 {
        didSet {
            selectionOverlay.contentScale = overlayScale
            eraserIndicator.contentScale = overlayScale
        }
    }

    /// 橡皮是否处于激活状态（决定是否显示有效范围圈）。
    var isEraserActive: Bool = false {
        didSet {
            eraserIndicator.isHidden = !isEraserActive
            if !isEraserActive { eraserIndicator.update(point: nil) }
        }
    }

    /// 橡皮有效范围（画布世界坐标下的直径，与 PKEraserTool.width 保持一致）。
    var eraserWidth: CGFloat = 24 {
        didSet { eraserIndicator.eraserWidth = eraserWidth }
    }

    /// 画布纸张底色样式（纯白 / 复古和纸护眼米白 `#FBF9F5` 等）。
    var paperStyle: CanvasPaperStyle = .pureWhite {
        didSet {
            guard oldValue != paperStyle else { return }
            paperView.paperStyle = paperStyle
            backgroundColor = paperStyle.backgroundColor
        }
    }

    // MARK: - 生命周期

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .white

        addSubview(paperView)
        imageContainerView.backgroundColor = .clear
        addSubview(imageContainerView)

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .pencilOnly
        canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
        canvasView.contentSize = Self.canvasSize
        addSubview(canvasView)

        imageFrontContainerView.backgroundColor = .clear
        addSubview(imageFrontContainerView)

        addSubview(eraserIndicator)
        canvasView.onTouch = { [weak self] point, touchType in
            guard let self else { return }
            // 有效范围圈只在"这次触摸真的会擦除"时显示：
            // 橡皮激活 + （手指书写开启 或 这一下是 Apple Pencil）。
            // 手指开关关闭时用手指标橡皮既不擦除、也不该显示圆圈。
            let canErase = self.isFingerDrawingEnabled || touchType == .pencil
            let shouldShow = self.isEraserActive && canErase
            self.eraserIndicator.isHidden = !shouldShow
            self.eraserIndicator.update(point: shouldShow ? point : nil)
        }

        selectionContentContainer.backgroundColor = .clear
        selectionContentContainer.isUserInteractionEnabled = false
        addSubview(selectionContentContainer)

        selectionTopContainerView.backgroundColor = .clear
        addSubview(selectionTopContainerView)

        selectionOverlay.delegate = self
        selectionOverlay.allowsFingerLasso = isFingerDrawingEnabled
        addSubview(selectionOverlay)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleContainerTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        paperView.frame = CGRect(origin: .zero, size: size)
        imageContainerView.frame = CGRect(origin: .zero, size: size)
        canvasView.frame = CGRect(origin: .zero, size: size)
        imageFrontContainerView.frame = CGRect(origin: .zero, size: size)
        eraserIndicator.frame = CGRect(origin: .zero, size: size)
        selectionContentContainer.frame = CGRect(origin: .zero, size: size)
        selectionTopContainerView.frame = CGRect(origin: .zero, size: size)
        selectionOverlay.frame = CGRect(origin: .zero, size: size)
    }

    private func updateDrawingPolicy() {
        canvasView.drawingPolicy = isFingerDrawingEnabled ? .anyInput : .pencilOnly
        // 套索是否允许手指参与，与「手指书写」开关保持一致。
        selectionOverlay.allowsFingerLasso = isFingerDrawingEnabled
    }

    private func updateInteractionPolicy() {
        canvasView.isUserInteractionEnabled = isDrawingEnabled && !isLassoActive
    }

    // MARK: - 触控仲裁（spec 3.1 核心）

    /// 允许在画布矩形之外参与命中测试：
    /// 贴图可以被拖出 1400×1400 画布之外（视口留白处仍会绘制），
    /// 若不放行 `point(inside:)`，这些贴图就会"看得见、摸不着"，也无法保证图片操作优先于消失手势。
    /// 命中失败时返回 nil，事件照旧落到外层滚动视图（双指平移缩放不受影响）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }

        let overlayPoint = convert(point, to: selectionOverlay)

        // 1. 手柄 / 浮动菜单 / 变形态内部拖动区：手指与 Pencil 都可操作。
        //    （这是"手指开关关闭时手指仍可操控控制点"的实现路径。）
        if selectionOverlay.hitsInteractiveElement(overlayPoint),
           let hit = selectionOverlay.hitTest(overlayPoint, with: event) {
            return hit
        }

        // 2. 贴图命中：临时置顶层 → 前置层 → 后置层，逆序遍历保证顶层优先。
        if let entity = imageEntity(at: point) {
            // 已选中的贴图：任何模式下（含套索态）都直接交给它 ——
            // 拖动它就是移动贴图，而不是重新画一个套索。
            if selectedImageIDs.contains(entity.itemID) {
                return entity
            }
            // 未选中的贴图：非套索态下一律拦截（图片绝对优先，杜绝“选中贴图同时画出污点”）；
            // 套索态下不拦，交给套索圈选（重叠即选中，见 UnifiedLassoArbitrator）。
            if !isLassoActive {
                return entity
            }
        }

        // 3. 套索模式：其余区域由覆盖层接管。
        //    「这一下该不该画套索」在 SelectionOverlayView.touchesBegan 里判定 ——
        //    因为事件的触摸集合在 hitTest 阶段不可靠（初次落笔常常取不到该触摸），
        //    曾经据此分流导致「关闭手指开关后完全无法套索」。
        if isLassoActive {
            return selectionOverlay
        }

        // 4. 画布内：交给 PencilKit（是否响应取决于 drawingPolicy / 是否处于导航态）
        if canvasView.isUserInteractionEnabled {
            let local = convert(point, to: canvasView)
            if let hit = canvasView.hitTest(local, with: event) {
                return hit
            }
        }

        // 5. 画纸之外的空白（缩小时暴露的四周留白）：接管为「空白区域」，
        //    使得"点画纸外"与"点画纸内空白处"行为一致（取消选中 / 弹菜单）。
        //    接管后事件不会再落到滚动视图，但双指平移缩放依赖手势识别器（作用于整棵子树），不受影响。
        return self
    }

    /// 命中测试：返回该点最上层的贴图实体（临时置顶层 → 前置层 → 后置层）。
    /// **锁定贴图直接跳过** —— 锁定后完全惰性：不可选中、不可移动，
    /// 也因此不会截断绘制事件（可以在锁定素材之上直接画）。
    func imageEntity(at point: CGPoint) -> ImageEntityView? {
        for container in [selectionTopContainerView, imageFrontContainerView, imageContainerView] {
            for subview in container.subviews.reversed() {
                guard let entity = subview as? ImageEntityView, !entity.isHidden, entity.alpha > 0.01 else { continue }
                guard !entity.isLocked else { continue }
                let local = entity.convert(point, from: self)
                if entity.bounds.contains(local) {
                    return entity
                }
            }
        }
        return nil
    }

    @objc private func handleContainerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        // 刚从原生菜单点选动作后，菜单退场可能把**一次**触摸透传下来：
        // 忽略这一次，否则会立刻把刚建立的选择清掉（表现为“变形点了没反应”）。
        // 旧写法用挂钟时间窗（对比当前时刻与冷却时间戳）：不可穷举，
        // 且主线程卡顿会随机漏掉 / 吞掉用户的正常点击。
        // 现改为「读相位 + 发送 tapReceived 事件」两步：冷却窗口 = 恰好一次点击。
        if menuGuardPhase.blocksCanvasTap {
            menuGuardPhase = MenuGuardPolicy.reduce(menuGuardPhase, event: .tapReceived)
            return
        }

        let point = gesture.location(in: self)

        // 1) 手柄 / 浮动菜单：交给它们自己处理
        if selectionOverlay.hitsHandleOrMenu(point) { return }

        // 2) 点在贴图上 → 选中该贴图。
        //    - 变形态下**不改选对象**：用户约定"点框内保持变形态并弹菜单"；
        //    - 裁剪态下同样不改选，避免误触退出裁剪；
        //    - 套索态（非变形态）下触摸会被内部拖动区/套索层接管，贴图自身手势收不到事件，
        //      因此由容器代劳选中并弹菜单。
        if !isGroupTransforming, croppingImageID == nil,
           let entity = imageEntity(at: point) {   // 已跳过锁定贴图
            selectImage(id: entity.itemID, additive: false)
            selectionOverlay.presentMenu()
            return
        }

        // 3) 点在选区内（非手柄）：保持选中与当前模式，并弹出编辑菜单
        if selectionOverlay.containsSelection(point) {
            selectionOverlay.presentMenu()
            return
        }

        // 4) 点在选区之外：取消选中
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            clearSelection()
        }
    }

    // MARK: - 内容装载

    func load(drawing: PKDrawing, items: [CanvasImageItem], resetHistory: Bool = true) {
        // 切换页面：直接丢弃浮动选区，绝不把上一页的笔迹并入本页。
        discardSelection()
        installDrawing(drawing)
        rebuildImageViews(items)
        if resetHistory {
            history.removeAll()
            redoStack.removeAll()
            notifyHistory()
        }
        notifySelection()
    }

    /// 快照必须包含“浮动选区中的笔迹”，否则撤销/重做会丢内容。
    func snapshot() -> CanvasSnapshot {
        var drawing = canvasView.drawing
        if !selectedStrokes.isEmpty {
            drawing.strokes.append(contentsOf: selectedStrokes)
        }
        return CanvasSnapshot(drawing: drawing, items: currentItems())
    }

    func currentItems() -> [CanvasImageItem] {
        imageViews.map(\.canvasItem).sorted { $0.zIndex < $1.zIndex }
    }

    /// 画布 drawing 的**唯一写入漏斗**。
    ///
    /// 为什么要做三件事，而不只是把新 drawing 赋给画布：
    ///
    /// 1. **清掉 PencilKit 自己的撤销登记**。`PKCanvasView` 会把 drawin 变更
    ///    自动登记到 `undoManager`，而这个登记**不会因为程序化赋值而失效**
    ///    （社区一致的现象：给画布赋新 drawing 后，撤销按钮仍然可用）。
    ///    本应用的撤销是 `history`/`redoStack` 的 30 步快照（还含贴图与裁剪，
    ///    PencilKit 的栈根本表示不了），两边同时存在就是**两个引擎写同一份 drawing**，
    ///    而我们的历史永远追不上它那条链。这里直接把它清掉，
    ///    让「本应用的 30 步历史」成为**唯一**历史。
    ///    代价：窗口的撤销栈也会被清一次，会连带清掉正在编辑的文本框的撤销记录。
    ///    编辑器全屏遮住主页面、且文本框不在画布上，这个代价极小；
    ///    而代价的另一边是「被撤销的笔画自己回来」。
    ///
    /// 2. **强制 PencilKit 舍弃它内部的旧副本**（先清空再装入）。
    ///    只赋一次值，PencilKit 内部可能仍持有替换前的副本，
    ///    于是在下一笔结束时按旧副本回写 —— 现象正是**被撤销的笔画在新笔画绘完时复活**。
    ///    同一轮 runloop 内的两次赋值不会产生可见闪烁（没有显示回合夹在中间），
    ///    却能把它内部的旧副本顶掉。
    ///
    /// 3. **有笔正按在画布上时只赋一次**。
    ///    此时清空会把进行中的那一笔置于未知状态（极端情况直接丢笔），
    ///    而这条路径本来就是「开始落笔时把浮动选区落回画布」（见
    ///    `canvasViewDidBeginUsingTool`），绝对不能把画布清一下再装。
    ///    真正造成陈旧副本的是**撤销/重做/换页**这些“没有笔在画”的时机，
    ///    那里的清空-装入才是安全的（也正是失效场景所在）。
    /// 页内改动（撤销 / 重做 / 选区提交 / 套索取出）写入 drawing 的**唯一**漏斗。
    ///
    /// ★ 关键：**只替换笔迹列表，绝不把整份 drawing 换掉**。
    ///
    /// `PKDrawing` 不是一串普通笔迹：Apple 自己的头文件里它带 `_uuid`、`_replicaUUID`、
    /// `_version`（PKVectorTimestamp），是 **CRDT 式版本语义** —— 社区也早报过
    /// “两个空白 drawing 用 == 比较不相等”。于是：
    ///
    ///  · 整份换上一份**旧快照** ＝ 给画布一份**旧版本**的 drawing。而“删除”在旧版本里
    ///    还没发生 —— PencilKit 在**提交新笔画**时按版本对账，那些被删掉的笔迹算“尚未删除”，
    ///    于是**被撤销的笔画就这么回来了**，且出现时机正好是**笔离开画布那一刻**（对账点）。
    ///  · 改成只写 `strokes`：取的是**画布当前**的版本，只有笔迹列表不同，
    ///    PencilKit 才能把差集当成“在当前版本上删除”落成墓碑，删除才真的生效。
    ///    这也正是 Apple 官方推荐的程序化修改方式（改 `strokes`，而不是换整份 drawing）。
    ///
    /// 不用“先清空再装入”之类的技巧：那会再造一份外来版本，只会把版本谱系搞得更乱
    /// （v1.0.25 试过，对用户报的这个现象无效）。
    ///
    /// 另外仍然清掉 PencilKit 自己的撤销登记：本应用的撤销是 `history`/`redoStack`
    /// 的 30 步快照（还含贴图与裁剪，PencilKit 的栈根本表示不了），
    /// 两套引擎并存时我们追不上它那条链。代价是窗口撤销栈也会被清一次
    /// （会连带清掉正在编辑的文本框的撤销记录）；编辑器全屏遮住主页面、
    /// 文本框不在画布上，代价极小。
    func setDrawing(_ drawing: PKDrawing) {
        isProgrammatic = true
        defer { isProgrammatic = false }
        canvasView.undoManager?.removeAllActions()
        canvasView.drawing.strokes = drawing.strokes
    }

    /// 换页 / 首次装载：**整份**装入 drawing（这是全工程唯一该整份赋值的地方）。
    ///
    /// 与 `setDrawing` 的分工不是风格问题：换页拿到的 drawing 是从磁盘解码出来的
    /// （全新一次解码 = 全新的内部版本谱系），与画布当前内容没有可对账的版本关系；
    /// 而“装入某一页”本来就应该是干净起点。页内的撤销/重做则必须保留当前版本。
    func installDrawing(_ drawing: PKDrawing) {
        isProgrammatic = true
        defer { isProgrammatic = false }
        canvasView.undoManager?.removeAllActions()
        canvasView.drawing = drawing
    }

    func rebuildImageViews(_ items: [CanvasImageItem]) {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []

        let sorted = items.sorted { $0.zIndex < $1.zIndex }
        let back = sorted.filter { !$0.isInFront }
        let front = sorted.filter(\.isInFront)

        for (index, item) in back.enumerated() {
            var normalized = item
            normalized.zIndex = index
            let entity = makeEntity(normalized)
            imageContainerView.addSubview(entity)
            imageViews.append(entity)
        }
        for (index, item) in front.enumerated() {
            var normalized = item
            normalized.zIndex = CanvasLayers.frontBase + index
            let entity = makeEntity(normalized)
            imageFrontContainerView.addSubview(entity)
            imageViews.append(entity)
        }
        notifyLockState()
    }

    func makeEntity(_ item: CanvasImageItem) -> ImageEntityView {
        let entity = ImageEntityView(item: item)
        entity.setLocked(item.isLocked)
        entity.onSelect = { [weak self] view in
            self?.selectImage(id: view.itemID, additive: false)
        }
        entity.onBeginMove = { [weak self] view in
            guard let self else { return }
            // 拖拽期间不重建手柄、不重弹菜单（由 interactionPhase.allowsOverlayRebuild 守卫）。
            // 注意：这里**不能**调用 dismissMenu() —— 收起原生菜单会中断正在进行中的触摸，
            // 表现为「第一次拖动只走一下，第二次才正常」。
            self.noteInteraction(.selectionAdjustingBegan)
            self.pushHistory()
            _ = view
        }
        entity.onTransformChanged = { [weak self] _ in
            guard let self else { return }
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }
        entity.onEndMove = { [weak self] _ in
            guard let self else { return }
            self.noteInteraction(.selectionAdjustingEnded)
            // 手指脱离后才把选中贴图重挂载到顶层容器（拖拽中重挂载会取消手势）。
            self.elevateSelection()
            self.refreshSelectionOverlay()
            self.onContentChange?()
        }
        return entity
    }

    // MARK: - 锁定贴图

    var lockedImageCount: Int {
        imageViews.filter(\.isLocked).count
    }

    func notifyLockState() {
        onLockedCountChanged?(lockedImageCount)
    }

    /// 锁定 / 解锁指定贴图。锁定后立即取消其选中态。
    func setLocked(_ locked: Bool, for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            guard let entity = entity(for: id), entity.isLocked != locked else { continue }
            entity.setLocked(locked)
            changed = true
        }
        guard changed else { return }
        if locked {
            commitSelection(notify: false)
            notifySelection()
        }
        notifyLockState()
        onContentChange?()
    }

    func lockSelectedImages() {
        pushHistory()
        setLocked(true, for: selectedImageIDs)
    }

    func unlockAllImages() {
        pushHistory()
        setLocked(false, for: imageViews.map(\.itemID))
    }

    /// 按图层归属放置视图；`elevated` 表示临时置顶（选中态）。
    func place(_ entity: ImageEntityView, elevated: Bool = false) {
        let wasElevated = entity.superview === selectionTopContainerView
        entity.removeFromSuperview()
        if elevated {
            selectionTopContainerView.addSubview(entity)
        } else if entity.zIndex >= CanvasLayers.frontBase {
            imageFrontContainerView.addSubview(entity)
        } else {
            imageContainerView.addSubview(entity)
        }
        if !imageViews.contains(where: { $0.itemID == entity.itemID }) {
            imageViews.append(entity)
        }
        if wasElevated != elevated {
            selectionTopContainerView.isUserInteractionEnabled = true
        }
    }

    /// 取消选中：把所有临时置顶的贴图归位并撤掉高亮。
    func releaseElevatedSelection() {
        for entity in imageViews {
            if entity.superview === selectionTopContainerView, !entity.isMoving {
                place(entity, elevated: false)
            }
            entity.setHighlighted(false)
        }
    }

    /// 选中：临时高亮置顶。
    /// 注意：正在被拖动的实体只做高亮，重挂载推迟到 `onEndMove` ——
    /// `removeFromSuperview` 会立即取消该视图进行中的 pan 手势，导致“选中后无法移动”。
    func elevateSelection() {
        for id in selectedImageIDs {
            guard let entity = entity(for: id) else { continue }
            entity.setHighlighted(true)
            guard !entity.isMoving else { continue }
            place(entity, elevated: true)
        }
    }

    // MARK: - 历史

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 压入历史：快照已自包含浮动笔迹，因此无需打断当前选区。
    func pushHistory() {
        history.append(snapshot())
        if history.count > historyLimit { history.removeFirst() }
        redoStack.removeAll()
        notifyHistory()
    }

    func undo() {
        // 先把浮动选区落回画布，保证快照语义完整（否则撤销会丢失被选中的笔迹）。
        commitSelection(notify: false)
        guard let previous = history.popLast() else {
            notifyHistory()
            return
        }
        redoStack.append(snapshot())
        apply(previous)
        notifyHistory()
    }

    func redo() {
        commitSelection(notify: false)
        guard let next = redoStack.popLast() else {
            notifyHistory()
            return
        }
        history.append(snapshot())
        apply(next)
        notifyHistory()
    }

    private func apply(_ snapshot: CanvasSnapshot) {
        discardSelection()
        setDrawing(snapshot.drawing)
        rebuildImageViews(snapshot.items)
        notifySelection()
        onContentChange?()
    }

    private func notifyHistory() {
        onHistoryChange?(canUndo, canRedo)
    }

    /// 选区相位的**唯一写入点**：由原始事实重新推导相位、刷新覆盖层，
    /// 并按 `broadcast` 决定是否对外回调 `onSelectionChange`。
    ///
    /// 为什么把「更新状态」与「对外广播」拆开：旧实现把两件事塞进 `commitSelection(notify:)`
    /// 一个 bool —— 传 `false` 时既不广播、也**不重推导**，改走一条直接写 `selectionKind = .none`
    /// 的旁路，于是相位出现了第二、第三个写者。现在相位永远在这里被重建，
    /// `broadcast` 只影响回调：传 `false` 时仍会更新真值与覆盖层，只是不对外广播。
    func notifySelection(broadcast: Bool = true) {
        selectionPhase = SelectionStatePolicy.phase(
            imageIDs: selectedImageIDs,
            strokeCount: selectedStrokes.count,
            isGroupTransforming: isGroupTransforming,
            croppingID: croppingImageID
        )
        if broadcast { onSelectionChange?(selectionKind) }
        refreshSelectionOverlay()
    }

    // MARK: - 贴图 API

    @discardableResult
    func addImage(_ image: UIImage, fileName: String, offset: CGPoint = .zero, payload: CanvasItemPayload? = nil) -> UUID {
        pushHistory()
        let natural = CGSize(width: max(1, image.size.width * image.scale),
                             height: max(1, image.size.height * image.scale))
        let transform = Self.entranceTransform(naturalSize: natural, offset: offset)
        let nextZ = nextZIndex(inFront: false)
        let item = CanvasImageItem(id: UUID(),
                                   fileName: fileName,
                                   image: image,
                                   worldTransform: transform,
                                   cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   naturalSize: natural,
                                   zIndex: nextZ,
                                   payload: payload)
        if let payload {
            CanvasPayloadStore.savePayload(payload, for: fileName)
        }
        let entity = makeEntity(item)
        place(entity)
        selectImage(id: item.id, additive: false)
        onContentChange?()
        return item.id
    }

    /// 原地更新可编辑图元（文本/形状等），保持中心点不变
    func updateImageItem(id: UUID, image: UIImage, payload: CanvasItemPayload) {
        guard let entity = entity(for: id) else { return }
        pushHistory()
        let oldCenter = entity.worldCenter
        let oldVisibleSize = entity.visibleSize
        let newNatural = CGSize(width: max(1, image.size.width * image.scale),
                                height: max(1, image.size.height * image.scale))

        // 写回磁盘文件与元数据
        let url = AppPaths.assetURL(entity.fileName)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        CanvasPayloadStore.savePayload(payload, for: entity.fileName)

        // 保持中心点位置不变
        var newTransform = entity.worldTransform
        let currentCenter = newTransform.applied(to: CGPoint(x: newNatural.width / 2, y: newNatural.height / 2))
        let dx = oldCenter.x - currentCenter.x
        let dy = oldCenter.y - currentCenter.y
        newTransform = newTransform.concatenating(CGAffineTransform(translationX: dx, y: dy))

        entity.worldTransform = newTransform
        entity.updateContent(image: image, naturalSize: newNatural, payload: payload)

        notifySelection()
        onContentChange?()
    }

    /// 智能入场缩放：不超画布则 1:1 居中；超出则按 Aspect Fit 落入 90% 安全区。
    static func entranceTransform(naturalSize: CGSize, offset: CGPoint = .zero) -> CGAffineTransform {
        let canvas = canvasSize
        var scale: CGFloat = 1
        if naturalSize.width > canvas.width || naturalSize.height > canvas.height {
            let safeWidth = canvas.width * 0.9
            let safeHeight = canvas.height * 0.9
            scale = min(safeWidth / naturalSize.width, safeHeight / naturalSize.height)
        }
        let size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        let origin = CGPoint(x: (canvas.width - size.width) / 2 + offset.x,
                             y: (canvas.height - size.height) / 2 + offset.y)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
    }

    func entity(for id: UUID) -> ImageEntityView? {
        imageViews.first { $0.itemID == id }
    }

    /// 删除全部内容（清空当前页）。
    func clearAll() {
        pushHistory()
        commitSelection(notify: false)
        setDrawing(PKDrawing())
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
        notifySelection()
        onContentChange?()
    }

    func replaceImage(id: UUID, image: UIImage, fileName: String) {
        guard let entity = entity(for: id) else { return }
        pushHistory()
        let natural = CGSize(width: max(1, image.size.width * image.scale),
                             height: max(1, image.size.height * image.scale))
        // 保持画面中心与可见尺寸，替换为原图比例的等价变换
        let currentCenter = entity.worldCenter
        let currentSize = entity.visibleSize
        let scale = min(currentSize.width / natural.width, currentSize.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        let rotation = entity.worldTransform.rotationAngle
        let cosinus = cos(rotation)
        let sinus = sin(rotation)
        let transform = CGAffineTransform(a: scale * cosinus, b: scale * sinus,
                                          c: -scale * sinus, d: scale * cosinus,
                                          tx: currentCenter.x - (scale * cosinus * size.width / 2 - scale * sinus * size.height / 2),
                                          ty: currentCenter.y - (scale * sinus * size.width / 2 + scale * cosinus * size.height / 2))
        let item = CanvasImageItem(id: entity.itemID,
                                   fileName: fileName,
                                   image: image,
                                   worldTransform: transform,
                                   cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   naturalSize: natural,
                                   zIndex: entity.zIndex)
        entity.removeFromSuperview()
        imageViews.removeAll { $0.itemID == id }
        let replacement = makeEntity(item)
        place(replacement)
        selectImage(id: id, additive: false)
        onContentChange?()
    }
}

// MARK: - PKCanvasViewDelegate

extension CompositeCanvasContainerView: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard !isToolSessionActive else { return }
        noteInteraction(.toolSessionBegan)
        // 落笔即视为退出选区编辑态（等价于“点按空白处取消选中”）。
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            commitSelection(notify: true)
        }
        pushHistory()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        noteInteraction(.toolSessionEnded)
        onContentChange?()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard programmaticDepth == 0 else { return }
        // 画布内容一旦变化，说明用户在用笔/橡皮 —— 等价于“点按空白处”，选区随即失效。
        // 该路径不依赖手势共存仲裁，因此“手指书写开启”时同样可靠。
        if !selectedImageIDs.isEmpty || !selectedStrokes.isEmpty {
            commitSelection(notify: true)
        }
        // ★ 任何内容变化都让「重做」失效，而不只是在 `pushHistory()` 里失效。
        // 理由：重做栈只在「最后一次操作是撤销」时才有意义。一旦内容变了
        // （不管变化是我们登记的，还是别人改了画布 —— 例如 PencilKit 按它自己的
        // 撤销登记回写），重做栈指向的就是**另一条线**的旧状态；
        // 这时按重做就是把已经被撤销/改掉的内容搬回来。
        invalidateRedoStack()
        onContentChange?()
    }

    /// 让重做栈失效（内容一变就必须调；幂等）。
    func invalidateRedoStack() {
        guard !redoStack.isEmpty else { return }
        redoStack.removeAll()
        notifyHistory()
    }
}
