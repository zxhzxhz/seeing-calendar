# “视觉手绘日历”产品需求规格书与技术架构方案 (v2.2)

## 一、 产品定位与形态定义 (Product Report)

### 1.1 产品定位

一款以 **“无模板自由手绘（Apple Pencil First）”** 为核心创作方式、以 **“**$1:1$ **正方形网格缩略图联动”** 为视觉载体的新型 iPadOS 视觉手帐与日程管理应用。

* **核心差异化**：

  * 区别于传统日程工具的文字堆砌与冰冷色块。

  * 区别于 GoodNotes / Notability 等泛笔记软件的“手动截图贴回日历”，实现“画即所得、日记即日程、月历即画廊”的自动化闭环。

* **目标用户**：手帐爱好者、插画师/视觉创作者、轻度日程管理者、视觉打卡习惯养成者。

### 1.2 画布 $1:1$ 比例方案评估与屏幕自适应策略

#### 1. 方案可行性与设计美学评估

经数学模型推导与视口几何计算，将创作画布与月历单元格强制固定为 $1:1$**（正方形）** 是极其合理且优于动态宽高比的方案：

* **核心痛点解决**：如果画布比例跟随屏幕物理比例（如 iPad 默认的 $4:3$ 或 $16:11$），一旦用户旋转设备（横屏 $\leftrightarrow$ 竖屏）或进入分屏（Split View），原本的长方形格子比例会发生剧烈畸变，导致之前绘制的笔迹出现严重的上下/左右黑边（Letterboxing）或不匹配拉伸。

* $1:1$ **的美学与工程优势**：

  * **几何不变性**：正方形画布具有各向同性，无论设备如何旋转、分屏宽度如何拖拽，画布本身的内部坐标系永远保持 $1:1$ 恒定，手写笔迹与贴图永不形变。

  * **画廊感与拟物感**：正方形天然契合拍立得照片（Polaroid）、Instagram 视觉流以及手帐便签的视觉直觉，整月平铺时具备极强的网格阵列美感。

#### 2. iPad 各模式下的视口动态适配逻辑

iPad 主流屏幕比例为 $4:3$（如 iPad Pro 12.9"、$2048 \times 2732$ 点阵）与 $1.43:1$（iPad Pro 11"）。按 $7 \times 5$ 或 $7 \times 6$ 的月历矩阵计算：

```
[ iPad 横屏态 (Landscape ~4:3) ]
┌───────────────────────────────────────────────────────────┐
│ 顶栏导航区 (Header: 月份、视图切换、备份、设置)               │
├─────┬─────┬─────┬─────┬─────┬─────┬─────┤ 7 列正方形格子自然
│ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 撑满横向宽度，
├─────┼─────┼─────┼─────┼─────┼─────┼─────┤ 垂直方向占用约 85% 高度，
│ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 上下边距极其匀称紧凑。
├─────┼─────┼─────┼─────┼─────┼─────┼─────┤
│ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 
└─────┴─────┴─────┴─────┴─────┴─────┴─────┘

[ iPad 竖屏态 (Portrait ~3:4) ]
┌───────────────────────────────────────────┐
│ 顶栏导航区 (Header)                        │
├─────┬─────┬─────┬─────┬─────┬─────┬─────┤ 7 列正方形格子在竖屏下
│ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 占用垂直高度约 52%~58%。
├─────┼─────┼─────┼─────┼─────┼─────┼─────┤
│ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 1:1 │ 
├─────┴─────┴─────┴─────┴─────┴─────┴─────┤
│ [ 动态扩展区 (Dynamic Context Drawer) ]    │ 竖屏剩余的大量纵向空间
│  - 当日 ICS 日程详细时间轴 (Timeline)       │ 转为常驻“日程/打卡详情抽屉”，
│  - 多页手绘画作横向轮播预览 (Page Carousel)  │ 形成“上月历 + 下详情”的绝佳
│  - 便签式快捷记录栏                       │ 生产力组合，避免版面大面积留白。
└───────────────────────────────────────────┘

```

#### 3. 动态视觉细节分级系统 (Adaptive LOD - Level of Detail)

根据当前单格正方形的实际物理渲染宽度 $W_{cell}$，动态调控格子内部的 UI 呈现精度：

