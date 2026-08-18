//
//  ContentView.swift
//  MaciPhotoAlbum
//
//  Created by Yingzhuo Huang on 2026/3/21.
//

import AppKit
import AVKit
import SwiftUI

private enum DragSelectionMode {
    case select
    case deselect
}

private enum DragAxisLock {
    case horizontal
    case vertical
}

private struct AssetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PreviewRequest: Identifiable {
    let id: String
}

struct ContentView: View {
    @StateObject private var viewModel = PhotoLibraryViewModel()
    @State private var showingDeleteDialog = false
    @State private var showingDeleteError = false
    @State private var exportResultMessage: String?
    @State private var didInitialScrollToTop = false
    @State private var frameByAssetID: [String: CGRect] = [:]
    @State private var dragSelectionMode: DragSelectionMode?
    @State private var dragVisitedAssetIDs: Set<String> = []
    @State private var isHorizontalSelectionActive = false
    @State private var dragAxisLock: DragAxisLock?
    @State private var lastDragLocation: CGPoint?
    @State private var previewRequest: PreviewRequest?
    @State private var gridZoomIndex = 0
    @State private var jumpDate = Date()

    // 缩略图整体缩放档位，作用于格子最小/最大宽度。当前(112–170)为最小档。
    private let gridZoomScales: [CGFloat] = [1.0, 1.4, 1.9, 2.6]
    private var columns: [GridItem] {
        let scale = gridZoomScales[gridZoomIndex]
        return [GridItem(.adaptive(minimum: 112 * scale, maximum: 170 * scale), spacing: 10)]
    }

