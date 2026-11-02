import Foundation
import CoreGraphics

// MARK: - Volumes

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String?
    public let uuid: String?
    public let isRemovable: Bool
    public let isInternal: Bool
    public let availableBytes: Int64?
    public let totalBytes: Int64?
    public let format: String?
    /// Path of the inspected folder relative to the volume root ("" for the root itself).
    public let relativePath: String?
    /// The volume has a DCIM folder — almost certainly a camera card.
    public let looksLikeCameraCard: Bool

    static let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                            .volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey,
                                            .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
                                            .volumeURLKey, .volumeIsRootFileSystemKey]

    public init(for url: URL) {
        let v = try? url.resourceValues(forKeys: Self.keys)
        let root = v?.volume ?? URL(fileURLWithPath: "/")
        self.url = root
        name = v?.volumeName
        uuid = v?.volumeUUIDString
        isRemovable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
        isInternal = v?.volumeIsInternal ?? true
        availableBytes = v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
        totalBytes = v?.volumeTotalCapacity.map(Int64.init)
        format = v?.volumeLocalizedFormatDescription
        let rp = root.standardizedFileURL.path, up = url.standardizedFileURL.path
        if up == rp { relativePath = "" }
        else if up.hasPrefix(rp == "/" ? "/" : rp + "/") { relativePath = String(up.dropFirst(rp == "/" ? 1 : rp.count + 1)) }
        else { relativePath = nil }
        looksLikeCameraCard = FileManager.default.fileExists(atPath: root.appendingPathComponent("DCIM").path)
    }

    /// External drives and cards currently mounted (not the startup disk, not hidden system volumes).
    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: keys)
            if v?.volumeIsRootFileSystem == true { return nil }
            let info = VolumeInfo(for: u)
            guard info.isRemovable || !info.isInternal else { return nil }
            return info
        }
    }
}

// MARK: - Enumeration & preview

/// One photo to scan. RAW+JPEG pairs become one entry: the JPEG/HEIC is analysed (fast) and the RAW is a sibling.
public struct ScanFile: Hashable, Sendable {
    public let relPath: String
    public let filename: String
    public let ext: String
    public let size: Int64
    public let mtime: Double
    public let siblings: [String]
    public var folder: String { (relPath as NSString).deletingLastPathComponent }
}

public struct ScanPreview: Sendable {
    public struct Folder: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let path: String
        public var photos: Int
        public var bytes: Int64
    }
    public let root: URL
    public var files: [ScanFile] = []
    public var folders: [Folder] = []
    /// Count of files by upper-cased extension, including RAW siblings.
    public var formats: [String: Int] = [:]
    public var rawPairs = 0
    public var totalBytes: Int64 = 0
    /// Image files macOS cannot decode on this Mac.
    public var unsupported: [String] = []
    public var videosSkipped = 0
    public var otherSkipped = 0
    public var unreadable: [String] = []
}

