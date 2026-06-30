//
//  PhotoLibraryViewModel.swift
//  MaciPhotoAlbum
//
//  Created by Yingzhuo Huang on 2026/3/21.
//

import AppKit
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

struct DaySection: Identifiable {
    let date: Date
    let assetIDs: [String]

    var id: Date { date }
}

struct CameraDeviceSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let productKind: String
    let isLocked: Bool
    let catalogPercent: Int
    let itemCount: Int

    var detailText: String {
        if isLocked {
            return "请解锁并信任此 Mac"
        }

        if catalogPercent < 100 {
            return "正在读取 \(catalogPercent)%"
        }

        return "\(itemCount) 个项目"
    }
}

enum MediaKind {
    case image
    case video
    case other
}

/// 天的排序方式。始终按拍摄日期分天，每天内部始终按拍摄时间(新→旧)；
/// 此枚举只决定「天」与「天」之间的先后。
enum AssetSortOrder: CaseIterable, Hashable {
    case date               // 拍摄日期，新→旧（默认）
    case daySizeDescending  // 当天总大小，大→小
    case daySizeAscending   // 当天总大小，小→大
}

@MainActor
final class PhotoLibraryViewModel: NSObject, ObservableObject {
    @Published var devices: [CameraDeviceSummary] = []
    @Published var selectedDeviceID: String?
    @Published var sections: [DaySection] = []
    @Published var sortOrder: AssetSortOrder = .date
    @Published var selectedAssetIDs: Set<String> = []
    @Published var statusText = "连接 iPhone 后，请在手机上点按“信任此电脑”。"
    @Published var isDeleting = false
    @Published var isExporting = false
    @Published var exportProgress: (done: Int, total: Int)?

    /// A media item reduced to the keys we group/sort on, all already in memory.
    private typealias AssetRow = (id: String, date: Date, size: Int64)

    private var hasStarted = false
    private let browser = ICDeviceBrowser()
    private var cameraByID: [String: ICCameraDevice] = [:]
    private var itemByID: [String: ICCameraFile] = [:]
    private var thumbnailByID: [String: NSImage] = [:]
    private var previewURLByID: [String: URL] = [:]
    private var rebuildTask: Task<Void, Never>?

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    deinit {
        browser.stop()
        for camera in cameraByID.values where camera.hasOpenSession {
            camera.requestCloseSession()
        }
    }

    var orderedAssetIDs: [String] {
        sections.flatMap(\.assetIDs)
    }

    var firstAssetID: String? {
        orderedAssetIDs.first
    }