| 

| **模式 / 宽度区间** | **典型场景** | **缩略图呈现** | **日期与角标** | **ICS 日程显示粒度** | 
| **LOD 3 (全量级)**  $W_{cell} \ge 120\text{pt}$ | 全屏横屏、竖屏 7 列模式 | 完整显示 Page 1 高保真缩略图 | 日期大字 + 班/休角标 + 多页角标（如 `+2`） | 底部半透明胶囊标签，显示最多 2 条微型日程文字标题 | 
| **LOD 2 (紧凑级)**  $70\text{pt} \le W_{cell} < 120\text{pt}$ | 分屏 $2/3$ 宽度模式 | 完整显示 Page 1 缩略图 | 标准日期字号 + 班/休圆点徽标 | 仅显示 ICS 事件分类彩色实心圆点（Dots，最多 3 颗） | 
| **LOD 1 (极小级)**  $W_{cell} < 70\text{pt}$ | 分屏 $1/3$ 宽度模式（Slide Over） | 仅呈现纯手绘轮廓缩略图（略微提亮背景） | 仅显示公历日期数字 | 隐藏全部文字，仅在有事件时呈现 1 个呼吸微点指示 | 

### 1.3 核心功能规范

#### 1. 数据备份与完整导入恢复机制 (Backup & Restore System)

为保障用户长达数年的手写笔记、插画与照片安全，提供平台级离线归档与跨设备迁移方案：

* **归档打包格式（`.vcal` 文件包）**：

  * 本质为标准 ZIP 压缩包，内部包含结构化元数据（JSON）、PencilKit 矢量笔迹文件（二进制 `.pkdrawing`）、导入的外置高分辨率图片/贴图（`.webp` 或 `.png`）。

* **导出与备份功能**：

  * **手动完整备份**：一键生成带时间戳的归档文件 `VisualCalendar_Backup_YYYYMMDD_HHmm.vcal`，调用系统分享面板，可存储至“文件（Files）”App、外接固态硬盘、AirDrop 隔空投送或第三方云盘。

  * **自动本地快照**：应用每周自动在沙盒缓存区构建轻量增量快照，最多保留最近 3 个版本，防止误操作。

* **导入与恢复策略**：

  * 支持从系统“文件”App 中“打开方式...”直接关联本应用唤醒导入。

  * **恢复冲突消解模式**：

    * **完整覆写模式（Full Restore）**：清空当前库，以备份文件为绝对基准全量还原。

    * **智能增量合并模式（Smart Merge）**：保留当前未修改数据，备份中同一日期若均存在内容，自动将备份的 Page 1\~N 转化为目标日期的后置拓展页（如 Page 2, Page 3），杜绝笔迹被覆盖。

  * **安全校验**：解压前执行哈希校验与版本号验证，杜绝损坏包破坏本地数据库。

#### 2. 多维度日历与 ICS 订阅系统

* **维度隔离**：支持建立独立的画板工作区（如 `工作/Studio`、`生活/Life`、`个人创作/Sketches`）。

* **订阅作用域**：支持订阅 `.ics` 网络日历源，规则可设定为“全局应用（所有日历可见）”或“仅绑定当前维度”。

* **非侵入式呈现**：严格遵守“主手绘享有绝对视觉焦点”原则，ICS 项以底部微型胶囊（Micro Pill）或彩色圆点呈现，日历格内手绘层占主视觉 85% 以上。

#### 3. 节假日与调休（班/休）系统

* **设计表现**：公历日期旁附带“休”（系统柔和红色/绿色微标）或“班”（中性灰微标）。

* **架构解耦**：当前阶段保留纯粹的协议抽象（`HolidayProviderProtocol`）与 UI 锚点，业务逻辑待后续通过动态更新配置注入。

#### 4. 每日多页画布与第一页唯一定位

* **形状绑定**：每日编辑器画布锁定为严格的 $1:1$ **正方形**（逻辑虚拟分辨率 $1400 \times 1400\text{pt}$）。

* **缩略图唯一定位**：每日支持创建无限多页（Page 1, Page 2...），但**月历网格永远且仅捕获并渲染 Page 1 作为该日期的封面缩略图**。

