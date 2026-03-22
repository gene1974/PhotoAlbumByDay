//
//  ContentView.swift
//  PhotoAlbum
//
//  Created by Yingzhuo Huang on 2026/3/21.
//

import SwiftUI
import Photos
import AVKit
import UIKit

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

struct ContentView: View {
    @StateObject private var viewModel = PhotoLibraryViewModel()
    @State private var showingDeleteDialog = false
    @State private var showingDeleteError = false
    @State private var didInitialScrollToTop = false
    @State private var frameByAssetID: [String: CGRect] = [:]
    @State private var dragSelectionMode: DragSelectionMode?
    @State private var dragVisitedAssetIDs: Set<String> = []
    @State private var isHorizontalSelectionActive = false
    @State private var dragAxisLock: DragAxisLock?
    @State private var previewAssetID: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 8)]
    private let scrollCoordinateSpace = "mediaScrollSpace"
    private let sectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if viewModel.hasReadAccess {
                        photoGrid(proxy: proxy)
                    } else {
                        permissionView
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button {
                            scrollToTop(with: proxy)
                        } label: {
                            Text("Daily Media")
                                .font(.headline)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.firstAssetID == nil)
                    }

                    if viewModel.authorizationStatus == .limited {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("管理访问") {
                                viewModel.openAppSettings()
                            }
                        }
                    }

                    if !viewModel.selectedAssetIDs.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消选中") {
                                viewModel.clearSelection()
                            }
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) {
                                showingDeleteDialog = true
                            } label: {
                                Text("删除(\(viewModel.selectedAssetIDs.count))")
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
                    Text("删除后会进入最近删除。")
                }
                .alert("删除失败", isPresented: $showingDeleteError) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("请检查照片权限后重试。")
                }
                .onAppear {
                    viewModel.start()
                }
                .onChange(of: viewModel.orderedAssetIDs) { _, ids in
                    handleOrderedIDsChanged(ids, proxy: proxy)
                }
            }
        }
        .environmentObject(viewModel)
        .fullScreenCover(
            isPresented: Binding(
                get: { previewAssetID != nil },
                set: { newValue in
                    if !newValue {
                        previewAssetID = nil
                    }
                }
            )
        ) {
            if let previewAssetID, !viewModel.orderedAssetIDs.isEmpty {
                AssetPreviewPagerScreen(
                    assetIDs: viewModel.orderedAssetIDs,
                    initialAssetID: previewAssetID
                ) {
                    self.previewAssetID = nil
                }
            }
        }
    }

    private func photoGrid(proxy: ScrollViewProxy) -> some View {
        Group {
            if viewModel.sections.isEmpty {
                ContentUnavailableView(
                    "No media found",
                    systemImage: "photo.on.rectangle.angled"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(sectionDateFormatter.string(from: section.date))
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)

                                    let isAllSelected = isSectionFullySelected(section)
                                    Button(isAllSelected ? "取消当天" : "全选当天") {
                                        toggleSectionSelection(section, shouldSelect: !isAllSelected)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)
                                }

                                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                    ForEach(section.assetIDs, id: \.self) { assetID in
                                        AssetThumbnailView(
                                            assetID: assetID,
                                            isSelected: viewModel.selectedAssetIDs.contains(assetID)
                                        ) {
                                            previewAssetID = assetID
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .coordinateSpace(name: scrollCoordinateSpace)
                .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
                    let previousFrames = frameByAssetID
                    frameByAssetID = frames
                    if hasMeaningfulFrameShift(from: previousFrames, to: frames) {
                        viewModel.noteScrollActivity()
                    }
                }
                .simultaneousGesture(dragSelectionGesture)
            }
        }
    }

    @ViewBuilder
    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text("Photo access is required")
                .font(.headline)

            Text("Grant read-write access to browse by day and delete media.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Grant Access") {
                Task {
                    await viewModel.requestAuthorizationIfNeeded()
                    if viewModel.hasReadAccess {
                        viewModel.reloadAssets()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
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

                handleDragSelection(at: value.location)
            }
            .onEnded { _ in
                resetDragSelection()
            }
    }

    private func handleDragSelection(at location: CGPoint) {
        guard let assetID = assetID(at: location) else { return }

        if dragSelectionMode == nil {
            dragSelectionMode = viewModel.selectedAssetIDs.contains(assetID) ? .deselect : .select
        }

        guard let mode = dragSelectionMode else { return }
        guard !dragVisitedAssetIDs.contains(assetID) else { return }

        dragVisitedAssetIDs.insert(assetID)
        viewModel.setSelection(mode == .select, for: assetID)
    }

    private func resetDragSelection() {
        dragSelectionMode = nil
        dragVisitedAssetIDs.removeAll()
        isHorizontalSelectionActive = false
        dragAxisLock = nil
    }

    private func assetID(at location: CGPoint) -> String? {
        frameByAssetID.first(where: { $0.value.contains(location) })?.key
    }

    private func scrollToTop(with proxy: ScrollViewProxy) {
        guard let firstID = viewModel.firstAssetID else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(firstID, anchor: .top)
        }
    }

    private func isSectionFullySelected(_ section: DaySection) -> Bool {
        !section.assetIDs.isEmpty && section.assetIDs.allSatisfy { viewModel.selectedAssetIDs.contains($0) }
    }

    private func toggleSectionSelection(_ section: DaySection, shouldSelect: Bool) {
        viewModel.setSelection(shouldSelect, for: section.assetIDs)
    }

    private func hasMeaningfulFrameShift(from oldFrames: [String: CGRect], to newFrames: [String: CGRect]) -> Bool {
        for (id, newFrame) in newFrames {
            guard let oldFrame = oldFrames[id] else { continue }
            if abs(newFrame.minY - oldFrame.minY) > 1 || abs(newFrame.minX - oldFrame.minX) > 1 {
                return true
            }
        }
        return false
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

    @State private var image: UIImage?
    @State private var thumbnailRequestID: PHImageRequestID?
    @State private var targetPixelSize: CGSize = CGSize(width: 220, height: 220)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap()
                    }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .white)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect()
                    }
            }

            Text(viewModel.mediaLabel(for: assetID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .task(id: "\(assetID)-\(Int(targetPixelSize.width))") {
            loadThumbnail()
            viewModel.ensureSizeLoaded(for: assetID)
            viewModel.updatePreheatWindow(around: assetID, targetSize: targetPixelSize)
        }
        .onDisappear {
            viewModel.cancelImageRequest(thumbnailRequestID)
            thumbnailRequestID = nil
        }
    }

    private func loadThumbnail() {
        viewModel.cancelImageRequest(thumbnailRequestID)
        thumbnailRequestID = viewModel.requestThumbnail(for: assetID, targetSize: targetPixelSize) { result in
            if let result {
                image = result
            }
        }
    }

    private func updateTargetSize(from viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }

        let scale = UIScreen.main.scale
        let side = max(viewSize.width, viewSize.height) * scale
        let clampedSide = max(160, ceil(side))

        guard abs(clampedSide - targetPixelSize.width) >= 12 else { return }

        targetPixelSize = CGSize(width: clampedSide, height: clampedSide)
        image = nil
    }
}