    var canDelete: Bool {
        guard !selectedAssetIDs.isEmpty,
              !isDeleting,
              let camera = selectedCamera,
              !camera.isLocked,
              !camera.isAccessRestrictedAppleDevice else {
            return false
        }

        return camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
            || camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteAllFiles.rawValue)
    }

    var canExport: Bool {
        !selectedAssetIDs.isEmpty && !isExporting && !isDeleting && selectedCamera != nil
    }

    /// Formatted total byte size of the currently selected items, e.g. "1.2 GB".
    /// Empty when nothing is selected. Files with unknown size contribute 0.
    var selectedSizeText: String {
        guard !selectedAssetIDs.isEmpty else { return "" }
        return totalSizeText(for: selectedAssetIDs)
    }

    /// Formatted total byte size of the given items, e.g. "1.2 GB". Files with
    /// unknown size contribute 0. Sizes are cached `ICCameraFile` properties, so
    /// this is a cheap in-memory sum with no device access.
    func totalSizeText<S: Sequence>(for ids: S) -> String where S.Element == String {
        let total = ids.reduce(Int64(0)) { sum, id in
            sum + max(0, itemByID[id]?.fileSize ?? 0)
        }
        return byteFormatter.string(fromByteCount: total)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser.start()
    }

    func refreshSelectedDevice() {
        guard let selectedDeviceID else {
            sections = []
            itemByID = [:]
            selectedAssetIDs.removeAll()
            statusText = "连接 iPhone 后，请在手机上点按“信任此电脑”。"
            return
        }

        guard let camera = cameraByID[selectedDeviceID] else {
            self.selectedDeviceID = nil
            refreshSelectedDevice()
            return
        }

        // Don't pre-gate on isAccessRestrictedAppleDevice: before a session is
        // open this flag can read stale/true even for an unlocked, trusted
        // device (Image Capture itself just opens the session and lets the
        // open call surface any real error). Always attempt to connect; the
        // didOpenSessionWithError delegate reports genuine lock/trust failures.
        if !camera.hasOpenSession {
            openSession(for: camera)
            return
        }

        rebuildSections(from: camera)
    }

    func selectDevice(_ id: String?) {
        selectedDeviceID = id
        selectedAssetIDs.removeAll()
        refreshSelectedDevice()
    }

    func mediaLabel(for id: String) -> String {
        guard let item = itemByID[id] else { return "" }
        let sizeText = item.fileSize > 0 ? byteFormatter.string(fromByteCount: item.fileSize) : "大小未知"

        switch mediaKind(for: id) {
        case .video:
            return "视频 | \(sizeText)"
        case .image:
            return sizeText
        case .other:
            return "文件 | \(sizeText)"
        }
    }

    func mediaKind(for id: String) -> MediaKind {
        guard let item = itemByID[id] else { return .other }
        return Self.mediaKind(for: item)
    }

    func filename(for id: String) -> String {
        guard let item = itemByID[id] else { return "" }
        return item.originalFilename ?? item.name ?? "未命名"
    }

    func dimensionsText(for id: String) -> String {
        guard let item = itemByID[id], item.width > 0, item.height > 0 else { return "" }
        return "\(item.width) x \(item.height)"
    }

    func cachedThumbnail(for id: String) -> NSImage? {
        thumbnailByID[id]
    }

    func requestThumbnail(for id: String, maxPixelSize: CGFloat, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailByID[id] {
            completion(cached)
            return
        }

        guard let item = itemByID[id] else {
            completion(nil)
            return
        }

        let options: [ICCameraItemThumbnailOption: Any] = [
            .imageSourceThumbnailMaxPixelSize: NSNumber(value: max(160, Int(maxPixelSize.rounded(.up))))
        ]

        item.requestThumbnailData(options: options) { [weak self] data, _ in
            let image = data.flatMap(NSImage.init(data:))
            Task { @MainActor [weak self] in
                if let image {
                    self?.thumbnailByID[id] = image
                }
                completion(image)
            }
        }
    }

    func requestPreviewURL(for id: String, completion: @escaping (Result<URL, Error>) -> Void) {
        if let cached = previewURLByID[id], FileManager.default.fileExists(atPath: cached.path) {
            completion(.success(cached))
            return
        }

        guard let item = itemByID[id] else {
            completion(.failure(PreviewError.missingItem))
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaciPhotoAlbumPreview", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            completion(.failure(error))
            return
        }

        let fileName = Self.safeFilename(item.originalFilename ?? item.name ?? "\(id).media")
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: fileName,
            .overwrite: true,
            .sidecarFiles: false
        ]

        _ = item.requestDownload(options: options) { [weak self] downloadedName, error in
            Task { @MainActor [weak self] in
                if let error {
                    completion(.failure(error))
                    return
                }

                let url: URL
                if let downloadedName, downloadedName.hasPrefix("/") {
                    url = URL(fileURLWithPath: downloadedName)
                } else {
                    url = directory.appendingPathComponent(downloadedName ?? fileName)
                }

                self?.previewURLByID[id] = url
                completion(.success(url))
            }
        }
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
        setSelection(!selectedAssetIDs.contains(id), for: id)
    }

    func clearSelection() {
        selectedAssetIDs.removeAll()
    }

    /// Copies the selected items to `directory` on the Mac, downloading each in
    /// turn so the device isn't flooded with parallel transfer requests.
    /// Original filenames are preserved; collisions get a numeric suffix.
    func exportSelected(to directory: URL, completion: @escaping (_ succeeded: Int, _ failed: Int) -> Void) {
        guard selectedCamera != nil else {
            completion(0, 0)
            return
        }

        let items = orderedAssetIDs
            .filter { selectedAssetIDs.contains($0) }
            .compactMap { itemByID[$0] }

        guard !items.isEmpty else {
            completion(0, 0)
            return
        }

        isExporting = true
        exportProgress = (done: 0, total: items.count)
        statusText = "正在导出 0/\(items.count)..."

        downloadItems(items, index: 0, to: directory, succeeded: 0, failed: 0, completion: completion)
    }

    private func downloadItems(
        _ items: [ICCameraFile],
        index: Int,
        to directory: URL,
        succeeded: Int,
        failed: Int,
        completion: @escaping (Int, Int) -> Void
    ) {
        guard index < items.count else {
            isExporting = false
            exportProgress = nil
            statusText = failed == 0
                ? "导出完成，共 \(succeeded) 个项目。"
                : "导出完成，\(succeeded) 个成功，\(failed) 个失败。"
            completion(succeeded, failed)
            return
        }

        exportProgress = (done: index, total: items.count)
        statusText = "正在导出 \(index)/\(items.count)..."

        let item = items[index]
        let baseName = Self.safeFilename(item.originalFilename ?? item.name ?? "item_\(index).media")
        let fileName = Self.uniqueFilename(baseName, in: directory)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: fileName,
            .overwrite: false,
            .sidecarFiles: false
        ]

        _ = item.requestDownload(options: options) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadItems(
                    items,
                    index: index + 1,
                    to: directory,
                    succeeded: succeeded + (error == nil ? 1 : 0),
                    failed: failed + (error == nil ? 0 : 1),
                    completion: completion
                )
            }
        }
    }


    func deleteSelected(completion: @escaping (Bool) -> Void) {
        guard let camera = selectedCamera else {
            completion(false)
            return
        }

        let idsToDelete = selectedAssetIDs
        let itemsToDelete = orderedAssetIDs
            .filter { idsToDelete.contains($0) }
            .compactMap { itemByID[$0] }

        guard !itemsToDelete.isEmpty else {
            completion(false)
            return
        }

        isDeleting = true
        statusText = "正在删除 \(itemsToDelete.count) 个项目..."

        camera.requestDeleteFiles(itemsToDelete) { _ in
            // Per-item failures are reported in the completion dictionary as well.
        } completion: { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let failedCount = result[.failed]?.count ?? 0
                let succeededItems = result[.successful] ?? []
                let succeededIDs = Set(succeededItems.compactMap { ($0 as? ICCameraFile).map(Self.itemID(for:)) })

                self.selectedAssetIDs.subtract(succeededIDs)
                self.isDeleting = false
                self.rebuildSections(from: camera)

                if let error {
                    self.statusText = "删除失败：\(error.localizedDescription)"
                    completion(false)
                } else if failedCount > 0 {
                    self.statusText = "\(failedCount) 个项目删除失败，请确认 iPhone 未锁定。"
                    completion(false)
                } else {
                    self.statusText = "删除完成。"
                    completion(true)
                }
            }
        }
    }

    private var selectedCamera: ICCameraDevice? {
        guard let selectedDeviceID else { return nil }
        return cameraByID[selectedDeviceID]
    }

    private func openSession(for camera: ICCameraDevice) {
        statusText = "正在连接 \(camera.name ?? "iPhone")..."
        camera.delegate = self
        camera.requestOpenSession(options: [
            .enumerationChronologicalOrder: true
        ]) { [weak self, weak camera] error in
            Task { @MainActor [weak self, weak camera] in
                guard let self, let camera else { return }
                if let error {
                    self.statusText = "连接失败：\(error.localizedDescription)"
                    self.updateDeviceSummaries()
                    return
                }

                self.rebuildSections(from: camera)
            }
        }
    }

    /// Coalesces the high-frequency delegate callbacks (didAdd / PTP events /
    /// rename, which fire dozens of times while a large library enumerates)
    /// into a single rebuild. Without this, every incremental event triggers a
    /// full mediaFiles scan + grid re-render, saturating the main thread and
    /// causing the "spinning / frozen" feeling right after connecting.
    private func scheduleRebuild(from camera: ICCameraDevice) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard !Task.isCancelled else { return }
            self?.rebuildSections(from: camera)
        }
    }

    private func rebuildSections(from camera: ICCameraDevice) {
        rebuildTask?.cancel()
        guard selectedDeviceID == Self.deviceID(for: camera) else { return }

        let files = (camera.mediaFiles ?? [])
            .compactMap { $0 as? ICCameraFile }
            .filter(Self.isSupportedMedia)

        var nextItemByID: [String: ICCameraFile] = [:]
        var rows: [AssetRow] = []

        for file in files {
            let id = Self.itemID(for: file)
            nextItemByID[id] = file
            rows.append((id: id, date: Self.creationDate(for: file), size: file.fileSize))
        }

        itemByID = nextItemByID
        selectedAssetIDs = selectedAssetIDs.filter { nextItemByID[$0] != nil }
        thumbnailByID = thumbnailByID.filter { nextItemByID[$0.key] != nil }
        previewURLByID = previewURLByID.filter { nextItemByID[$0.key] != nil }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { row in
            calendar.startOfDay(for: row.date)
        }

        let daySections = grouped.keys.map { day in
            DaySection(date: day, assetIDs: timeOrderedIDs(from: grouped[day, default: []]))
        }
        sections = sortedSections(daySections)

        let deviceName = camera.name ?? "iPhone"
        if camera.contentCatalogPercentCompleted < 100 {
            statusText = "\(deviceName) 正在读取相册 \(camera.contentCatalogPercentCompleted)%..."
            if camera.isLocked || camera.isAccessRestrictedAppleDevice {
                statusText += "请保持 iPhone 解锁以加快读取。"
            }
        } else {
            statusText = "\(deviceName) 已连接，找到 \(files.count) 个项目。"
        }

        updateDeviceSummaries()
    }

    /// Switches how the day sections are ordered. Only re-sorts the existing
    /// sections (each day's contents stay put) using cached `ICCameraFile`
    /// sizes, so it never re-reads the device — instant even for years of
    /// photos.
    func setSortOrder(_ order: AssetSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        sections = sortedSections(sections)
    }

    /// Within a single day, newest first; ties break on ID (descending) so the
    /// order is stable across rebuilds. Day contents never depend on `sortOrder`.
    private func timeOrderedIDs(from rows: [AssetRow]) -> [String] {
        rows.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
            .map(\.id)
    }

    /// Orders whole days per the current `sortOrder`. For size modes the day's
    /// total byte size is computed once per section (not inside the comparator),
    /// with the date as a stable tiebreak.
    private func sortedSections(_ input: [DaySection]) -> [DaySection] {
        switch sortOrder {
        case .date:
            return input.sorted { $0.date > $1.date }
        case .daySizeDescending, .daySizeAscending:
            let ascending = (sortOrder == .daySizeAscending)
            let sized: [(section: DaySection, size: Int64)] = input.map { section in
                (section: section, size: daySize(section))
            }
            let ordered = sized.sorted { lhs, rhs in
                if lhs.size != rhs.size {
                    return ascending ? (lhs.size < rhs.size) : (lhs.size > rhs.size)
                }
                return lhs.section.date > rhs.section.date
            }
            return ordered.map { $0.section }
        }
    }

    /// Total byte size of a day's items, summed from cached sizes (no device I/O).
    private func daySize(_ section: DaySection) -> Int64 {
        section.assetIDs.reduce(Int64(0)) { $0 + max(0, itemByID[$1]?.fileSize ?? 0) }
    }

    private func updateDeviceSummaries() {
        devices = cameraByID.values
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
            .map { camera in
                CameraDeviceSummary(
                    id: Self.deviceID(for: camera),
                    name: camera.name ?? "未命名设备",
                    productKind: camera.productKind ?? "Camera",
                    isLocked: camera.isLocked || camera.isAccessRestrictedAppleDevice,
                    catalogPercent: camera.contentCatalogPercentCompleted,
                    itemCount: (camera.mediaFiles ?? []).count
                )
            }
    }

    private func addCamera(_ camera: ICCameraDevice) {
        let id = Self.deviceID(for: camera)
        camera.delegate = self
        cameraByID[id] = camera
        updateDeviceSummaries()

        if selectedDeviceID == nil {
            selectDevice(id)
        }
    }

    private func removeDevice(_ device: ICDevice) {
        let id = Self.deviceID(for: device)
        cameraByID.removeValue(forKey: id)
        updateDeviceSummaries()

        if selectedDeviceID == id {
            selectedDeviceID = devices.first?.id
            itemByID = [:]
            sections = []
            selectedAssetIDs.removeAll()
            refreshSelectedDevice()
        }
    }

    private static func deviceID(for device: ICDevice) -> String {
        device.uuidString ?? device.persistentIDString ?? device.name ?? "\(ObjectIdentifier(device))"
    }

    private static func itemID(for item: ICCameraFile) -> String {
        if let originatingAssetID = item.originatingAssetID, !originatingAssetID.isEmpty {
            return originatingAssetID
        }

        let name = item.originalFilename ?? item.name ?? "item"
        let timestamp = creationDate(for: item).timeIntervalSince1970
        return "\(item.ptpObjectHandle)-\(name)-\(item.fileSize)-\(timestamp)"
    }

    private static func creationDate(for item: ICCameraFile) -> Date {
        item.exifCreationDate
            ?? item.fileCreationDate
            ?? item.creationDate
            ?? item.modificationDate
            ?? .distantPast
    }

    private static func mediaKind(for item: ICCameraFile) -> MediaKind {
        let uti = item.uti ?? ""
        if let type = UTType(uti) {
            if type.conforms(to: .movie) {
                return .video
            }
            if type.conforms(to: .image) {
                return .image
            }
        }

        let ext = (item.originalFilename ?? item.name ?? "")
            .split(separator: ".")
            .last?
            .lowercased() ?? ""

        if ["mov", "mp4", "m4v", "hevc"].contains(ext) {
            return .video
        }

        if ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng"].contains(ext) {
            return .image
        }

        return .other
    }

    private static func isSupportedMedia(_ item: ICCameraFile) -> Bool {
        switch mediaKind(for: item) {
        case .image, .video:
            return true
        case .other:
            return false
        }
    }

    private static func safeFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = filename
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "preview.media" : cleaned
    }

    /// Returns a filename that doesn't already exist in `directory`, appending
    /// " 2", " 3", … before the extension on collision (Finder-style).
    private static func uniqueFilename(_ filename: String, in directory: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(filename).path) else {
            return filename
        }

        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    private enum PreviewError: LocalizedError {
        case missingItem

        var errorDescription: String? {
            "找不到要预览的项目。"
        }
    }
}