#### 5. 触控交互分流开关与命中判定规则 (Finger vs Pencil Input Mode)

顶部导航栏常驻触控模式切换按钮，严格区分手指与 Apple Pencil 的交互行为：

* **模式 A：手指书写关闭（Apple Pencil 独占模式，默认推荐）**：

  * **Apple Pencil 权能**：承担唯一的绘制、书写、擦除、套索路径选取职责。

  * **手指权能**：

    * 单指轻点（Single Tap）：直接选中贴图对象（进入图片编辑态并显示手柄与菜单），或点击已套索选区唤起快捷编辑菜单；

    * 单指/双指平移与缩放：控制整幅画布的平移漫游与无级缩放；

    * 彻底杜绝手掌与手指搭在屏幕上的误触误画（Palm Rejection 物理级隔离）。

* **模式 B：手指书写开启（全触控模式）**：

  * 手指与 Apple Pencil 享有同等绘制权能，在空白画布或非贴图区域，手指可自由落笔书写、使用橡皮擦除或拖拽套索圈选内容；

  * **图片交互绝对优先级（关键规则）**：**即使手指书写处于开启状态，当手指单点（Single Tap）命中已存在的图片/贴图时，严禁在该图片上留下任何笔迹，系统必须且仅能将其识别为“图片点选”行为，立即高亮该图片并唤起图片编辑菜单与控制手柄**；

  * 双指手势保留为画布平移与缩放。

#### 6. 跨图层统一套索（Unified Lasso）与智能选取规范

打破传统笔记应用“笔迹与贴图处于割裂世界”的痛点，构建可同时框选/多选矢量笔迹与图片的统一套索系统：

* **场景 1：套索框选【笔画 + 贴图】或【纯多笔画】（复合选区）**：

  * **视觉反馈**：系统在框选命中的所有图元最外层渲染一条**动态抗锯齿虚线轮廓（Bounding Marquee）**，紧密包围所选内容的外边界。

  * **一级浮动菜单**：在虚线框上方居中弹出系统级快捷操作栏：`[ 复制 | 剪切 | 删除 | 缩放变形 ]`。

  * **进入二级变形**：当用户点击 `缩放变形` 时，虚线框切换为带有 8 个控制手柄（Handle）的几何变换框，中心生成旋转锚点，允许用户对选区内的笔迹与贴图进行同步整体缩放与旋转变换。

* **场景 2：套索/单指点选【单张贴图或照片】（专属图片编辑态）**：

  * **触发机制**：无论手指绘制开关是否开启，单指直接点击图片或使用套索圈中单张图片均立即进入该状态。

  * **视觉反馈**：立即高亮显示图片专属编辑框，四角分布等比手柄，中点分布裁剪手柄，顶部带有独立旋转把手。

  * **专属功能手柄与菜单**：

    * **强制等比缩放**：拖拽四角圆点手柄默认强制锁定宽高比（$1:1$ 或原图比例）；

    * **无损裁剪（Crop）**：点击菜单中 `裁剪` 或拖拽四边把手，进入遮罩裁剪模式，图片二进制源数据保留，仅裁切显示视窗；

    * **自由位移与旋转**：按住中心区域单指拖动位移，拖拽顶部旋转手柄以 $1^\circ$ 步进旋转，并提供 $15^\circ / 45^\circ / 90^\circ$ 触觉震动吸附；

    * **快捷上下文菜单**：`[ 拷贝 | 裁剪 | 替换 | 图层顺序 (置顶/置底) | 删除 ]`。

#### 7. 贴图与相片入场管理

* **智能入场缩放**：

  * 尺寸均 $\le$ 画布尺寸：以 $1:1$ 原始物理像素居中放置。

  * 尺寸任意一边 $>$ 画布尺寸：基于 `Aspect Fit` 缩放至画布的 $90\%$ 安全区域内。

* **拍照即贴图**：系统相机拍摄后自动作为贴图对象执行上述入场与编辑流程。

## 二、 技术栈选型 (Technology Stack)

