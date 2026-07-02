# MaciPhotoAlbum — CLAUDE.md

## 项目概述

**macOS** App，名称 **MaciPhotoAlbum**。通过数据线读取已连接 iPhone（或其它相机设备）相册中的照片和视频，以拍摄日期分栏展示，支持全屏预览、多选、拖拽选择、缩略图缩放、右键复制、导出到 Mac、按天/按当天总大小排序、批量删除、预览内单张删除。

- **开发者**：Yingzhuo Huang
- **创建日期**：2026/3/21
- **平台**：macOS，SwiftUI + **ImageCaptureCore**（`ICDeviceBrowser` / `ICCameraDevice` / `ICCameraFile`）+ AVKit
- **开发环境**：macOS 14 + Xcode 15
- **部署目标**：`MACOSX_DEPLOYMENT_TARGET = 14.0`，`SDKROOT = macosx`
- **重要**：不是 PhotoKit。读取的是“连接的外部相机设备”，删除直接作用于 iPhone 上的原始文件，无系统“最近删除”兜底——删除前务必确认设备已解锁。

---

## 文件结构

```
MaciPhotoAlbum/
├── MaciPhotoAlbumApp.swift        # App 入口 (@main)，WindowGroup
├── ContentView.swift              # 主界面 & 所有子 View
├── PhotoLibraryViewModel.swift    # 业务逻辑 & ImageCaptureCore 数据层
└── Assets.xcassets/               # 图标等资源
```

---

## 项目配置（重要）

- `GENERATE_INFOPLIST_FILE = YES`——无手写 Info.plist，键值通过 `INFOPLIST_KEY_*` 注入。
- **未启用 App Sandbox**，无 `.entitlements` 文件。ImageCaptureCore 访问 USB 设备在非沙盒下可直接工作；若后续开启沙盒，需添加相应 entitlement，否则设备枚举会失败。
- `LSApplicationCategoryType = public.app-category.photography`。

---

## 构建

命令行构建(`xcode-select` 已指向 `/Applications/Xcode.app`,直接用即可)：

```
cd /Users/huang/Documents/Xcode/MaciPhotoAlbum
xcodebuild -project MaciPhotoAlbum.xcodeproj -scheme MaciPhotoAlbum -destination 'platform=macOS' build
```

- 若 `xcode-select -p` 指回了 Command Line Tools，临时绕过(无需改全局)：
  在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 成功标志：输出末尾 `** BUILD SUCCEEDED **`。

---

## 架构

### 数据层：`PhotoLibraryViewModel`

`@MainActor final class`，继承 `NSObject`，`ObservableObject`。同时实现
`ICDeviceBrowserDelegate` 与 `ICCameraDeviceDelegate`（delegate 回调均为
`nonisolated`，内部用 `Task { @MainActor }` 切回主线程）。

职责：

- **设备发现**：`ICDeviceBrowser`，`browsedDeviceTypeMask` = camera + local，
  `start()` 启动浏览，`didAdd/didRemove` 维护 `cameraByID`。
- **会话管理**：选中设备后 `requestOpenSession`（带
  `.enumerationChronologicalOrder`）。`deinit` 中关闭 session 与 browser。
- **资产模型**：
  - `DaySection`：`{ date: Date, assetIDs: [String] }`，以 `startOfDay` 为 key。
  - `CameraDeviceSummary`：侧栏设备行的展示模型（名称/型号/锁定/读取进度/数量）。
  - `MediaKind`：`image / video / other`。
  - `AssetSortOrder`：**天与天之间**的排序方式——`date`（拍摄日期，新→旧，默认）/
    `daySizeDescending`（当天总大小大→小）/ `daySizeAscending`（小→大）。
  - `AssetRow`（typealias）：`(id, date, size)`，分组/排序用的精简行，全部取自内存。
  - 资产 ID = `itemID(for:)`：优先 `originatingAssetID`，否则用
    `ptpObjectHandle + 文件名 + 大小 + 时间戳` 组合（无 PHAsset.localIdentifier）。
  - 媒体对象为 `ICCameraFile`，存于 `itemByID`。
- **分组 / 排序**：`rebuildSections(from:)` 过滤受支持媒体（image/video），按拍摄
  日期（`exifCreationDate → fileCreationDate → creationDate → modificationDate`）
  分天。**每天内部恒按拍摄时间降序、同时间按 ID 降序**（`timeOrderedIDs`），
  不受排序选项影响；**天与天之间**由 `sortedSections(_:)` 按 `sortOrder` 排。
  `setSortOrder(_:)` 只重排已有 sections（每天内容不动），用缓存 `fileSize`
  求和、每天只算一次，无设备访问、瞬时生效。