    private let scrollCoordinateSpace = "mediaScrollSpace"
    private let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            ScrollViewReader { proxy in
                Group {
                    if viewModel.selectedDeviceID == nil {
                        emptyDeviceView
                    } else if viewModel.sections.isEmpty {
                        emptyMediaView
                    } else {
                        photoGrid(proxy: proxy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button {
                            scrollToTop(with: proxy)
                        } label: {
                            Text("MaciPhotoAlbum")
                                .font(.headline)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.firstAssetID == nil)
                    }

                    ToolbarItemGroup {
                        if !viewModel.selectedAssetIDs.isEmpty {
                            Button {
                                viewModel.clearSelection()
                            } label: {
                                Label("取消", systemImage: "xmark.circle")
                            }
                        }

                        Button {
                            viewModel.refreshSelectedDevice()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }

                        if !viewModel.sections.isEmpty {
                            Menu {
                                sortMenuItem("拍摄日期", systemImage: "calendar", order: .date)
                                sortMenuItem("当天总大小(大→小)", systemImage: "arrow.down", order: .daySizeDescending)
                                sortMenuItem("当天总大小(小→大)", systemImage: "arrow.up", order: .daySizeAscending)
                            } label: {
                                Label("排序", systemImage: "arrow.up.arrow.down")
                            }
                            .help("按天排序方式（每天内部仍按拍摄时间）")

                            datePickerControl

                            Button {
                                gridZoomIndex = max(gridZoomIndex - 1, 0)
                            } label: {
                                Label("缩小", systemImage: "minus.magnifyingglass")
                            }
                            .disabled(gridZoomIndex == 0)

                            Button {
                                gridZoomIndex = min(gridZoomIndex + 1, gridZoomScales.count - 1)
                            } label: {
                                Label("放大", systemImage: "plus.magnifyingglass")
                            }
                            .disabled(gridZoomIndex == gridZoomScales.count - 1)
                        }

                        if !viewModel.selectedAssetIDs.isEmpty {
                            Text("已选 \(viewModel.selectedAssetIDs.count) 项 · \(viewModel.selectedSizeText)")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Button {
                                exportSelected()
                            } label: {
                                Label("导出(\(viewModel.selectedAssetIDs.count))", systemImage: "square.and.arrow.down")
                            }
                            .disabled(!viewModel.canExport)

                            Button(role: .destructive) {
                                showingDeleteDialog = true
                            } label: {
                                Label("删除(\(viewModel.selectedAssetIDs.count))", systemImage: "trash")
                            }
                            .disabled(!viewModel.canDelete)
                        }
                    }
                }
                .confirmationDialog(
                    "删除已勾选的项目？",
                    isPresented: $showingDeleteDialog,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        viewModel.deleteSelected { success in
                            if !success {
                                showingDeleteError = true
                            }
                        }
                    }
                } message: {
                    Text("删除会直接从已连接设备中移除，操作前请确认 iPhone 已解锁。")
                }
                .alert("删除失败", isPresented: $showingDeleteError) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text(viewModel.statusText)
                }
                .alert(
                    "导出完成",
                    isPresented: Binding(
                        get: { exportResultMessage != nil },
                        set: { if !$0 { exportResultMessage = nil } }
                    )
                ) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text(exportResultMessage ?? "")
                }
                .onChange(of: viewModel.orderedAssetIDs) { _, ids in
                    handleOrderedIDsChanged(ids, proxy: proxy)
                }
                .onChange(of: jumpDate) { _, date in
                    jumpToDate(date, proxy: proxy)
                }
            }
        }
        .environmentObject(viewModel)
        .onAppear {
            viewModel.start()
        }
        .sheet(item: $previewRequest) { request in
            AssetPreviewSheet(assetID: request.id)
                .environmentObject(viewModel)
                .frame(minWidth: 720, idealWidth: 920, minHeight: 520, idealHeight: 680)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(
                viewModel.devices,
                selection: Binding(
                    get: { viewModel.selectedDeviceID },
                    set: { viewModel.selectDevice($0) }
                )
            ) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: device.isLocked ? "iphone.slash" : "iphone")
                            .foregroundStyle(device.isLocked ? .orange : .blue)

                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Text("\(device.productKind) · \(device.detailText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(device.id)
            }

            Divider()

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("设备")
    }

    private var emptyDeviceView: some View {
        ContentUnavailableView {
            Label("No iPhone connected", systemImage: "cable.connector")
        } description: {
            Text("Connect an iPhone with a cable, unlock it, and trust this Mac.")
        }
    }

    private var emptyMediaView: some View {
        ContentUnavailableView {
            Label("No media found", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(viewModel.statusText)
        }
    }

    private func photoGrid(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(sectionDateFormatter.string(from: section.date))
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text("\(section.assetIDs.count) 项 · \(viewModel.totalSizeText(for: section.assetIDs))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            let bySize = viewModel.isDaySortedBySize(section.date)
                            Button {
                                viewModel.toggleDaySizeSort(for: section.date)
                            } label: {
                                Label(
                                    bySize ? "按时间" : "按大小",
                                    systemImage: bySize ? "clock" : "arrow.down.circle"
                                )
                            }
                            .controlSize(.small)
                            .help(bySize ? "改回按拍摄时间" : "当天内按大小排序（大→小）")

                            let isAllSelected = isSectionFullySelected(section)
                            Button(isAllSelected ? "取消当天" : "全选当天") {
                                toggleSectionSelection(section, shouldSelect: !isAllSelected)
                            }
                            .controlSize(.small)
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(section.assetIDs, id: \.self) { assetID in
                                AssetThumbnailView(
                                    assetID: assetID,
                                    isSelected: viewModel.selectedAssetIDs.contains(assetID)
                                ) {
                                    previewRequest = PreviewRequest(id: assetID)
                                } onSelect: {
                                    viewModel.toggleSelection(for: assetID)
                                }
                                .id(assetID)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: AssetFramePreferenceKey.self,
                                            value: [assetID: geometry.frame(in: .named(scrollCoordinateSpace))]
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .coordinateSpace(name: scrollCoordinateSpace)
        .scrollIndicators(.visible)
        .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
            frameByAssetID = frames
        }
        .simultaneousGesture(dragSelectionGesture)
    }

    private var dragSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(scrollCoordinateSpace))
            .onChanged { value in
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)

                if dragAxisLock == nil {
                    guard dx >= 8 || dy >= 8 else { return }
                    dragAxisLock = dx > dy ? .horizontal : .vertical
                }

                guard dragAxisLock == .horizontal else { return }

                if !isHorizontalSelectionActive {
                    guard dx > dy else { return }
                    isHorizontalSelectionActive = true
                }

                handleDragSelection(to: value.location)
            }
            .onEnded { _ in
                resetDragSelection()
            }
    }

    /// Applies selection to every cell the pointer swept over since the last
    /// event — not just the cell under the current point. Fast drags fire
    /// `onChanged` at sparse, far-apart locations; hit-testing only the current
    /// point would skip every cell in between. We walk the segment from the
    /// previous location to this one and visit each cell along the way.
    private func handleDragSelection(to location: CGPoint) {
        let start = lastDragLocation ?? location
        lastDragLocation = location

        for assetID in assetIDs(along: start, to: location) {
            if dragSelectionMode == nil {
                dragSelectionMode = viewModel.selectedAssetIDs.contains(assetID) ? .deselect : .select
            }

            guard let mode = dragSelectionMode else { return }
            guard !dragVisitedAssetIDs.contains(assetID) else { continue }

            dragVisitedAssetIDs.insert(assetID)
            viewModel.setSelection(mode == .select, for: assetID)
        }
    }

    /// Cell IDs hit while stepping along the segment, in travel order (so the
    /// first one still decides select-vs-deselect). Samples every few points;
    /// the step is far smaller than a cell, so no cell between the endpoints is
    /// skipped regardless of drag speed.
    private func assetIDs(along start: CGPoint, to end: CGPoint) -> [String] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let span = max(abs(dx), abs(dy))
        let sampleStep: CGFloat = 8
        let steps = max(1, Int((span / sampleStep).rounded(.up)))

        var ordered: [String] = []
        var seen: Set<String> = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            if let id = assetID(at: point), seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    private func resetDragSelection() {
        dragSelectionMode = nil
        dragVisitedAssetIDs.removeAll()
        isHorizontalSelectionActive = false
        dragAxisLock = nil
        lastDragLocation = nil
    }

    private func assetID(at location: CGPoint) -> String? {
        frameByAssetID.first(where: { $0.value.contains(location) })?.key
    }

    @ViewBuilder
    private func sortMenuItem(_ title: String, systemImage: String, order: AssetSortOrder) -> some View {
        Button {
            viewModel.setSortOrder(order)
        } label: {
            if viewModel.sortOrder == order {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }

    @ViewBuilder
    private var datePickerControl: some View {
        let picker = Group {
            if let range = viewModel.loadedDateRange {
                DatePicker("跳转到日期", selection: $jumpDate, in: range, displayedComponents: .date)
            } else {
                DatePicker("跳转到日期", selection: $jumpDate, displayedComponents: .date)
            }
        }
        picker
            .datePickerStyle(.compact)
            .labelsHidden()
            .help("跳转到指定日期（就近）")
    }

    private func jumpToDate(_ date: Date, proxy: ScrollViewProxy) {
        guard let anchorID = viewModel.anchorAssetID(forDay: date) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func scrollToTop(with proxy: ScrollViewProxy) {
        guard let firstID = viewModel.firstAssetID else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(firstID, anchor: .top)
        }
    }

    private func exportSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到此处"
        panel.message = "选择保存照片和视频的文件夹"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        viewModel.exportSelected(to: directory) { succeeded, failed in
            if failed == 0 {
                exportResultMessage = "已导出 \(succeeded) 个项目到 \(directory.lastPathComponent)。"
            } else {
                exportResultMessage = "\(succeeded) 个成功，\(failed) 个失败。请确认 iPhone 已解锁后重试。"
            }
        }
    }

    private func isSectionFullySelected(_ section: DaySection) -> Bool {
        !section.assetIDs.isEmpty && section.assetIDs.allSatisfy { viewModel.selectedAssetIDs.contains($0) }
    }

    private func toggleSectionSelection(_ section: DaySection, shouldSelect: Bool) {
        viewModel.setSelection(shouldSelect, for: section.assetIDs)
    }

    private func handleOrderedIDsChanged(_ ids: [String], proxy: ScrollViewProxy) {
        guard !ids.isEmpty else {
            didInitialScrollToTop = false
            return
        }

        guard !didInitialScrollToTop, let firstID = ids.first else { return }

        DispatchQueue.main.async {
            proxy.scrollTo(firstID, anchor: .top)
            didInitialScrollToTop = true
        }
    }
}

