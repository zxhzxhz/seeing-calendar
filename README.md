# 看见Calendar · SeeingCalendar

面向 **iPadOS 18+ / iPad Pro (M4) 及以上**的「视觉手绘日历」应用。
以 **Apple Pencil First 的无模板自由手绘**为核心创作方式，以 **1:1 正方形网格缩略图联动**为视觉载体，
实现「画即所得 · 日记即日程 · 月历即画廊」的自动化闭环。

工程严格按 `visual_calendar_product_tech_spec.md`（v2.2）落地，并通过 GitHub Actions 在 macOS runner 上编译出
**未签名 .ipa**（用 `gh run download` 取回）。

---

## 1. 快速开始（本机 = Windows，构建走 CI）

```bash
# 1. 触发构建
gh workflow run "iOS Build (unsigned)" --ref main
# 或直接 push（workflow 已在 push: main 上自动触发）

# 2. 等待并查看
gh run list --limit 5
gh run watch $(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')

# 3. 下载 artifacts（未签名 ipa + dSYM + 构建日志）
gh run download $(gh run list --limit 1 --json databaseId --jq '.[0].databaseId') -D ./artifacts
ls -lh ./artifacts/SeeingCalendar-unsigned-ipa/
```

拿到 `SeeingCalendar-unsigned.ipa` 后，使用 AltStore / SideStow / Sideloadly / Xcode（`ios-deploy`）等工具
自行签名安装到 iPad（免费 Apple ID 亦可，7 天有效期）。

## 2. 工程结构

```
project.yml                     # XcodeGen 工程定义（CI 里 xcodegen generate 出 .xcodeproj）
SupportFiles/Info.plist          # 由 XcodeGen 生成（UTI / 文档类型 / 权限文案）
scripts/make_app_icon.py         # 纯 numpy+zlib 生成 1024 图标（无需 Pillow）
scripts/swift_lint.py            # 轻量 Swift 机械体检（括号平衡 / 重复声明）
.github/workflows/ios-build.yml  # macOS runner 编译 + 打包未签名 ipa + 上传 artifacts
SeeingCalendar/
├── App/                 # 入口、数据栈、路径规划、日历计算
├── Models/              # SwiftData 模型 + 值类型（日历事件 / 班休状态）
├── Store/               # 仓储层：SQLite 元数据 ↔ 文件系统二进制；ZIP 归档；备份/恢复
├── ICS/                 # RFC5545 子集解析器 + 订阅聚合索引
├── Canvas/              # ★ 复合画布：触控分流 / 统一套索 / 选区状态机 / 变换手柄
├── Rendering/           # Page1 缩略图确定性离线合成
└── Views/               # SwiftUI 外壳：月历 LOD 网格 / 编辑器 / 抽屉 / 订阅 / 备份
```

## 3. 核心架构要点

### 3.1 五层复合画布与触控仲裁（spec 3.1）

```
Layer 5  SelectionOverlayView       虚线框 / 8 向手柄 / 旋转锚点 / 原生菜单 / 套索捕获
Layer 4  SelectionContentContainer  浮动选区（被取出的笔迹位图预览）
Layer 3  ImageFrontContainerView    置于「笔迹之上」的贴图（置顶后进入）
Layer 2  PKCanvasView               透明矢量手绘层（drawingPolicy 受“手指书写”开关控制）
Layer 1  ImageLayerContainerView    笔迹之下的自由变换贴图（无损裁剪：只改 contentsRect）
Layer 0  PaperBackgroundView        恒定 1400×1400 正方底纸 + 网格参考线
```

`zIndex` 用一个整型同时编码层内序号与前后层归属（`zIndex >= 10000` 即位于笔迹之上），
“置顶 / 置底”因此可以真正跨越手绘层，而无需为一次排序引入 schema 变更。

`CompositeCanvasContainerView.hitTest(_:with:)` 在事件分发第一纳秒内做三件事：