private struct AssetPreviewPagerScreen: View {
    let assetIDs: [String]
    let onClose: () -> Void

    @State private var currentAssetID: String
    @State private var dismissDragOffsetY: CGFloat = 0

    init(assetIDs: [String], initialAssetID: String, onClose: @escaping () -> Void) {
        self.assetIDs = assetIDs
        self.onClose = onClose
        _currentAssetID = State(
            initialValue: assetIDs.contains(initialAssetID) ? initialAssetID : (assetIDs.first ?? initialAssetID)
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentAssetID) {
                ForEach(assetIDs, id: \.self) { assetID in
                    AssetPreviewPage(assetID: assetID)
                        .tag(assetID)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .offset(y: dismissDragOffsetY)
            // allowsHitTesting(false) 使 SwiftUI 给 overlay 生成的容器 UIView
            // isUserInteractionEnabled = false，touch 穿透到 TabView 内容层。
            // 下滑退出手势挂在 UIWindow 上，不依赖 hit-test，不受影响。
            .overlay(
                DownwardDismissHandler(offsetY: $dismissDragOffsetY, onDismiss: onClose)
                    .allowsHitTesting(false)
            )

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(16)
            }
            .offset(y: dismissDragOffsetY)
        }
    }

    private var backgroundOpacity: Double {
        let progress = min(max(dismissDragOffsetY / 320.0, 0), 1)
        let opacity: CGFloat = 1 - (progress * 0.35)
        return Double(opacity)
    }
}