private struct AssetThumbnailView: View {
    @EnvironmentObject private var viewModel: PhotoLibraryViewModel

    let assetID: String
    let isSelected: Bool
    let onTap: () -> Void
    let onSelect: () -> Void

    @State private var image: NSImage?
    @State private var targetPixelSize: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.14))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap()
                    }

                Button {
                    onSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white, isSelected ? .blue : .black.opacity(0.35))
                        .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "取消选中" : "选中")
                .padding(4)

                if viewModel.mediaKind(for: assetID) == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
            }

            Text(viewModel.filename(for: assetID))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(viewModel.mediaLabel(for: assetID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contextMenu {
            Button {
                viewModel.copyAsset(id: assetID)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateTargetSize(from: geometry.size)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        updateTargetSize(from: newSize)
                    }
            }
        }
        .task(id: "\(assetID)-\(Int(targetPixelSize))") {
            image = viewModel.cachedThumbnail(for: assetID)
            viewModel.requestThumbnail(for: assetID, maxPixelSize: targetPixelSize) { result in
                if let result {
                    image = result
                }
            }
        }
    }

    private func updateTargetSize(from viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let side = max(viewSize.width, viewSize.height) * scale
        let clamped = max(180, ceil(side))
        guard abs(clamped - targetPixelSize) >= 12 else { return }
        targetPixelSize = clamped
        image = nil
    }
}