- **总大小**：`totalSizeText(for:)` 对任意一组 ID 累加 `fileSize`（纯内存）；
  `selectedSizeText` 复用之；section 头显示当天总大小，`daySize(_:)` 供排序用。
- **缩略图**：`item.requestThumbnailData(options:)` 按目标像素请求，缓存
  `thumbnailByID`；也接收 delegate 推送的 `didReceiveThumbnail`。
- **预览 / 下载**：`item.requestDownload(options:)` 下载到
  `temporaryDirectory/MaciPhotoAlbumPreview/`，返回本地 URL 缓存于
  `previewURLByID`。图片用 `NSImage(contentsOf:)`，视频用 `AVPlayer(url:)`。
- **导出**：`exportSelected(to:)` 逐个 `requestDownload` 串行下载到用户选定目录
  （避免并发压垮设备），保留原名、冲突加数字后缀（`uniqueFilename`），
  `isExporting` / `exportProgress` 驱动进度。
- **复制**：`copyAsset(id:)` 先下载原文件，再写 `NSPasteboard.general`——
  图片写「图像内容 + 文件 URL」，视频只写文件 URL。
- **选择状态**：`Set<String> selectedAssetIDs`，单选/批量/全天选择。
- **删除**：核心 `deleteAssets(_:)` 调 `camera.requestDeleteFiles(_:)`，按
  `result[.successful]` 从选择集移除、完成后 `rebuildSections`；`deleteSelected`
  是它对当前选中集的封装，预览里单张删除也走它。能力检查 `canDeleteFromDevice`
  （设备存在/未锁定/未受限/未在删除中/含删除能力），`canDelete = 有选中 &&
  canDeleteFromDevice`。
- **状态文本**：`statusText` 驱动侧栏底部与空态提示。
- **[临时] 实况照片诊断**：`#if DEBUG` 下 `logLivePhotoDiagnostics(camera:)`
  用 `NSLog`（前缀 `LIVEPHOTO-DIAG`）打印文件与 `originatingAssetID` 配对信号，
  用于评估实况照片支持；策略定了即删。

### 视图层：`ContentView.swift`

所有 View 均在此文件内（private structs）：

| 组件 | 说明 |
|------|------|
| `ContentView` | 根视图，`NavigationSplitView`（侧栏设备列表 + detail 日期网格），含 toolbar、导出/删除弹窗、缩放档位、拖拽多选 |
| `AssetThumbnailView` | 缩略图格子，含选中圆圈、文件名、媒体标签、视频角标、右键「复制」菜单 |
| `AssetPreviewSheet` | `sheet` 弹出的预览窗，loading/image/video/failed 四态；头部含上一张/下一张、缩放、删除、关闭；右键「复制」 |
| `CenteredZoomablePreviewImage` | 预览大图的可缩放/居中滚动容器 |
| `StableVideoPlayer` | 包裹 `AVPlayerView` 的 `NSViewRepresentable`，切换 URL 时复用 |

辅助类型：`DragSelectionMode` / `DragAxisLock` / `AssetFramePreferenceKey`
（PreferenceKey 收集每格 rect 用于拖拽命中）/ `PreviewRequest`（Identifiable）。

---

## 核心功能

### 布局

- `NavigationSplitView`：左侧 `List` 显示已连接设备（图标区分锁定态），
  右侧为日期分栏的 `LazyVGrid`（`GridItem(.adaptive(minimum:112,maximum:170))`）。
- 三种 detail 状态：未选设备 → `emptyDeviceView`；无媒体 → `emptyMediaView`；
  有数据 → `photoGrid`。
- toolbar：principal 处为标题按钮（点击滚到顶部）；右侧一组按选中态变化——
  最左「取消」（仅有选中时出现，特意远离删除避免误触）、刷新、**排序** `Menu`
  （拍摄日期 / 当天总大小大→小 / 小→大，勾选当前项）、缩小/放大、
  「已选 N 项 · 大小」、导出（`canExport`）、删除（带计数，`canDelete`）。

### 交互

