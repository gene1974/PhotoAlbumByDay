# MaciPhotoAlbum — CLAUDE.md

## 项目概述

**macOS** App，名称 **MaciPhotoAlbum**。通过数据线读取已连接 iPhone（或其它相机设备）相册中的照片和视频，以拍摄日期分栏展示，支持全屏预览、多选、拖拽选择、批量删除。

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
  - 资产 ID = `itemID(for:)`：优先 `originatingAssetID`，否则用
    `ptpObjectHandle + 文件名 + 大小 + 时间戳` 组合（无 PHAsset.localIdentifier）。
  - 媒体对象为 `ICCameraFile`，存于 `itemByID`。
- **分组**：`rebuildSections(from:)` 过滤受支持媒体（image/video），按拍摄日期
  （`exifCreationDate → fileCreationDate → creationDate → modificationDate`）
  分天，section 按日期降序，section 内按时间降序、同时间按 ID 降序。
- **缩略图**：`item.requestThumbnailData(options:)` 按目标像素请求，缓存
  `thumbnailByID`；也接收 delegate 推送的 `didReceiveThumbnail`。
- **预览**：`item.requestDownload(options:)` 下载到
  `temporaryDirectory/MaciPhotoAlbumPreview/`，返回本地 URL 缓存于
  `previewURLByID`。图片用 `NSImage(contentsOf:)`，视频用 `AVPlayer(url:)`。
- **选择状态**：`Set<String> selectedAssetIDs`，单选/批量/全天选择。
- **删除**：`camera.requestDeleteFiles(_:)`，按 `result[.successful]` 从选择集
  移除，完成后 `rebuildSections`。需设备具备
  `cameraDeviceCanDeleteOneFile/AllFiles` 能力（见 `canDelete`）。
- **状态文本**：`statusText` 驱动侧栏底部与空态提示。

### 视图层：`ContentView.swift`

所有 View 均在此文件内（private structs）：

| 组件 | 说明 |
|------|------|
| `ContentView` | 根视图，`NavigationSplitView`（侧栏设备列表 + detail 日期网格） |
| `AssetThumbnailView` | 缩略图格子，含选中圆圈、文件名、媒体标签、视频角标 |
| `AssetPreviewSheet` | `sheet` 弹出的预览窗，loading/image/video/failed 四态 |

辅助类型：`DragSelectionMode` / `DragAxisLock` / `AssetFramePreferenceKey`
（PreferenceKey 收集每格 rect 用于拖拽命中）/ `PreviewRequest`（Identifiable）。

---

## 核心功能

### 布局

- `NavigationSplitView`：左侧 `List` 显示已连接设备（图标区分锁定态），
  右侧为日期分栏的 `LazyVGrid`（`GridItem(.adaptive(minimum:112,maximum:170))`）。
- 三种 detail 状态：未选设备 → `emptyDeviceView`；无媒体 → `emptyMediaView`；
  有数据 → `photoGrid`。
- toolbar：principal 处为标题按钮（点击滚到顶部），右侧为刷新、取消选中、
  删除（带计数，受 `canDelete` 约束）。

### 交互

- **点击缩略图主体** → `sheet` 全屏预览（`previewRequest`）。
- **点击右上角圆圈** → 切换选中。
- **水平拖拽** → 拖拽多选（横向位移 > 纵向时触发）。

### 拖拽多选

- `DragGesture(minimumDistance:12, coordinateSpace:.named("mediaScrollSpace"))`。
- `dragAxisLock` 锁定轴向，避免同一手势中途切方向；仅横向触发选择。
- 首个命中格决定本次是 `.select` 还是 `.deselect`，`dragVisitedAssetIDs` 去重。
- `AssetFramePreferenceKey` 收集每格 rect，`assetID(at:)` 做命中检测。

### 按天分组

- 标题格式：`yyyy年M月d日 EEEE`（中文，Gregorian 历），后跟当天数量。
- 每个 section 右侧有“全选当天 / 取消当天”按钮。

### 预览（`AssetPreviewSheet`）

- 通过 `requestPreviewURL` 下载原文件到临时目录后展示。
- 图片：`NSImage` + `scaledToFit`。
- 视频：`AVKit.VideoPlayer`，出现时 `play()`，消失时 `pause()`。
- 头部显示文件名、媒体标签、分辨率（`dimensionsText`）。

---

## 删除流程（重要）

1. 选中项 > 0 时 toolbar 出现“删除(N)”。
2. `confirmationDialog` 二次确认，文案提示“直接从设备移除，需 iPhone 已解锁”。
3. `requestDeleteFiles` 执行，按结果字典区分 `.successful` / `.failed`。
4. 失败时 `alert("删除失败")` 显示 `statusText`。
5. **无系统回收站**——删除不可撤销。

`canDelete` 前置条件：有选中、未在删除中、设备存在、未锁定、未受访问限制、
且设备 capabilities 含删除能力。

---

## 语言混用规则

- **中文 UI**：刷新、取消选中、删除、全选当天、取消当天、视频、加载失败、
  设备、各类状态/错误文案。
- **英文 UI**：导航标题 "MaciPhotoAlbum"、`ContentUnavailableView` 内容
  （"No iPhone connected" / "No media found" 及其说明）。
- **错误弹窗**：“删除失败” / “好的”。

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
- 未实现导出/下载到本地相册功能（仅预览时落临时目录）。
- 多设备并发未充分测试；同一时刻聚焦单一选中设备。
