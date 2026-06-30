# MaciPhotoAlbum — AGENTS.md

## 项目概述

iOS 相册 App，名称 **MaciPhotoAlbum**。以日期分栏展示设备相册中的照片和视频，支持多选批量删除、全屏预览、拖拽选择等功能。

- **开发者**：Yingzhuo Huang
- **创建日期**：2026/3/21
- **平台**：iOS，SwiftUI + PhotoKit (Photos framework) + AVKit
- **开发环境**：macOS 14 + Xcode 15（iOS 17 SDK）；运行设备：**iOS 26.3**
- **重要**：所有功能必须在 iOS 26.3 真机上可用，iOS 26 对 SwiftUI/UIKit 手势交互有较大变化

---

## 文件结构

```
MaciPhotoAlbum/
├── MaciPhotoAlbumApp.swift          # App 入口 (@main)
├── ContentView.swift            # 主界面 & 所有子 View
├── PhotoLibraryViewModel.swift  # 业务逻辑 & 数据层
└── Assets.xcassets/             # 图标等资源
```

---

## 架构

### 数据层：`PhotoLibraryViewModel`

`@MainActor final class`，`ObservableObject`，负责：

- **资产加载**：`reloadAssets()` 通过 `PHFetchOptions`（按 creationDate 降序）拉取全量相册，按日历天分组为 `[DaySection]`。
- **数据模型**：
  - `DaySection`：`{ date: Date, assetIDs: [String] }`，以 `startOfDay` 作为 key。
  - `AssetInfo`：`{ mediaType: PHAssetMediaType, byteSize: Int64? }`，byteSize 懒加载。
  - 资产 ID 使用 `PHAsset.localIdentifier`（String）作为全局稳定标识符。
- **缩略图预热**：`PHCachingImageManager`，以当前可见资产为中心，前后各 24 个（radius=24）。
- **文件大小**：`PHAssetResource` + `requestData` 读取字节数，滚动期间延迟，停止滚动 0.25s 后批量触发。
- **选择状态**：`Set<String> selectedAssetIDs`。
- **删除**：`PHPhotoLibrary.performChanges` + `PHAssetChangeRequest.deleteAssets`，删后进系统"最近删除"。
- **实时更新**：注册 `PHPhotoLibraryChangeObserver`，库变化时调用 `reloadAssets()`。

### 视图层：`ContentView.swift`

所有 View 均在此文件内（private structs/classes）：

| 组件 | 说明 |
|------|------|
| `ContentView` | 根视图，NavigationStack + ScrollViewReader |
| `AssetThumbnailView` | 单个缩略图格子，含选中指示器和文件大小标签 |
| `AssetPreviewPagerScreen` | 全屏预览，TabView 横向翻页 |
| `AssetPreviewPage` | 单张预览页，图片用 `ZoomableImageView`，视频用 `AVKit.VideoPlayer` |
| `DownwardDismissHandler` | UIViewRepresentable，将下滑退出手势安装在 UIWindow 上 |
| `ZoomScrollView` | UIScrollView 子类，处理照片缩放与平移（见下方 iOS 26 说明） |
| `ZoomableImageView` | UIViewRepresentable，包装 ZoomScrollView |

---

## 核心功能

### 交互模式（单一模式）

无 browse/select 切换（已废弃，原因：iOS 26 SwiftUI ScrollView 切换状态时滚动位置无法保持）：
- **点击照片主体** → 全屏预览
- **点击右上角选择圆圈** → 切换选中/取消选中
- **水平拖拽** → 拖拽多选
- 选择指示器始终显示；选中数 > 0 时 toolbar 显示删除按钮

### 拖拽多选

- 水平拖拽（横向位移 > 纵向）触发拖拽选择，锁定轴向后批量选/取消选。
- `dragAxisLock` 确保同一拖拽手势不切换方向。
- `AssetFramePreferenceKey` 通过 PreferenceKey 收集每个资产的坐标 rect，用于命中检测。

### 按天分组