- **点击缩略图主体** → `sheet` 全屏预览（`previewRequest`）。
- **点击右上角圆圈** → 切换选中。
- **水平拖拽** → 拖拽多选（横向位移 > 纵向时触发）。
- **右键缩略图 / 预览大图** → 「复制」到剪贴板（`copyAsset`）。
- **缩略图缩放**：`gridZoomIndex` 选档（`gridZoomScales`），改 `GridItem` 的
  min/max 宽度。

### 拖拽多选

- `DragGesture(minimumDistance:12, coordinateSpace:.named("mediaScrollSpace"))`。
- `dragAxisLock` 锁定轴向，避免同一手势中途切方向；仅横向触发选择。
- 首个命中格决定本次是 `.select` 还是 `.deselect`，`dragVisitedAssetIDs` 去重。
- `AssetFramePreferenceKey` 收集每格 rect，`assetID(at:)` 做命中检测。
- **快速拖拽不漏选**：`onChanged` 稀疏触发，故沿「上一点 → 当前点」线段每 8pt
  插值采样（`assetIDs(along:to:)` + `lastDragLocation`），把扫过的格子逐个命中，
  不再因光标跳过而漏。

### 按天分组

- 标题格式：`yyyy年M月d日 EEEE`（中文，Gregorian 历），后跟「N 项 · 当天总大小」。
- 每个 section 右侧有“全选当天 / 取消当天”按钮。
- 天顺序由 toolbar 排序菜单控制；每天内部恒按拍摄时间。

### 预览（`AssetPreviewSheet`）

- 通过 `requestPreviewURL` 下载原文件到临时目录后展示。
- 图片：`NSImage` + 可缩放（`zoomLevels`，`CenteredZoomablePreviewImage`）。
- 视频：`StableVideoPlayer`（`AVPlayerView`），出现即播放。
- 头部：文件名、媒体标签、分辨率（`dimensionsText`）、上一张/下一张（←/→）、
  缩放（+/−）、**删除**（在关闭左侧，`canDeleteFromDevice` 约束，二次确认）、关闭。
- 删除当前项后自动跳下一张（无则上一张，都没有则关闭）。
- 右键「复制」当前项。

---

## 删除流程（重要）

1. **批量**：选中项 > 0 时 toolbar 出现“删除(N)”。**单张**：预览头部「删除」。
2. `confirmationDialog` 二次确认，文案提示“直接从设备移除，无法恢复，需 iPhone 已解锁”。
3. 两者都走 `deleteAssets(_:)` → `requestDeleteFiles`，按结果字典区分
   `.successful` / `.failed`。
4. 失败时 `alert("删除失败")` 显示 `statusText`。
5. **无系统回收站**——删除不可撤销（真正的 iOS「最近删除」属 PhotoKit，
   PTP/ImageCaptureCore 接口无法触及，做不到）。

`canDeleteFromDevice`：未在删除中、设备存在、未锁定、未受访问限制、且设备
capabilities 含删除能力。`canDelete` 再叠加「有选中」。

---

## 语言混用规则

- **中文 UI**：取消、刷新、排序（拍摄日期/当天总大小…）、缩小、放大、导出、
  删除、复制、全选当天、取消当天、视频、加载失败、设备、各类状态/错误文案。
- **英文 UI**：导航标题 "MaciPhotoAlbum"、`ContentUnavailableView` 内容
  （"No iPhone connected" / "No media found" 及其说明）。
- **错误弹窗**：“删除失败” / “导出完成” / “好的”。

---

## 性能与约定

- 缩略图按格子实际像素尺寸请求（`targetPixelSize`，随 backingScaleFactor 计算，
  变化 ≥12pt 才重算），最小 160px。
- 预览/原图按需下载到临时目录并缓存 URL，重复打开复用。
- delegate 回调全部 `nonisolated` + `Task { @MainActor }`，状态变更只在主线程。
- `rebuildSections` 时清理 `itemByID` 之外的孤立缓存（缩略图、预览 URL、选择集）。

---

## 已知限制 / 待办

- 视频预览音频未单独配置（沿用系统默认），一般 Mac 上有声音。
- 仅支持 image/video，其它类型（如 RAW sidecar、文档）被过滤。
- **实况照片**未做配对：静态图与 MOV 目前各显示为独立一项，未识别成一张
  Live Photo（调研中，见数据层「临时实况照片诊断」）。
- 复制大文件（尤其视频）需先从设备下载，有几秒延迟；剪贴板不含「实况」语义。
- 导出为串行下载，大量选中时较慢（换取设备稳定）。
- 多设备并发未充分测试；同一时刻聚焦单一选中设备。