public enum FileScanner {
    /// Walk a folder (skipping hidden files and packages such as .photoslibrary) and build a scan preview.
    public static func preview(root: URL, isCancelled: () -> Bool = { false }) -> ScanPreview {
        var preview = ScanPreview(root: root)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        var items: [(rel: String, ext: String, size: Int64, mtime: Double)] = []
        let rootPath = root.standardizedFileURL.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                    errorHandler: { url, _ in preview.unreadable.append(url.lastPathComponent); return true }) else { return preview }
        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if FileTypes.videoExtensions.contains(ext) { preview.videosSkipped += 1; continue }
            guard ImageLoader.isImageFile(ext: ext) else { preview.otherSkipped += 1; continue }
            if !ImageLoader.canDecode(ext: ext) { preview.unsupported.append(rel); continue }
            items.append((rel, ext, Int64(v.fileSize ?? 0), v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        // Pair RAW with a processed file of the same name in the same folder.
        let groups = Dictionary(grouping: items) { ($0.rel as NSString).deletingPathExtension.lowercased() }
        var folderMap: [String: ScanPreview.Folder] = [:]
        for (_, group) in groups {
            let primary = group.first { FileTypes.processedExtensions.contains($0.ext) } ?? group.first { FileTypes.isRAW(ext: $0.ext) } ?? group[0]
            let others = group.filter { $0.rel != primary.rel }
            if others.contains(where: { FileTypes.isRAW(ext: $0.ext) }) && !FileTypes.isRAW(ext: primary.ext) { preview.rawPairs += 1 }
            let file = ScanFile(relPath: primary.rel, filename: (primary.rel as NSString).lastPathComponent, ext: primary.ext,
                                size: primary.size, mtime: primary.mtime, siblings: others.map(\.rel).sorted())
            preview.files.append(file)
            let bytes = group.reduce(Int64(0)) { $0 + $1.size }
            preview.totalBytes += bytes
            for g in group { preview.formats[g.ext.uppercased(), default: 0] += 1 }
            folderMap[file.folder, default: .init(path: file.folder, photos: 0, bytes: 0)].photos += 1
            folderMap[file.folder]!.bytes += bytes
        }
        preview.files.sort { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
        preview.folders = folderMap.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return preview
    }
}

// MARK: - Scan engine

/// Suspends workers while paused.
public actor PauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func setPaused(_ p: Bool) {
        paused = p
        if !p { waiters.forEach { $0.resume() }; waiters.removeAll() }
    }
    public func wait() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable { case scanning, grouping, finished, cancelled, failed }
    public var phase: Phase = .scanning
    public var total = 0
    public var processed = 0
    public var newPhotos = 0
    public var skippedUnchanged = 0
    public var facesFound = 0
    public var errors: [(file: String, message: String)] = []
    public var currentFile = ""
    public var photosPerSecond: Double = 0
    public var recentFaceThumbs: [Data] = []
    /// Running count of thumbnails added, so each face in `recentFaceThumbs` keeps a stable identity.
    public var thumbSerial = 0
    public var importID: Int64?
    public init() {}

    public var fraction: Double { total == 0 ? 0 : Double(processed) / Double(total) }
    public var secondsRemaining: Double? {
        guard photosPerSecond > 0.05, processed >= 5 else { return nil }
        return Double(total - processed) / photosPerSecond
    }
}

public final class ScanEngine: @unchecked Sendable {
    public let store: LibraryStore
    public let embedder: FaceEmbedder
    public let thresholds: MatchThresholds
    public let gate = PauseGate()
    /// Long edge used for face detection and alignment. Large photos are also scanned in tiles by SCRFD.
    /// When set up, private photos are skipped on rescans and private people's matches are routed into it.
    public var vault: PrivateVault?
    public var analysisLongEdge = AppSettings.analysisLongEdge
    public var workers = AppSettings.scanWorkers

    public init(store: LibraryStore, embedder: FaceEmbedder, thresholds: MatchThresholds) {
        self.store = store; self.embedder = embedder; self.thresholds = thresholds
    }

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var next = 0
        var progress = ScanProgress()
        var rateStart = Date()
        var rateCount = 0
    }
    private let current = Shared()

    public func pause() async { await gate.setPaused(true) }
    public func resume() async {
        current.lock.withLock { current.rateStart = Date(); current.rateCount = 0 }
        await gate.setPaused(false)
    }