| **模块** | **选型** | **考量与架构优势** | 
| **开发语言** | **Swift 6** | 全面启用严格并发检查（Strict Concurrency），采用 `Actor` 隔离后台缩略图渲染与备份打包。 | 
| **UI 呈现架构** | **SwiftUI + UIKit (Hybrid)** | 主月历网格与外围容器采用 SwiftUI 响应式布局；$1:1$ 复合绘图板封装 UIKit，确保极致触控响应与手势低延迟。 | 
| **手写与绘图引擎** | **Apple PencilKit** | 官方低延迟笔迹渲染，通过拓展自定义选取层，实现与外部 UIView 贴图的数据联动。 | 
| **手势分流与统一套索** | **Custom Hit-Test + Geometry2D** | 采用自定义容器 `hitTest` 实现单点图片事件对 PencilKit 绘制事件的绝对截流；使用分离轴定理（SAT）计算套索闭合曲线与笔迹/贴图的几何求交。 | 
| **图像贴图与变换引擎** | **CoreGraphics + Metal** | 利用硬件加速完成贴图的矩阵变换（`CGAffineTransform`）、抗锯齿滤镜与实时遮罩裁剪。 | 
| **打包归档引擎** | **Apple Archive (System) / ZIPFoundation** | 高效流式读写 `.vcal` 容器，低内存占用压缩大体积位图与笔迹数据。 | 
| **持久化与数据存储** | **SwiftData + 文件系统沙盒** | SwiftData 管理元数据关系模型；二进制矢量文件与图片以独立文件存储于 Application Support 目录。 | 
| **缩略图多级缓存** | **NSCache + 磁盘 WebP 缓存** | 针对 LOD 3/2/1 实行分级缩放缓存，月历平滑滚动锁定 ProMotion 120fps。 | 

## 三、 核心技术架构与关键技术细节

### 3.1 复合画布图层与触控分流架构 (Touch Routing & Hit-Testing)

为了保证**无论手指绘制是否开启，手指单点图片均只进入编辑态而非产生涂鸦笔迹**，必须构建穿透层级的自定义 `Hit-Test` 拦截容器：

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Selection & Transform Overlay (顶层统一选择交互层)     │
│ - 承载动态虚线框 (CAShapeLayer)、8 向变换手柄、UIMenu 菜单锚点 │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: PKCanvasView (透明矢量手绘层)                       │
│ - backgroundColor = .clear                                  │
│ - 默认置于上层，负责捕获 Pencil 笔迹及空白区手指绘制            │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: ImageLayerContainerView (贴图与多媒体图元层)         │
│ - 管理多张自由变换的 ImageEntityView 实体                   │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Base Canvas Background (纸张底衬与 1:1 视口边界)     │
│ - 恒定 1400x1400 正方形底纸、网格参考线与裁剪遮罩            │
└─────────────────────────────────────────────────────────────┘

```

#### 1. 核心手势分流与贴图拦截容器实现 (CanvasTouchContainerView)

通过在画布顶层容器拦截 `hitTest(_:with:)`，在手指/Pencil 触摸发生的第一纳秒判断触控点是否命中贴图。若命中，则直接将触摸事件移交给贴图选择器，**短路（Bypass）`PKCanvasView` 的内部绘制手势**：

```
import UIKit
import PencilKit

public final class CompositeCanvasContainerView: UIView {
    public let canvasView = PKCanvasView()
    public let imageContainerView = UIView()
    public let selectionOverlay = SelectionOverlayView()
    
