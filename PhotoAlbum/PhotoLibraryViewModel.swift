//
//  PhotoLibraryViewModel.swift
//  PhotoAlbum
//
//  Created by Yingzhuo Huang on 2026/3/21.
//

import Foundation
import Photos
import UIKit

struct DaySection: Identifiable {
    let date: Date
    let assetIDs: [String]

    var id: Date { date }
}

private struct AssetInfo {
    let mediaType: PHAssetMediaType
    var byteSize: Int64?
}

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject {
    @Published var sections: [DaySection] = []
    @Published var selectedAssetIDs: Set<String> = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined

    private var assetsByID: [String: PHAsset] = [:]
    private var infoByID: [String: AssetInfo] = [:]
    private var hasStarted = false

    private var sizeLoadingAssetIDs: Set<String> = []
    private var sizeLoadedAssetIDs: Set<String> = []
    private var pendingSizeLoadAssetIDs: Set<String> = []
    private var sizeRequestIDsByAssetID: [String: [PHAssetResourceDataRequestID]] = [:]
    private var isActivelyScrolling = false
    private var scrollActivityToken: UInt64 = 0
    private var pendingReloadTask: Task<Void, Never>?
    private var cachedAssetIDs: Set<String> = []
    private var lastPreheatCenterIndex: Int?
    private var lastPreheatSide: CGFloat = 0

    private let imageManager = PHCachingImageManager()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    override init() {
        super.init()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    deinit {
        pendingReloadTask?.cancel()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        imageManager.stopCachingImagesForAllAssets()
    }

    var orderedAssetIDs: [String] {
        sections.flatMap(\.assetIDs)
    }

    var firstAssetID: String? {
        orderedAssetIDs.first
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        PHPhotoLibrary.shared().register(self)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.requestAuthorizationIfNeeded()
            if self.hasReadAccess {
                self.reloadAssets()
            }
        }
    }

    var hasReadAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var canDelete: Bool {
        hasReadAccess
    }

    func requestAuthorizationIfNeeded() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = current
        guard current == .notDetermined else { return }

        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = newStatus
    }

    func reloadAssets() {
        var newAssetsByID: [String: PHAsset] = [:]
        var newInfoByID: [String: AssetInfo] = [:]
        var rows: [(id: String, date: Date)] = []

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: options)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }

            let id = asset.localIdentifier
            newAssetsByID[id] = asset
            rows.append((id: id, date: asset.creationDate ?? .distantPast))
            newInfoByID[id] = AssetInfo(mediaType: asset.mediaType, byteSize: nil)
        }

        assetsByID = newAssetsByID
        infoByID = newInfoByID
        cancelAllSizeRequests()
        sizeLoadingAssetIDs.removeAll()
        sizeLoadedAssetIDs.removeAll()
        pendingSizeLoadAssetIDs.removeAll()
        isActivelyScrolling = false
        scrollActivityToken = 0
        cachedAssetIDs.removeAll()
        lastPreheatCenterIndex = nil
        lastPreheatSide = 0
        imageManager.stopCachingImagesForAllAssets()

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { row in
            calendar.startOfDay(for: row.date)
        }

        let sortedDays = grouped.keys.sorted(by: >)
        sections = sortedDays.map { day in
            let sortedIDs = grouped[day, default: []]
                .sorted { lhs, rhs in
                    if lhs.date == rhs.date {
                        return lhs.id > rhs.id
                    }
                    return lhs.date > rhs.date
                }
                .map(\.id)
            return DaySection(date: day, assetIDs: sortedIDs)
        }

        selectedAssetIDs = selectedAssetIDs.filter { assetsByID[$0] != nil }
    }

    func asset(for id: String) -> PHAsset? {
        assetsByID[id]
    }

    func mediaLabel(for id: String) -> String {
        guard let info = infoByID[id] else { return "" }

        if let byteSize = info.byteSize {
            let sizeText = byteFormatter.string(fromByteCount: byteSize)
            if info.mediaType == .video {
                return "视频 | \(sizeText)"
            }
            return sizeText
        }

        if info.mediaType == .video {
            if sizeLoadingAssetIDs.contains(id) {
                return "视频 | 计算中..."
            }
            if sizeLoadedAssetIDs.contains(id) {
                return "视频 | 大小未知"
            }
            return "视频"
        }
        if sizeLoadedAssetIDs.contains(id) {
            return "大小未知"
        }
        return sizeLoadingAssetIDs.contains(id) ? "计算中..." : ""
    }

    func ensureSizeLoaded(for id: String) {
        if isActivelyScrolling {
            pendingSizeLoadAssetIDs.insert(id)
            return
        }

        startSizeLoad(for: id)
    }

    func noteScrollActivity() {
        isActivelyScrolling = true
        scrollActivityToken += 1
        let token = scrollActivityToken

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.scrollActivityToken == token else { return }

                self.isActivelyScrolling = false
                self.flushPendingSizeLoads()
            }
        }
    }

    private func flushPendingSizeLoads() {
        guard !pendingSizeLoadAssetIDs.isEmpty else { return }

        let pendingSet = pendingSizeLoadAssetIDs
        pendingSizeLoadAssetIDs.removeAll()

        let orderedPendingIDs = orderedAssetIDs.filter { pendingSet.contains($0) }
        for id in orderedPendingIDs {
            startSizeLoad(for: id)
        }
    }

    private func startSizeLoad(for id: String) {
        guard infoByID[id] != nil else { return }
        guard !sizeLoadedAssetIDs.contains(id) else { return }
        guard !sizeLoadingAssetIDs.contains(id) else { return }
        guard let asset = assetsByID[id] else { return }

        sizeLoadingAssetIDs.insert(id)
        let requestIDs = Self.requestAssetByteSize(for: asset, allowNetwork: false) { [weak self] size in
            Task { @MainActor [weak self] in
                self?.applyLoadedSize(size, for: id)
            }
        }
        sizeRequestIDsByAssetID[id] = requestIDs
    }

    private func applyLoadedSize(_ size: Int64?, for id: String) {
        sizeLoadingAssetIDs.remove(id)
        pendingSizeLoadAssetIDs.remove(id)
        sizeRequestIDsByAssetID.removeValue(forKey: id)

        guard var info = infoByID[id] else { return }
        sizeLoadedAssetIDs.insert(id)
        info.byteSize = size
        infoByID[id] = info
    }

    func requestThumbnail(for id: String, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID? {
        guard let asset = assetsByID[id] else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            completion(image)
        }
    }

    func cancelImageRequest(_ requestID: PHImageRequestID?) {
        guard let requestID else { return }
        imageManager.cancelImageRequest(requestID)
    }

    func updatePreheatWindow(around centerID: String, targetSize: CGSize, radius: Int = 24) {
        let ids = orderedAssetIDs
        guard !ids.isEmpty else { return }
        guard let centerIndex = ids.firstIndex(of: centerID) else { return }

        let targetSide = max(targetSize.width, targetSize.height)
        let isTargetSizeChanged = abs(targetSide - lastPreheatSide) > 24
        if let lastIndex = lastPreheatCenterIndex,
           abs(centerIndex - lastIndex) < 10,
           !isTargetSizeChanged,
           !cachedAssetIDs.isEmpty {
            return
        }
        lastPreheatCenterIndex = centerIndex
        lastPreheatSide = targetSide

        let lowerBound = max(0, centerIndex - radius)
        let upperBound = min(ids.count - 1, centerIndex + radius)
        let newCachedIDs = Set(ids[lowerBound...upperBound])

        let idsToStart = newCachedIDs.subtracting(cachedAssetIDs)
        let idsToStop = cachedAssetIDs.subtracting(newCachedIDs)

        if !idsToStart.isEmpty {
            let assets = idsToStart.compactMap { assetsByID[$0] }
            imageManager.startCachingImages(
                for: assets,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: nil
            )
        }

        if !idsToStop.isEmpty {
            let assets = idsToStop.compactMap { assetsByID[$0] }
            imageManager.stopCachingImages(
                for: assets,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: nil
            )
        }

        cachedAssetIDs = newCachedIDs
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func setSelection(_ isSelected: Bool, for id: String) {
        if isSelected {
            selectedAssetIDs.insert(id)
        } else {
            selectedAssetIDs.remove(id)
        }
    }

    func setSelection(_ isSelected: Bool, for ids: [String]) {
        guard !ids.isEmpty else { return }

        var updatedSelection = selectedAssetIDs
        if isSelected {
            updatedSelection.formUnion(ids)
        } else {
            updatedSelection.subtract(ids)
        }

        if updatedSelection != selectedAssetIDs {
            selectedAssetIDs = updatedSelection
        }
    }

    func toggleSelection(for id: String) {
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
    }

    func clearSelection() {
        selectedAssetIDs.removeAll()
    }

    func deleteSelected(completion: @escaping (Bool) -> Void) {
        let assetsToDelete = selectedAssetIDs.compactMap { assetsByID[$0] }
        guard !assetsToDelete.isEmpty else {
            completion(false)
            return
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assetsToDelete as NSFastEnumeration)
        } completionHandler: { [weak self] success, _ in
            Task { @MainActor in
                if success {
                    self?.selectedAssetIDs.removeAll()
                    self?.reloadAssets()
                }
                completion(success)
            }
        }
    }

    private func scheduleReload() {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.hasReadAccess else { return }
            self.reloadAssets()
        }
    }

    private func cancelAllSizeRequests() {
        let manager = PHAssetResourceManager.default()
        for requestIDs in sizeRequestIDsByAssetID.values {
            for requestID in requestIDs {
                manager.cancelDataRequest(requestID)
            }
        }
        sizeRequestIDsByAssetID.removeAll()
    }

    nonisolated private static func requestAssetByteSize(
        for asset: PHAsset,
        allowNetwork: Bool,
        completion: @escaping (Int64?) -> Void
    ) -> [PHAssetResourceDataRequestID] {
        let allResources = PHAssetResource.assetResources(for: asset)
        let resources = preferredResources(for: asset, from: allResources)
        guard !resources.isEmpty else {
            completion(nil)
            return []
        }

        final class Accumulator: @unchecked Sendable {
            var totalSize: Int64 = 0
            var hasData = false
        }

        let manager = PHAssetResourceManager.default()
        let lock = NSLock()
        let group = DispatchGroup()
        let acc = Accumulator()
        var requestIDs: [PHAssetResourceDataRequestID] = []
        requestIDs.reserveCapacity(resources.count)

        for resource in resources {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork

            group.enter()
            let requestID = manager.requestData(
                for: resource,
                options: options
            ) { data in
                lock.lock()
                acc.totalSize += Int64(data.count)
                acc.hasData = true
                lock.unlock()
            } completionHandler: { _ in
                group.leave()
            }
            requestIDs.append(requestID)
        }

        DispatchQueue.global(qos: .utility).async {
            group.wait()
            lock.lock()
            let result = acc.hasData ? acc.totalSize : nil
            lock.unlock()
            completion(result)
        }

        return requestIDs
    }

    nonisolated private static func preferredResources(
        for asset: PHAsset,
        from resources: [PHAssetResource]
    ) -> [PHAssetResource] {
        guard !resources.isEmpty else { return [] }

        switch asset.mediaType {
        case .video:
            if let full = resources.first(where: { $0.type == .fullSizeVideo }) {
                return [full]
            }
            if let video = resources.first(where: { $0.type == .video }) {
                return [video]
            }
        case .image:
            var selected: [PHAssetResource] = []
            if let full = resources.first(where: { $0.type == .fullSizePhoto }) {
                selected.append(full)
            } else if let photo = resources.first(where: { $0.type == .photo }) {
                selected.append(photo)
            } else if let alternate = resources.first(where: { $0.type == .alternatePhoto }) {
                selected.append(alternate)
            }

            if asset.mediaSubtypes.contains(.photoLive),
               let pairedVideo = resources.first(where: { $0.type == .pairedVideo }) {
                selected.append(pairedVideo)
            }

            if !selected.isEmpty {
                return selected
            }
        default:
            break
        }

        return resources.filter { resource in
            resource.type != .adjustmentData && resource.type != .adjustmentBasePhoto
        }
    }
}

extension PhotoLibraryViewModel: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.scheduleReload()
        }
    }
}
