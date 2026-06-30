# MaciPhotoAlbum — CLAUDE.md

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