    public var isFingerDrawingEnabled: Bool = false {
        didSet {
            updateDrawingPolicy()
        }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupHierarchy()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupHierarchy() {
        addSubview(imageContainerView)
        addSubview(canvasView)
        addSubview(selectionOverlay)
        
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        updateDrawingPolicy()
    }
    
    private func updateDrawingPolicy() {
        if isFingerDrawingEnabled {
            canvasView.drawingPolicy = .anyInput
            canvasView.allowsFingerDrawing = true
        } else {
            canvasView.drawingPolicy = .pencilOnly
            canvasView.allowsFingerDrawing = false
        }
    }
    
    /// 核心触控仲裁：即使开启了手指书写，单点命中贴图也必须直接走贴图交互
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 1. 若当前处于选区编辑态（手柄、菜单等），优先由选区覆盖层捕获
        if selectionOverlay.isUserInteractionEnabled {
            if let overlayHit = selectionOverlay.hitTest(convert(point, to: selectionOverlay), with: event) {
                return overlayHit
            }
        }
        
        // 2. 判定该触控点是否命中任何贴图实体（逆序遍历确保顶层贴图优先）
        for subview in imageContainerView.subviews.reversed() {
            guard let imageView = subview as? ImageEntityView, !imageView.isHidden else { continue }
            let pointInImageView = convert(point, to: imageView)
            
            // 考虑变换后的非轴对齐多边形命中
            if imageView.containsRotatedPoint(pointInImageView) {
                // 关键拦截：直接返回贴图视图。
                // 此时系统将触控事件派发给贴图的手势处理器，PKCanvasView 不会接收到任何 Touch，彻底杜绝意外墨迹！
                return imageView
            }
        }
        
        // 3. 落点在空白区域，转交 PKCanvasView（受 isFingerDrawingEnabled 约束）
        return canvasView.hitTest(convert(point, to: canvasView), with: event)
    }
}

```

### 3.2 跨图层统一套索（Unified Lasso）求交与外轮廓计算算法

由于系统原生 `PKLassoTool` 仅作用于 `PKDrawing`，为了使贴图与笔划能被一次性共同圈选，必须构建统一选区仲裁引擎（Selection Arbiter）：

```
import UIKit
import PencilKit

public struct UnifiedSelectionPayload {
    public var selectedStrokes: [PKStroke] = []
    public var selectedImages: [UUID] = [] // 贴图实体的唯一标识
    public var combinedBoundingBox: CGRect = .null
}

public final class UnifiedLassoArbitrator {
    
    /// 当套索闭合路径生成后，执行跨图层几何相交判定
    public static func evaluateSelection(
        lassoPath: UIBezierPath,
        currentDrawing: PKDrawing,
        imageEntities: [ImageEntitySnapshot]
    ) -> UnifiedSelectionPayload {
        var payload = UnifiedSelectionPayload()
        let cgPath = lassoPath.cgPath
        
        // 1. 计算 PencilKit 笔迹相交
        for stroke in currentDrawing.strokes {
            // 快速粗筛：外接矩形相交
            if lassoPath.bounds.intersects(stroke.renderBounds) {
                // 细筛：采样笔迹贝塞尔点判断是否在套索多边形内
                let isContained = stroke.path.interpolatedPoints(by: .distance(10)).contains { point in
                    cgPath.contains(point.location)
                }
                if isContained {
                    payload.selectedStrokes.append(stroke)
                    payload.combinedBoundingBox = payload.combinedBoundingBox.union(stroke.renderBounds)
                }
            }
        }
        
        // 2. 计算贴图图元相交 (判定图片的四个角点或中心点是否在套索内)
        for imageItem in imageEntities {
            let itemFrame = imageItem.transformedFrame
            if lassoPath.bounds.intersects(itemFrame) {
                let centerPoint = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
                if cgPath.contains(centerPoint) || cgPath.contains(CGPoint(x: itemFrame.minX, y: itemFrame.minY)) {
                    payload.selectedImages.append(imageItem.id)
                    payload.combinedBoundingBox = payload.combinedBoundingBox.union(itemFrame)
                }
            }
        }
        
        return payload
    }
}

```

### 3.3 选区状态机与交互手柄控制器 (Selection Overlay State Machine)

选区图层根据选取的目标对象类型，自动在两种 UI 形态之间切换：

```
public enum SelectionVisualMode {
    /// 状态 A：纯笔画或【笔画 + 贴图】复合选区
    /// 呈现：紧贴内容的多边形/矩形虚线（Marching Ants），居中显示 [复制/剪切/删除/缩放] 菜单
    case compositeDashedOutline(bounds: CGRect)
    
    /// 状态 B：独立单张图片选中态（无论由单点触发还是单图套索触发）
    /// 呈现：8 向变形控制锚点、顶部旋转手柄、无损裁剪把手
    case singleImageTransformer(imageID: UUID, transformFrame: CGRect)
    
    /// 状态 C：复合选区点击“缩放变形”后的二级状态
    case compositeTransforming(bounds: CGRect)
}