1. 选区覆盖层（手柄/菜单/套索）优先命中；
2. 逆序判定落点是否落在任一贴图的多边形外框内 —— **命中即返回贴图视图**，
   `PKCanvasView` 完全收不到这次 `touchesBegan`，从底座杜绝“手指绘制开启时在照片上留下污点”；
3. 空白区域才转交 PencilKit。

### 3.2 跨图层统一套索（spec 3.2）

* 自绘套索（不依赖 `PKLassoTool` 的私有选区），闭合路径后交给 `UnifiedLassoArbitrator`：
  AABB 粗筛 → 笔迹采样点射线法细筛 → 贴图四角/中心判定；
* 命中笔迹会**从画布中取出**成为「浮动选区」（`floatingPreview`），
  变换时只改预览视图的 `transform`（视觉预览零成本），手势结束才把 delta 烧进贝塞尔控制点并同步缩放线宽；
* 复合选区（笔迹 + 贴图）支持 8 向整体缩放与旋转，单张贴图另有 4 角等比 / 4 边裁剪 / 顶部旋转手柄。

### 3.3 1:1 适应与动态 LOD（spec 1.2 / 3.5）

月历恒为 7×6 固定矩阵，单元格 = `min(横向可用宽, 纵向可用高)`，天然保证 1:1；
按实际渲染宽度切换 LOD3（≥120pt 全量级）/ LOD2（≥70pt 紧凑级）/ LOD1（<70pt 极小级），
ICS 日程相应降级为微胶囊 → 彩点 → 单微点，手绘始终占据 ≥85% 视觉焦点。

### 3.4 归档闭环（spec 3.4）

`.vcal` = ZIP 容器：`manifest.json` + `database_dump.json` + `drawings/*.drawing` + `assets/*`。

* 写入：STORE 模式流式落盘（贴图本身已是压缩码流，避免二次压缩的 CPU/内存开销），内存驻留恒定为一个 chunk；
* 读取：以中央目录为唯一索引，兼容 STORE / Deflate（含数据描述符），逐条目 CRC32 校验 + 清单指纹比对；
* 恢复：**完整覆写** 与 **智能增量合并**（同日冲突时把备份画页转为后置拓展页，绝不覆盖现有笔迹）。

### 3.5 Swift 6 严格并发

全部 UI / SwiftData / PencilKit 状态锚定 `@MainActor`；网络解析与缩略图合成走 `Task.detached` + Sendable 值类型；
备份打包为独立 `actor`；跨隔离域一律降维为纯值 DTO（`SubscriptionSnapshot` / `ThumbnailImageSpec` / `RestoreBundle`）。

## 4. 已实现的功能清单

| 模块 | 状态 |
| :--- | :--- |
| 1:1 月历矩阵 + 三级 LOD + 今日/选中/周末/非本月态 | ✅ |
| 单日编辑器：严格 1:1 画布（1400×1400）+ 无限多页 + Page 1 唯一定位封面 | ✅ |
| 触控分流（模式 A Pencil 独占 / 模式 B 全触控）+ 贴图绝对优先级 | ✅ |
| 统一套索（笔迹 + 贴图）+ 复合选区整体缩放/旋转 + 8 向手柄 | ✅ |
| 单张贴图：等比四角 / 无损裁剪四边 / 顶部旋转（1° 步进 + 15/45/90° 吸附触觉） | ✅ |
| 贴图入场智能缩放（1:1 居中 / Aspect Fit 90% 安全区）、拷贝/替换/置顶/置底/删除 | ✅ |
| 倒带历史（30 步：笔迹 + 贴图状态统一快照） | ✅ |
| ICS 订阅（RFC5545 子集 + RRULE 展开 + 多选维度作用域 + 彩点/胶囊降级呈现） | ✅ |
| 节假日班/休：`HolidayProviderProtocol` 协议抽象 + 注入点 + UI 锚点 | ✅（数据待注入） |
| `.vcal` 完整备份 / 定时快照（保留 3 份）/ 双模式恢复 / CRC + 指纹校验 | ✅ |
| 竖屏动态扩展区：日程时间轴 + 多页轮播 + 便签快捷记录 | ✅ |
| 多维度工作区（工作/生活/个人创作…）隔离 | ✅ |