// 将手势安装在 UIWindow 上，而非覆盖在 TabView 之上的 UIView 上。
// 原因：iOS 26 中覆盖层 UIView 会捕获 hit-test，导致 TabView 内部的
// UIScrollView 永远收不到横向滑动的 touch 事件，即使我们的手势 fail 了也无效。
// 将手势挂在 window 上可绕过 hit-test 路径，让 TabView 横向翻页正常工作。
private struct DownwardDismissHandler: UIViewRepresentable {
    @Binding var offsetY: CGFloat
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(offsetY: $offsetY, onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.offsetY = $offsetY
        context.coordinator.onDismiss = onDismiss
    }

    // 透明占位 view，isUserInteractionEnabled=false 让所有 touch 直接穿透。
    // 唯一职责：在进入/离开 window 时安装/卸载 window 级别的手势识别器。
    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window = window {
                coordinator?.install(in: window)
            } else {
                coordinator?.uninstall()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var offsetY: Binding<CGFloat>
        var onDismiss: () -> Void
        private var installedPan: UIPanGestureRecognizer?

        init(offsetY: Binding<CGFloat>, onDismiss: @escaping () -> Void) {
            self.offsetY = offsetY
            self.onDismiss = onDismiss
        }

        func install(in window: UIWindow) {
            guard installedPan == nil else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.delaysTouchesBegan = false
            pan.cancelsTouchesInView = false
            window.addGestureRecognizer(pan)
            installedPan = pan
        }

        func uninstall() {
            if let pan = installedPan {
                pan.view?.removeGestureRecognizer(pan)
                installedPan = nil
            }
        }

        // 仅在速度以向下为主时才启动手势，避免干扰横向翻页
        func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
            guard let pan = gr as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let v = pan.velocity(in: view)
            return v.y > 80 && v.y > abs(v.x) * 2
        }

        // 与 TabView 的 UIScrollView 手势同时识别，互不取消
        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: pan.view)
            switch pan.state {
            case .changed:
                offsetY.wrappedValue = max(0, translation.y)
            case .ended:
                let velocity = pan.velocity(in: pan.view)
                if translation.y > 120 || velocity.y > 500 {
                    onDismiss()
                    offsetY.wrappedValue = 0
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        offsetY.wrappedValue = 0
                    }
                }
            case .cancelled, .failed:
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    offsetY.wrappedValue = 0
                }
            default:
                break
            }
        }
    }
}