public final class SelectionOverlayView: UIView {
    private var currentMode: SelectionVisualMode?
    private let dashedBorderLayer = CAShapeLayer()
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupLayers() {
        backgroundColor = .clear
        isUserInteractionEnabled = true
        
        dashedBorderLayer.strokeColor = UIColor.systemBlue.cgColor
        dashedBorderLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        dashedBorderLayer.lineWidth = 1.5
        dashedBorderLayer.lineDashPattern = [6, 4]
        layer.addSublayer(dashedBorderLayer)
    }
    
    public func update(with mode: SelectionVisualMode) {
        self.currentMode = mode
        subviews.forEach { $0.removeFromSuperview() } // 清空旧手柄
        
        switch mode {
        case .compositeDashedOutline(let bounds):
            dashedBorderLayer.isHidden = false
            dashedBorderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
            // 唤出 UIMenu: [复制 | 剪切 | 删除 | 缩放变形]
            showContextMenu(at: bounds, items: [.copy, .cut, .delete, .transform])
            
        case .singleImageTransformer(_, let frame):
            dashedBorderLayer.isHidden = true
            // 渲染专业图片控制把手：4 角（锁定等比）+ 4 边（裁剪）+ 顶部旋转柱
            attachImageHandles(for: frame)
            showContextMenu(at: frame, items: [.copy, .crop, .aspectRatioLock, .delete])
            
        case .compositeTransforming(let bounds):
            dashedBorderLayer.isHidden = false
            dashedBorderLayer.path = UIBezierPath(rect: bounds).cgPath
            // 显示整体变换锚点
            attachCompositeHandles(for: bounds)
        }
    }
    
    private func attachImageHandles(for rect: CGRect) {
        // 构建四角手柄（强制等比约束）与四边裁剪锚点
    }
    
    private func attachCompositeHandles(for rect: CGRect) {
        // 构建整体缩放与旋转锚点
    }
    
    private func showContextMenu(at targetRect: CGRect, items: [MenuActionType]) {
        // 调用 UIEditMenuInteraction 或 ContextMenu 弹出轻量操作栏
    }
}

public enum MenuActionType {
    case copy, cut, delete, transform, crop, aspectRatioLock
}

```

### 3.4 归档与备份系统架构规范 (Backup & Restore Pipeline)

#### 1. `.vcal` 容器内部文件系统规范

归档文件使用 ZIP 压缩标准，扩展名定义为 `.vcal`（Visual Calendar Archive）：

```
VisualCalendar_Backup.vcal (Container)
├── manifest.json              # 备份清单（版本号、导出时间、设备信息、哈希指纹）
├── database_dump.json         # 结构化数据（日历维度、日期关联项、ICS 配置、多页索引）
├── drawings/                  # PencilKit 矢量笔迹文件目录
│   ├── {page_uuid_1}.drawing  # PKDrawing.dataRepresentation() 生成的二进制文件
│   └── {page_uuid_2}.drawing
└── assets/                    # 贴图与外部相片静态资源
    ├── {image_uuid_1}.png
    └── {image_uuid_2}.png

```

#### 2. 异步流式备份管理器 (Backup Actor)

使用 Swift 6 `actor` 避免备份过程中主线程卡顿及读取与写入冲突：

```
import Foundation
import PencilKit
import ZIPFoundation