## 5. 已知取舍（第一性原理下的显式决策）

1. **画布缩放**：全图层共用同一世界坐标系的外层 `UIScrollView`（保证套索/贴图/笔迹几何永不错位）。
   笔迹为 PencilKit 1:1 渲染，放大超过 100% 时由 GPU 采样纹理，属正常的位图放大表现；
   如需原生级锐度可改用 `PKCanvasView` 自带 zoom + 逐帧同步贴图层变换（复杂度显著上升）。
2. **`.vcal` 写入不压缩**：贴图与照片已是压缩格式，二次压缩收益 <5% 却带来 CPU 与内存成本；
   读取侧完整支持外部工具产生的 Deflate 归档。
3. **归档单档 <4GB**：未实现 ZIP64（超大素材库请分批备份），遇到 ZIP64 会给出明确错误而不是静默损坏。
4. **ICS**：覆盖 `DAILY/WEEKLY(+BYDAY)/MONTHLY/YEARLY` + `INTERVAL/COUNT/UNTIL/EXDATE`；
   `BYSETPOS` 等复杂规则退化为首次发生，不做过度工程。
5. **未签名 ipa**：CI 无证书，构建时显式 `CODE_SIGNING_ALLOWED=NO`，交付物需自行签名安装。
6. **极小格触控**：Slide Over（1/3 分屏）下 LOD1 单格约 45pt，目前依靠整格 `contentShape` 热区 + 双击进全屏编辑；
   spec 4.3 建议的气泡放大镜（Popover Preview）未实现，避免引入额外的预览合成开销。
7. **节假日班/休**：`HolidayProviderProtocol` 协议抽象 + `HolidayRegistry` 注入点 + UI 锚点；
   自 1.0.17 起另有两条**随包发行**的内置凭据（`holidayCal-HO` 放假 / `holidayCal-CO` 调休，覆盖 2022–2026），
   默认开启、固定置底且不可删除（不要用请关开关），冷启动零网络即可正确着色。
8. **订阅作用域**：**空作用域 = 全局**，「全局」行与维度行互斥。
   这个约定让几件事同时变简单：老库升级（旧单选字段迁移为空即全局）、
   从旧备份恢复（缺键按全局）、维度被删除时摘空引用（回到全局而不是静默消失）。
   代价是「一个维度都不选」与「全局」在模型上是同一个状态 —— 靠界面上「全局」行是否亮起表达，不靠文案解释。

## 7. 验证手段（无 macOS 设备下的可验证性边界）

| 环节 | 手段 | 结果 |
| :--- | :--- | :--- |
| 编译 / 链接 / 打包 | GitHub Actions macOS runner + `xcodebuild`（Release, iOS SDK） | ✅ 0 error 0 warning |
| 产物结构 | `zipfile` + `plistlib` 解包 ipa 校验 UTI / 方向 / 权限文案 / Bundle ID | ✅ 见 `artifacts/` |
| `.vcal` 容器格式 | `scripts/verify_vcal_layout.py` 按 Swift 写入布局重建 → 标准 ZIP 读取器解析 | ✅ 通过 |
| Swift 机械体检 | `scripts/swift_lint.py`（括号平衡 / 重复声明 / 已知陷阱） | ✅ 通过 |
| 行为门禁（CI `--strict`） | `verify_transform_math` 225 条 · `verify_holiday_table` 25 条 · `verify_thumbnail_lifecycle` 83 条 · `verify_ui_regressions` 91 条 · `verify_subscription_management` 91 条 | ✅ 全部通过 |
| 门禁自身的笔误 | `scripts/gate_preflight.py`（接收变量是否越界 / 断言字面量是否真能在目标文件里找到） | ✅ 通过 |
| 运行时行为（手势 / PencilKit / SwiftData） | **需真机** | ⚠️ 待上机验收 |

## 6. 本地（macOS）直接构建

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project SeeingCalendar.xcodeproj -scheme SeeingCalendar \
  -configuration Release -destination 'generic/platform=iOS' build
```