- 网格标题格式：`yyyy年M月d日 EEEE`（中文，Gregorian 历）。
- 每个 section 右侧有"全选当天"/"取消当天"按钮，始终显示。

### 全屏预览

- `fullScreenCover` 展示 `AssetPreviewPagerScreen`。
- `TabView(.page)` 左右翻页，`selection: $currentAssetID` 绑定当前页。
- 下滑退出：`DownwardDismissHandler`（UIViewRepresentable）。
- 图片：`ZoomScrollView` 捏合缩放 1x–4x，双击 2x 放大/还原，缩放后可拖拽平移。
- 视频：`PHImageManager.requestPlayerItem` + `AVPlayer`，页面出现时自动播放，消失时暂停。
  - ⚠️ 当前未配置 `AVAudioSession`，静音模式下无声音。

---

## iOS 26 手势架构（重要）

iOS 26 的 SwiftUI/UIKit 手势交互与早期版本有显著差异，以下是已知问题和解决方案：

### 问题1：TabView 翻页失效

**原因**：SwiftUI overlay 产生的容器 UIView 默认 `isUserInteractionEnabled = true`，在 hit-test 时返回自身，TabView 内部的 UIScrollView（兄弟节点）收不到 touch 事件。即使在 overlay UIView 上设 `isUserInteractionEnabled = false`，容器本身仍然拦截。

**解决方案**（两层）：
1. overlay 加 `.allowsHitTesting(false)` → SwiftUI 将容器 UIView 设为 `isUserInteractionEnabled = false`，touch 穿透。
2. `ZoomScrollView.gestureRecognizerShouldBegin` → zoom=1 时横向 pan 直接 fail，UIKit nested-scroll 让父级 TabView 接管。

### 问题2：ZoomScrollView 初始显示放大

**原因**：`updateUIView` 在 UIKit layout 前调用（bounds=zero），`layoutSize` guard 记录后不再被调用，imageView.frame 永久为 zero，图片以原始分辨率显示。

**解决方案**：改用 `layoutSubviews` override 设置布局，UIKit 在 bounds 确定后自动调用，时机可靠。

### 问题3：下滑退出与 TabView 手势冲突

**原因**：将 `UIPanGestureRecognizer` 挂在覆盖层 UIView 上时，对横向 swipe 的 `gestureRecognizerShouldBegin` 返回 false，但 TabView 的 UIScrollView 作为兄弟节点从未收到 touch，翻页仍失效。

**解决方案**：`DownwardDismissHandler` 的 `AnchorView`（`isUserInteractionEnabled = false`）通过 `didMoveToWindow` 将手势安装在 UIWindow。Window 级别手势绕过 hit-test，能看到所有 touch，且对横向 swipe 主动 fail，不干扰翻页。

---

## 语言混用规则

- **中文 UI**：删除、清空、全选当天、取消当天、计算中...、视频、加载失败、管理访问、取消选中
- **英文 UI**：导航标题 "MaciPhotoAlbum"、权限说明文字、`ContentUnavailableView` 内容
- **错误弹窗**："删除失败" / "好的"（中文）

---

## 权限

- 需要 `NSPhotoLibraryUsageDescription`（读写权限 `.readWrite`）。
- `hasReadAccess` = `.authorized` 或 `.limited`。
- 无权限时显示引导页，用户点击后调用 `PHPhotoLibrary.requestAuthorization`。
- limited 权限时 toolbar 显示"管理访问"按钮，跳转到系统设置（`openAppSettings()`）。

---

## 性能约定

- 缩略图请求：`deliveryMode = .opportunistic`，`resizeMode = .fast`。
- 全屏图片：`deliveryMode = .highQualityFormat`，`resizeMode = .exact`。
- 文件大小：`PHAssetResourceManager.requestData` 累加字节数；滚动期间 defer，停止 0.25s 后 flush。
- 预热窗口变化阈值：中心索引偏移 ≥ 10 或 targetSize 变化 > 24pt 才重算。