private struct AssetPreviewPage: View {
    let assetID: String

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var imageRequestID: PHImageRequestID?
    @State private var videoRequestID: PHImageRequestID?
    @State private var loadToken = UUID()
    @State private var isVideo = false
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if isVideo, let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                } else if let image {
                    ZoomableImageView(image: image)
                } else {
                    Text("加载失败")
                        .foregroundStyle(.white)
                }
            }
        }
        .onDisappear {
            cancelRequests()
            player?.pause()
            player = nil
        }
        .task(id: assetID) {
            loadAsset()
        }
    }

    private func loadAsset() {
        cancelRequests()
        isLoading = true
        image = nil
        player = nil
        isVideo = false
        let token = UUID()
        loadToken = token

        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else {
            isLoading = false
            return
        }

        if asset.mediaType == .video {
            isVideo = true
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            videoRequestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                DispatchQueue.main.async {
                    guard loadToken == token else { return }
                    if let item {
                        player = AVPlayer(playerItem: item)
                    }
                    isLoading = false
                }
            }
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        let targetSize = previewTargetSize()

        imageRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { resultImage, _ in
            DispatchQueue.main.async {
                guard loadToken == token else { return }
                image = resultImage
                isLoading = false
            }
        }
    }

    private func previewTargetSize() -> CGSize {
        let screenSize = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let maxSide = max(screenSize.width, screenSize.height) * scale * 2.2
        let clampedSide = min(maxSide, 4096)
        return CGSize(width: clampedSide, height: clampedSide)
    }

    private func cancelRequests() {
        if let imageRequestID {
            PHImageManager.default().cancelImageRequest(imageRequestID)
            self.imageRequestID = nil
        }
        if let videoRequestID {
            PHImageManager.default().cancelImageRequest(videoRequestID)
            self.videoRequestID = nil
        }
    }
}

// UIScrollView 子类，处理照片预览的缩放与平移。
//
// 为何用 UIScrollView 而非 SwiftUI 手势：
//   SwiftUI DragGesture 在 UIKit 层面会抢占所有 touch，导致 TabView
//   的 UIPageViewController 内部 UIScrollView 收不到横向事件，翻页失效。
//
// 为何用 layoutSubviews 而非 updateUIView 设置布局：
//   updateUIView 由 SwiftUI 调用，可能在 UIKit layout 之前触发（bounds=zero），
//   layoutSize guard 记录后 UIKit 给出真实 bounds 时 updateUIView 不再被调用，
//   导致 imageView.frame 始终为 zero，图片以原始分辨率显示（"放大状态"）。
//   layoutSubviews 由 UIKit 在 bounds 确定后调用，时机始终正确。
//
// gestureRecognizerShouldBegin：
//   zoom=1 时横向 pan 直接 fail，UIKit nested-scroll 机制让父级
//   UIPageViewController 接管，左右翻页得以工作。
private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var naturalSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 1, size.height > 1, size != naturalSize else { return }
        naturalSize = size
        // frame 先于 zoomScale，避免 scrollViewDidZoom 里 imageView 还是旧尺寸
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        contentOffset = .zero
        contentInset = .zero
        zoomScale = minimumZoomScale
    }

    // zoom=1 时横向滑动 fail → 父级 TabView 处理翻页
    override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        guard gr === panGestureRecognizer,
              let pan = gr as? UIPanGestureRecognizer,
              zoomScale <= minimumZoomScale else {
            return super.gestureRecognizerShouldBegin(gr)
        }
        let v = pan.velocity(in: self)
        if abs(v.x) > abs(v.y) { return false }
        return super.gestureRecognizerShouldBegin(gr)
    }

    // MARK: UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let sv = scrollView.bounds.size
        let iv = imageView.frame.size
        scrollView.contentInset = UIEdgeInsets(
            top:    max((sv.height - iv.height) / 2, 0),
            left:   max((sv.width  - iv.width)  / 2, 0),
            bottom: max((sv.height - iv.height) / 2, 0),
            right:  max((sv.width  - iv.width)  / 2, 0)
        )
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.imageView.image = image
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {}

    final class Coordinator: NSObject {
        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let sv = gr.view as? ZoomScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let pt = gr.location(in: sv.imageView)
                sv.zoom(to: CGRect(
                    x: pt.x - sv.bounds.width  / 4,
                    y: pt.y - sv.bounds.height / 4,
                    width:  sv.bounds.width  / 2,
                    height: sv.bounds.height / 2
                ), animated: true)
            }
        }
    }
}

#Preview {
    ContentView()
}