private struct AssetPreviewSheet: View {
    @EnvironmentObject private var viewModel: PhotoLibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var assetID: String
    @State private var phase: PreviewPhase = .loading
    @State private var zoomIndex = 0
    @State private var showingDeleteConfirm = false
    @State private var deleteErrorMessage: String?
    @FocusState private var focused: Bool

    // zoom=1.0 等同“适应窗口”，作为最小档；其余为放大倍数。
    private let zoomLevels: [CGFloat] = [1.0, 1.5, 2.0, 3.0, 4.0]

    init(assetID: String) {
        _assetID = State(initialValue: assetID)
    }

    private var orderedIDs: [String] { viewModel.orderedAssetIDs }
    private var currentIndex: Int? { orderedIDs.firstIndex(of: assetID) }
    private var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }
    private var canGoNext: Bool {
        guard let i = currentIndex else { return false }
        return i < orderedIDs.count - 1
    }
    private var isImage: Bool {
        if case .image = phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { goToPrevious(); return .handled }
        .onKeyPress(.rightArrow) { goToNext(); return .handled }
        .onKeyPress { press in handleKey(press) }
        .task(id: assetID) {
            zoomIndex = 0
            loadPreview()
        }
        .confirmationDialog(
            "删除这一项？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteCurrent() }
        } message: {
            Text("删除会直接从已连接设备中移除，无法恢复，操作前请确认 iPhone 已解锁。")
        }
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.filename(for: assetID))
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Text(viewModel.mediaLabel(for: assetID))
                    let dimensions = viewModel.dimensionsText(for: assetID)
                    if !dimensions.isEmpty { Text(dimensions) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button { goToPrevious() } label: {
                Image(systemName: "chevron.left")
            }.disabled(!canGoPrevious).help("上一张 (←)")

            Button { goToNext() } label: {
                Image(systemName: "chevron.right")
            }.disabled(!canGoNext).help("下一张 (→)")

            Divider().frame(height: 16)

            Button { zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }.disabled(!isImage || zoomIndex == 0).help("缩小 (−)")

            Button { zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }.disabled(!isImage || zoomIndex == zoomLevels.count - 1).help("放大 (+)")

            Divider().frame(height: 16)

            Button(role: .destructive) { showingDeleteConfirm = true } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!viewModel.canDeleteFromDevice)
            .help("从设备删除这一项")

            Button { dismiss() } label: {
                Label("关闭", systemImage: "xmark.circle.fill")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.black

            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在从设备读取...").foregroundStyle(.white.secondary)
                }
            case .image(let image):
                CenteredZoomablePreviewImage(
                    image: image,
                    zoomScale: zoomLevels[zoomIndex],
                    isScrollEnabled: zoomIndex > 0
                )
                .padding(12)
            case .video(let url):
                StableVideoPlayer(url: url)
            case .failed(let message):
                Text(message).foregroundStyle(.white).padding()
            }
        }
        .contextMenu {
            Button {
                viewModel.copyAsset(id: assetID)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.characters {
        case "+", "=": zoomIn(); return .handled
        case "-", "_": zoomOut(); return .handled
        default: return .ignored
        }
    }

    private func goToPrevious() {
        guard let i = currentIndex, i > 0 else { return }
        assetID = orderedIDs[i - 1]
    }

    private func goToNext() {
        guard let i = currentIndex, i < orderedIDs.count - 1 else { return }
        assetID = orderedIDs[i + 1]
    }

    /// Deletes the item currently shown. The neighbour to fall back to is
    /// captured *before* deletion (the ordering rebuilds afterwards): prefer the
    /// next item, else the previous one, else close the sheet when it was the
    /// last item.
    private func deleteCurrent() {
        let deletingID = assetID
        let neighbour: String? = {
            guard let i = currentIndex else { return nil }
            if i + 1 < orderedIDs.count { return orderedIDs[i + 1] }
            if i - 1 >= 0 { return orderedIDs[i - 1] }
            return nil
        }()

        viewModel.deleteAssets([deletingID]) { success in
            guard success else {
                deleteErrorMessage = viewModel.statusText
                return
            }
            if let neighbour {
                assetID = neighbour
            } else {
                dismiss()
            }
        }
    }

    private func zoomIn() {
        guard isImage else { return }
        zoomIndex = min(zoomIndex + 1, zoomLevels.count - 1)
    }

    private func zoomOut() {
        guard isImage else { return }
        zoomIndex = max(zoomIndex - 1, 0)
    }

    private func loadPreview() {
        phase = .loading

        viewModel.requestPreviewURL(for: assetID) { result in
            switch result {
            case .success(let url):
                if viewModel.mediaKind(for: assetID) == .video {
                    phase = .video(url)
                } else if let image = NSImage(contentsOf: url) {
                    phase = .image(image)
                } else {
                    phase = .failed("加载失败")
                }
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private enum PreviewPhase {
        case loading
        case image(NSImage)
        case video(URL)
        case failed(String)
    }
}

private struct CenteredZoomablePreviewImage: View {
    let image: NSImage
    let zoomScale: CGFloat
    let isScrollEnabled: Bool

    private let imageID = "preview-image"

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: geo.size.width * zoomScale,
                            height: geo.size.height * zoomScale
                        )
                        .id(imageID)
                }
                .scrollDisabled(!isScrollEnabled)
                .onAppear {
                    centerImage(with: proxy)
                }
                .onChange(of: zoomScale) { _, _ in
                    centerImage(with: proxy)
                }
            }
        }
    }

    private func centerImage(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(imageID, anchor: .center)
            }
        }
    }
}

private struct StableVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        context.coordinator.currentURL = url
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
        context.coordinator.currentURL = url
        view.player?.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var currentURL: URL?
    }
}