    /// Scan files of a source. Unchanged files already scanned with the same model are skipped, so re-scans
    /// and resumed scans never duplicate records. Cancelling keeps everything scanned so far.
    public func run(source: Source, files: [ScanFile], onProgress: @escaping @Sendable (ScanProgress) -> Void) async -> ScanProgress {
        let shared = current
        shared.lock.withLock {
            shared.next = 0
            shared.progress = ScanProgress()
            shared.rateStart = Date()
            shared.rateCount = 0
        }
        shared.progress.total = files.count
        let importID = (try? store.startImport(sourceID: source.id, total: files.count)) ?? -1
        shared.progress.importID = importID
        let existing = (try? store.existingPhotos(sourceID: source.id)) ?? [:]
        let privateTokens = vault?.isSetUp == true ? (vault?.privateTokens() ?? []) : []
        let analyzer = FaceAnalyzer(embedder: embedder)
        let root = source.url
        onProgress(shared.progress)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, workers) {
                group.addTask { [self] in
                    while true {
                        await gate.wait()
                        if Task.isCancelled { return }
                        let i = shared.lock.withLock { () -> Int in defer { shared.next += 1 }; return shared.next }
                        guard i < files.count else { return }
                        let file = files[i]
                        // Already in Private Space: don't analyse or re-add it.
                        let isPrivate = !privateTokens.isEmpty && (vault.map { privateTokens.contains($0.pathToken(sourceID: source.id, relPath: file.relPath)) } ?? false)
                        let outcome: Outcome = isPrivate ? .skipped : autoreleasepool { process(file, root: root, sourceID: source.id, importID: importID, existing: existing[file.relPath], analyzer: analyzer) }
                        let p = shared.lock.withLock { () -> ScanProgress in
                        var p = shared.progress
                        p.processed += 1
                        p.currentFile = file.relPath
                        switch outcome {
                        case .skipped: p.skippedUnchanged += 1
                        case let .scanned(faces, thumbs):
                            p.newPhotos += 1; p.facesFound += faces
                            p.recentFaceThumbs = Array((thumbs + p.recentFaceThumbs).prefix(24))
                            p.thumbSerial += thumbs.count
                        case let .failed(msg): p.errors.append((file.relPath, msg))
                        }
                        // Rate over the time since the last resume, counting only photos actually analysed.
                        if case .scanned = outcome { shared.rateCount += 1 }
                        if case .failed = outcome { shared.rateCount += 1 }
                        let elapsed = Date().timeIntervalSince(shared.rateStart)
                        p.photosPerSecond = elapsed > 1 ? Double(shared.rateCount) / elapsed : 0
                        shared.progress = p
                        return p
                        }
                        onProgress(p)
                    }
                }
            }
        }

        var p = shared.progress
        let cancelled = Task.isCancelled
        p.phase = .grouping
        onProgress(p)
        // Grouping runs even after cancel so whatever was scanned is usable.
        if let vault, vault.isSetUp {
            // Another copy of a photo that's already private (same fingerprint, different place) goes straight in.
            let fresh = (try? store.db.read { try $0.query("SELECT id, fingerprint FROM photos WHERE import_id = ? AND fingerprint IS NOT NULL", [importID]) { ($0.int(0), $0.text(1)) } }) ?? []
            let duplicates = fresh.filter { privateTokens.contains(vault.fingerprintToken($0.1)) }.map(\.0)
            try? vault.makePhotosPrivate(duplicates)
            try? vault.matchAndRoute(embedderID: embedder.id, thresholds: thresholds)
        } else {
            try? store.runMatching(embedderID: embedder.id, thresholds: thresholds)
        }
        // Eyes / sharpness / bursts, from the cached crops and thumbnails just written.
        try? Enrichment.run(store: store)
        p.phase = cancelled ? .cancelled : .finished
        try? store.finishImport(importID, status: cancelled ? "cancelled" : (p.errors.isEmpty ? "complete" : "complete with errors"),
                                new: p.newPhotos, skipped: p.skippedUnchanged, faces: p.facesFound, errors: p.errors.count)
        onProgress(p)
        return p
    }

    enum Outcome { case skipped, scanned(Int, [Data]), failed(String) }

    private func process(_ file: ScanFile, root: URL, sourceID: Int64, importID: Int64, existing: LibraryStore.ExistingPhoto?, analyzer: FaceAnalyzer) -> Outcome {
        if let e = existing, e.size == file.size, abs(e.mtime - file.mtime) < 1, e.scanState == 1, e.embedder == embedder.id {
            try? store.markSkipped(photoID: e.id, importID: importID)
            return .skipped
        }
        let url = root.appendingPathComponent(file.relPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return record(file, importID, sourceID, PhotoMetadata(), nil, [], error: "File could not be read (card removed or permission denied).")
        }
        let meta = ImageLoader.metadata(at: url)
        let fingerprint = Fingerprint.quick(url: url, size: file.size)
        guard let image = ImageLoader.image(at: url, maxPixel: analysisLongEdge) else {
            return record(file, importID, sourceID, meta, fingerprint, [], error: "macOS could not decode this image.")
        }
        let faces: [DetectedFace]
        do {
            faces = try analyzer.analyze(image, originalLongEdge: max(meta.width ?? 0, meta.height ?? 0) > 0 ? max(meta.width!, meta.height!) : nil)
        } catch {
            return record(file, importID, sourceID, meta, fingerprint, [], error: "Face detection failed: \(error.localizedDescription)")
        }
        let outcome = record(file, importID, sourceID, meta, fingerprint, faces, error: nil, image: image)
        return outcome
    }

    private func record(_ file: ScanFile, _ importID: Int64, _ sourceID: Int64, _ meta: PhotoMetadata, _ fp: String?,
                        _ faces: [DetectedFace], error: String?, image: CGImage? = nil) -> Outcome {
        do {
            let id = try store.recordScan(sourceID: sourceID, importID: importID, file: file, metadata: meta, fingerprint: fp,
                                          faces: faces, embedderID: embedder.id, error: error)
            if let image, let small = ImageLoader.downscale(image, maxPixel: 640) {
                if AppSettings.keepPreviews {
                    if let jpg = ImageLoader.jpegData(small, quality: 0.8) { try? jpg.write(to: AppPaths.thumbnail(photoID: id), options: .atomic) }
                } else {
                    // No preview kept: compute what burst grouping needs now, from memory.
                    let print = Enrichment.featurePrint(small).map(Vector.data)
                    try? store.db.write { try $0.run("UPDATE photos SET print = ?, enriched = 1 WHERE id = ?", print, id) }
                }
            }
        } catch {
            return .failed("Could not save to library: \(error)")
        }
        if let error { return .failed(error) }
        return .scanned(faces.count, faces.compactMap(\.thumbJPEG))
    }
}

extension ImageLoader {
    public static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