public actor BackupService {
    public static let shared = BackupService()
    private init() {}
    
    /// 执行完整备份并输出临时 .vcal 路径
    public func exportFullArchive(
        calendars: [CalendarMetadataDTO],
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        // 1. 写入 Manifest 清单
        let manifest = BackupManifest(
            schemaVersion: 2,
            appVersion: "2.2.0",
            exportDate: Date(),
            totalDrawingsCount: calendars.reduce(0) { $0 + $1.totalDrawingCount }
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        
        // 2. 导出元数据结构
        let dbData = try JSONEncoder().encode(calendars)
        try dbData.write(to: tempDir.appendingPathComponent("database_dump.json"))
        
        // 3. 组织 drawings 与 assets 文件夹
        let drawingsDir = tempDir.appendingPathComponent("drawings")
        let assetsDir = tempDir.appendingPathComponent("assets")
        try fileManager.createDirectory(at: drawingsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        
        // 4. 流式写入与打包（避免全量数据占满内存）
        let finalArchiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("VisualCalendar_\(Date().formatted(.iso8601)).vcal")
        
        try fileManager.zipItem(at: tempDir, to: finalArchiveURL, shouldKeepParent: false)
        return finalArchiveURL
    }
}

```

### 3.5 1:1 响应式布局与动态 LOD 渲染算法

#### 1. 月历单格自适应 LOD 视图 (SwiftUI)

根据父容器传入的实际宽高尺寸，动态降级/升级渲染组件：

```
import SwiftUI

public enum CellLODTier {
    case lod3Full       // 宽度 >= 120: 显示缩略图 + 日期 + 班休 + 详细日程胶囊
    case lod2Compact    // 70 <= 宽度 < 120: 显示缩略图 + 日期 + 班休 + ICS 纯圆点
    case lod1Minimal    // 宽度 < 70: 极微模式，仅显示缩略图轮廓与日期
    
    public static func resolve(for width: CGFloat) -> CellLODTier {
        if width >= 120 { return .lod3Full }
        if width >= 70  { return .lod2Compact }
        return .lod1Minimal
    }
}

public struct ResponsiveDayCellView: View {
    let date: Date
    let holidayStatus: WorkRestStatus
    let thumbnailImage: UIImage?
    let icsEvents: [MicroEvent]
    let pageCount: Int
    
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tier = CellLODTier.resolve(for: size.width)
            
            ZStack(alignment: .topLeading) {
                // 1. 底层：1:1 缩略图（严禁拉伸变形）
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Color(.secondarySystemBackground)
                }
                
                // 2. 顶栏：日期、班休与多页徽标
                HStack(spacing: tier == .lod1Minimal ? 1 : 3) {
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.system(
                            size: tier == .lod1Minimal ? 10 : 13,
                            weight: .semibold,
                            design: .rounded
                        ))
                    
                    if holidayStatus != .normal && tier != .lod1Minimal {
                        Text(holidayStatus.rawValue)
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 2)
                            .background(holidayStatus == .rest ? Color.red.opacity(0.85) : Color.gray.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    
                    Spacer(minLength: 0)
                    
                    if pageCount > 1 && tier == .lod3Full {
                        Text("+\(pageCount - 1)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(tier == .lod1Minimal ? 2 : 4)
                
                // 3. 底部：分级 ICS 渲染
                renderICSOverlay(for: tier)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .aspectRatio(1.0, contentMode: .fit) // 强制约束单元格外廓为严格 1:1
    }
    
    @ViewBuilder
    private func renderICSOverlay(for tier: CellLODTier) -> some View {
        VStack {
            Spacer()
            switch tier {
            case .lod3Full:
                // LOD 3: 微型半透明文本气泡胶囊
                if !icsEvents.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(icsEvents.prefix(2)) { event in
                            HStack(spacing: 2) {
                                Circle().fill(Color(hex: event.colorHex) ?? .blue).frame(width: 4, height: 4)
                                Text(event.title)
                                    .font(.system(size: 7))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity)
                }
                
            case .lod2Compact:
                // LOD 2: 仅显示极小实心彩点
                if !icsEvents.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(icsEvents.prefix(3)) { event in
                            Circle()
                                .fill(Color(hex: event.colorHex) ?? .blue)
                                .frame(width: 3.5, height: 3.5)
                        }
                    }
                    .padding(2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity)
                }
                
            case .lod1Minimal:
                // LOD 1: 单指示微点
                if !icsEvents.isEmpty {
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2.5, height: 2.5)
                        .padding(.bottom, 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

```

### 3.6 第一页（Page 1）缩略图确定性离线合成流水线

当用户编辑完退出或触发自动保存时，通过 CoreGraphics 离线合成高保真缩略图：

```
@MainActor
public final class DailyThumbnailPipeline {
    /// 渲染并输出 1:1 正方形缩略图
    public static func renderPage1Thumbnail(
        canvasSize: CGSize = CGSize(width: 1400, height: 1400),
        targetThumbnailWidth: CGFloat = 300,
        drawing: PKDrawing,
        imageComponents: [ImageEntitySnapshot]
    ) -> UIImage {
        let renderFormat = UIGraphicsImageRendererFormat()
        renderFormat.scale = 2.0 // 确保 Retina 清晰度
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetThumbnailWidth, height: targetThumbnailWidth),
            format: renderFormat
        )
        
        let targetScale = targetThumbnailWidth / canvasSize.width
        
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.scaleBy(x: targetScale, y: targetScale)
            
            // 1. 绘制中层贴图与照片
            for item in imageComponents {
                cgContext.saveGState()
                cgContext.concatenate(item.affineTransform)
                if let clipRect = item.cropRect {
                    cgContext.clip(to: clipRect)
                }
                item.image.draw(in: CGRect(origin: .zero, size: item.originalSize))
                cgContext.restoreGState()
            }
            
            // 2. 绘制顶层 PencilKit 笔迹
            let pkImage = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 1.0)
            pkImage.draw(in: CGRect(origin: .zero, size: canvasSize))
        }
    }
}

```

### 3.7 节假日与班/休数据协议预留规范

```
import Foundation

public enum WorkRestStatus: String, Codable, Sendable {
    case work = "班"
    case rest = "休"
    case normal = ""
}

public protocol HolidayProviderProtocol: Sendable {
    func fetchHolidaySchedule(year: Int, month: Int) async throws -> [Date: WorkRestStatus]
    func queryStatus(for date: Date) -> WorkRestStatus
}

// 占位解耦实现：暂无远端逻辑，返回空状态，随时可注入远程 API
public final class DeferredHolidayManager: HolidayProviderProtocol {
    public static let shared = DeferredHolidayManager()
    private init() {}
    
    public func fetchHolidaySchedule(year: Int, month: Int) async throws -> [Date: WorkRestStatus] {
        return [:]
    }
    
    public func queryStatus(for date: Date) -> WorkRestStatus {
        return .normal
    }
}

```

## 四、 实施难点与工程保障方案

1. **手指绘制开启状态下图片单点事件的防涂抹击穿**：

   * *难点*：当 `canvasView.drawingPolicy = .anyInput` 时，手指一触碰屏幕，`PKCanvasView` 的内置私有绘制手势就会在极短延迟内（约 $8\text{ms}$）在屏幕上画出点或小尾巴，此时若落点恰好在贴图上，会造成“一边选中贴图，一边在贴图上画了污点”。

   * *方案*：利用 `CompositeCanvasContainerView` 的 `hitTest(_:with:)` 机制，在事件向子视图分发前，主动判定落点是否处于任一贴图的多边形外框内。若命中贴图，直接返回贴图视图或选择图层，**使 `PKCanvasView` 完全接收不到这次触控的 `touchesBegan`**，从系统底座层面彻底杜绝误画。

2. **多笔画 + 贴图混合选区实时几何求交性能损耗**：

   * *难点*：当单页笔记积累上千条笔画时，套索闭合后逐点遍历做多边形相交判定会导致主线程掉帧。

   * *方案*：先用 `CGRect.intersects` 进行 AABB 包围盒快速排查，对命中的候选笔划建立 R-Tree 空间索引，将多边形点判定耗时控制在 $16\text{ms}$ 以内，保障流畅弹出菜单。

3. **正方形网格在极端分屏下的触控目标问题**：

   * *难点*：在 iPad 最小 $1/3$ 宽度分屏（Slide Over，宽度约 $320\text{pt}$）时，7 列矩阵单格宽度仅约 $45\text{pt}$，容易引发触控误点。

   * *方案*：应用动态增大触控热区（`contentShape` 扩展），点击时弹出气泡放大镜（Popover Preview），双击快速进入全屏编辑，防止误触。

4. **多页笔迹与大体积贴图归档导出时的内存溢出 (OOM)**：

   * *难点*：一年积累的画作与相片可能膨胀至数个 GB，若一次性读入内存打包必将发生崩溃。

   * *方案*：`BackupService` 采用流式文件写入（Chunked Streaming），按月分批将磁盘文件加入压缩流，内存常驻上限严格控制在 $50\text{MB}$ 以内。