extension PhotoLibraryViewModel: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor [weak self] in
            self?.addCamera(camera)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak self] in
            self?.removeDevice(device)
        }
    }

    nonisolated func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.devices.isEmpty {
                self.statusText = "未发现已连接的 iPhone。请用数据线连接并信任此 Mac。"
            }
        }
    }
}

extension PhotoLibraryViewModel: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor [weak self] in
            if let error {
                self?.statusText = "连接已关闭：\(error.localizedDescription)"
            }
            self?.refreshSelectedDevice()
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor [weak self] in
            self?.removeDevice(device)
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.statusText = "连接失败：\(error.localizedDescription)"
                return
            }
            guard let camera = device as? ICCameraDevice else { return }
            self.rebuildSections(from: camera)
        }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor [weak self] in
            guard let camera = device as? ICCameraDevice else { return }
            self?.rebuildSections(from: camera)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            self?.scheduleRebuild(from: camera)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            self?.scheduleRebuild(from: camera)
        }
    }

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: Error?
    ) {
        guard let thumbnail, let file = item as? ICCameraFile else { return }
        Task { @MainActor [weak self] in
            let image = NSImage(cgImage: thumbnail, size: .zero)
            self?.thumbnailByID[Self.itemID(for: file)] = image
        }
    }

    nonisolated func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: Error?
    ) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        Task { @MainActor [weak self] in
            self?.scheduleRebuild(from: camera)
        }
    }

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor [weak self] in
            self?.updateDeviceSummaries()
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor [weak self] in
            self?.scheduleRebuild(from: camera)
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor [weak self] in
            self?.rebuildSections(from: device)
        }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor [weak self] in
            self?.refreshSelectedDevice()
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor [weak self] in
            self?.refreshSelectedDevice()
        }
    }
}
