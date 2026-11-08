import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import CryptoKit
import Foundation
import ImageIO

/// Searching by what's in a photo. An optional model, downloaded once, turns each photo and each search into a list of
/// numbers on this Mac; the closer two lists are, the better the words describe the photo. Nothing leaves the Mac.
public enum Sight {
    public static let modelID = "siglip2-giant-384-8bit"
    public static let dimension = 1536
    /// The whole photo and four overlapping corners, so small subjects aren't lost when a photo is shrunk for the model.
    public static let views = 5
    public static let imageSide = 384
    public static let cornerShare = 0.6
    /// Seconds per photo for all five views on an M5. Only used until this Mac has timed itself.
    public static let typicalSecondsPerPhoto = 1.75
    public static let vectorBytes = views * dimension * MemoryLayout<UInt16>.size

    public struct Asset: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }
    public static let assets = [
        Asset(name: "PixoraSightVision.zip", bytes: 1_018_077_070, sha256: "249ac402507bf2b8f6b51be44271f79320563576b61c64a46f96a8e37fcf5abf"),
        Asset(name: "PixoraSightText.zip", bytes: 717_535_453, sha256: "7d7f5be3c566904c56ee0abf6459cc8f312e818c746d701f9e6644f2e8c1184d"),
    ]
    public static var downloadBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    public static var baseURL: URL {
        let custom = ProcessInfo.processInfo.environment["PIXORA_SIGHT_BASE"].flatMap(URL.init(string:))
        return custom ?? URL(string: "https://github.com/mithinsagar/Pixora/releases/download/search-model-1/")!
    }

    public static var directory: URL { AppPaths.models.appendingPathComponent("Sight", isDirectory: true) }
    static var visionURL: URL { directory.appendingPathComponent("PixoraSightVision.mlmodelc", isDirectory: true) }
    static var textURL: URL { directory.appendingPathComponent("PixoraSightText.mlmodelc", isDirectory: true) }
    static var tokensURL: URL { directory.appendingPathComponent("PixoraSightTokens.bin") }

    public static var isInstalled: Bool {
        let fm = FileManager.default
        return [visionURL, textURL, tokensURL].allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    /// What the model looks at: the whole frame, then each corner. Corners overlap so nothing sits only on a seam.
    public static func viewRects(width: Int, height: Int) -> [CGRect] {
        let w = Int(Double(width) * cornerShare), h = Int(Double(height) * cornerShare)
        return [CGRect(x: 0, y: 0, width: width, height: height),
                CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: width - w, y: 0, width: w, height: h),
                CGRect(x: 0, y: height - h, width: w, height: h), CGRect(x: width - w, y: height - h, width: w, height: h)]
    }

    /// Core ML aborted the app when the two models were used at once, so a search during a deep scan takes its turn.
    /// One view of a photo takes about a third of a second, which is as long as a search ever waits.
    private static let turn = NSLock()
    static func taking<T>(turn body: () throws -> T) rethrows -> T {
        turn.lock()
        defer { turn.unlock() }
        return try body()
    }

    static func loadModel(_ url: URL, units: MLComputeUnits) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try taking(turn: { try MLModel(contentsOf: url, configuration: config) })
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads photos. Only one is needed at a time, and it's big: let it go when the deep scan ends.
public final class SightVision: @unchecked Sendable {
    private let model: MLModel

    public init() throws { model = try Sight.loadModel(Sight.visionURL, units: .cpuAndGPU) }

    /// All five views as half-precision numbers, ready to store.
    public func vectors(for image: CGImage) throws -> Data {
        var out = [Float16]()
        out.reserveCapacity(Sight.views * Sight.dimension)
        for rect in Sight.viewRects(width: image.width, height: image.height) {
            guard let view = image.cropping(to: rect) else { throw CocoaError(.fileReadCorruptFile) }
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: try Self.pixels(view))])
            let prediction = try Sight.taking(turn: { try model.prediction(from: input) })
            guard let result = prediction.featureValue(for: "embedding")?.multiArrayValue,
                  result.count == Sight.dimension else { throw CocoaError(.coderValueNotFound) }
            result.withUnsafeBufferPointer(ofType: Float.self) { for v in $0 { out.append(Float16(v)) } }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    /// Stretched to the square the model expects, as it was trained: nothing is cut off.
    private static func pixels(_ image: CGImage) throws -> CVPixelBuffer {
        let side = Sight.imageSide
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &made)
        guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}

/// Reads what someone typed.
public final class SightText: @unchecked Sendable {
    private let model: MLModel
    private let tokenizer: SightTokenizer

    public init() throws {
        // On the GPU the first search took 27 seconds to get going; on the CPU it takes 0.15, and later ones about 40 ms.
        model = try Sight.loadModel(Sight.textURL, units: .cpuOnly)
        tokenizer = try SightTokenizer(contentsOf: Sight.tokensURL)
    }

    public func vector(for text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        for (i, token) in tokens.enumerated() { array[i] = NSNumber(value: token) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: array)])
        let prediction = try Sight.taking(turn: { try model.prediction(from: input) })
        guard let result = prediction.featureValue(for: "embedding")?.multiArrayValue,
              result.count == Sight.dimension else { throw CocoaError(.coderValueNotFound) }
        return result.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
    }
}

public struct SightHit: Sendable, Equatable {
    public let photoID: Int64
    public let score: Float
    /// Confident enough to call a match. The rest are shown apart, as maybes.
    public let isBest: Bool
    public init(photoID: Int64, score: Float, isBest: Bool) { self.photoID = photoID; self.score = score; self.isBest = isBest }
}

/// Every deep-scanned photo's numbers, side by side.
public struct SightLibrary: Sendable {
    public var ids: [Int64] = []
    public var vectors = Data()
    public init(ids: [Int64] = [], vectors: Data = Data()) { self.ids = ids; self.vectors = vectors }

    /// A photo scores as well as its best view. Set from labelled photos at the size Pixora keeps its previews:
    /// see "Search by what's in a photo" in the README.
    public static let bestScore: Float = 0.11
    public static let maybeScore: Float = 0.085

    public func hits(for query: [Float], best: Float = bestScore, maybe: Float = maybeScore) -> [SightHit] {
        guard query.count == Sight.dimension, vectors.count == ids.count * Sight.vectorBytes, !ids.isEmpty else { return [] }
        let chunkPhotos = 512
        var scores = [Float](repeating: 0, count: ids.count)
        var wide = [Float](repeating: 0, count: chunkPhotos * Sight.views * Sight.dimension)
        var dots = [Float](repeating: 0, count: chunkPhotos * Sight.views)
        vectors.withUnsafeBytes { raw in
            for start in stride(from: 0, to: ids.count, by: chunkPhotos) {
                let photos = min(chunkPhotos, ids.count - start), rows = photos * Sight.views, values = rows * Sight.dimension
                let from = raw.baseAddress!.advanced(by: start * Sight.vectorBytes)
                wide.withUnsafeMutableBytes { to in
                    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: from), height: 1, width: vImagePixelCount(values), rowBytes: values * 2)
                    var target = vImage_Buffer(data: to.baseAddress, height: 1, width: vImagePixelCount(values), rowBytes: values * 4)
                    vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                }
                vDSP_mmul(wide, 1, query, 1, &dots, 1, vDSP_Length(rows), 1, vDSP_Length(Sight.dimension))
                for p in 0..<photos {
                    scores[start + p] = dots[(p * Sight.views)..<((p + 1) * Sight.views)].max() ?? -1
                }
            }
        }
        return zip(ids, scores).filter { $0.1 >= maybe }.sorted { $0.1 > $1.1 }
            .map { SightHit(photoID: $0.0, score: $0.1, isBest: $0.1 >= best) }
    }
}

extension LibraryStore {
    /// Photos the deep scan hasn't reached. Private photos have no row here, so they can never be read or found.
    public func sightPending() throws -> [Int64] {
        try db.read { c in
            try c.query("""
            SELECT ph.id FROM photos ph LEFT JOIN photo_sight s ON s.photo_id = ph.id AND s.model = ?
            WHERE s.photo_id IS NULL ORDER BY ph.id
            """, [Sight.modelID]) { $0.int(0) }
        }
    }

    /// An empty `vectors` marks a photo that couldn't be read, so it isn't tried again on every deep scan.
    public func saveSight(photoID: Int64, vectors: Data) throws {
        try db.write { c in
            // The photo may have gone private or been removed while the model was reading it.
            guard try c.scalar("SELECT COUNT(*) FROM photos WHERE id = ?", [photoID]) > 0 else { return }
            try c.run("INSERT OR REPLACE INTO photo_sight(photo_id, model, vectors) VALUES(?,?,?)", photoID, Sight.modelID, vectors)
        }
    }

    public func sightCounts() throws -> (done: Int, total: Int) {
        try db.read { c in
            (Int(try c.scalar("SELECT COUNT(*) FROM photo_sight WHERE model = ?", [Sight.modelID])), Int(try c.scalar("SELECT COUNT(*) FROM photos")))
        }
    }

    public func sightLibrary() throws -> SightLibrary {
        var library = SightLibrary()
        try db.read { c in
            let rows = try c.query("SELECT photo_id, vectors FROM photo_sight WHERE model = ? AND length(vectors) = ? ORDER BY photo_id",
                                   [Sight.modelID, Sight.vectorBytes]) { ($0.int(0), $0.blob(1)) }
            library.vectors.reserveCapacity(rows.count * Sight.vectorBytes)
            for (id, data) in rows {
                guard let data else { continue }
                library.ids.append(id)
                library.vectors.append(data)
            }
        }
        return library
    }

    /// Without the model the numbers can't be compared to anything, so they go with it.
    public func clearSight() throws {
        try db.write { try $0.exec("DELETE FROM photo_sight") }
    }
}

public enum SightInstallError: LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64)
    case damaged(String)
    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            "This needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of free space. Free some up and try again."
        case .damaged(let name): "\(name) didn't arrive intact, so it wasn't installed. Please try again."
        }
    }
}

/// Fetches the model only when someone asks for it. Each file is checked against its known size and checksum before
/// it's unpacked, and nothing goes into place until everything has passed.
public final class SightInstaller: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let assets: [Sight.Asset], base: URL, destination: URL
    private let staging: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var finished: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var doneBytes: Int64 = 0
    private var cancelled = false
    private let onProgress: @Sendable (Int64) -> Void

    public init(assets: [Sight.Asset] = Sight.assets, base: URL = Sight.baseURL, destination: URL = Sight.directory,
                onProgress: @escaping @Sendable (Int64) -> Void) {
        self.assets = assets; self.base = base; self.destination = destination; self.onProgress = onProgress
        staging = destination.deletingLastPathComponent().appendingPathComponent("SightIncoming", isDirectory: true)
    }

    public func run() async throws {
        let fm = FileManager.default
        let total = assets.reduce(0) { $0 + $1.bytes }, needed = total * 2 + (200 << 20)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let free = (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free >= needed else { throw SightInstallError.notEnoughSpace(needed: needed) }
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging); session?.invalidateAndCancel() }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        for asset in assets {
            let zip = try await fetch(asset, session: session)
            let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard Int64(size) == asset.bytes, try Sight.sha256(of: zip) == asset.sha256 else { throw SightInstallError.damaged(asset.name) }
            try Self.unzip(zip, into: staging)
            try fm.removeItem(at: zip)
            lock.withLock { doneBytes += asset.bytes }
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
    }

    public func cancel() {
        let running = lock.withLock { () -> URLSessionDownloadTask? in cancelled = true; return task }
        running?.cancel()
    }

    /// Picks up where it stopped if the connection drops part-way.
    private func fetch(_ asset: Sight.Asset, session: URLSession) async throws -> URL {
        var resume: Data?
        for attempt in 0..<6 {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    let next = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: base.appendingPathComponent(asset.name))
                    let stopped = lock.withLock { () -> Bool in
                        if !cancelled { finished = continuation; task = next }
                        return cancelled
                    }
                    if stopped { continuation.resume(throwing: URLError(.cancelled)) } else { next.resume() }
                }
            } catch {
                let nsError = error as NSError
                resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if lock.withLock({ cancelled }) || attempt == 5 { throw error }
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private static func unzip(_ zip: URL, into folder: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SightInstallError.damaged(zip.lastPathComponent) }
        #else
        // Search by content is a Mac feature for now: the model is 1.7 GB and needs ditto to unpack.
        throw SightInstallError.damaged(zip.lastPathComponent)
        #endif
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in defer { finished = nil }; return finished }
        continuation?.resume(with: result)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(lock.withLock { doneBytes } + totalBytesWritten)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(URLError(.fileDoesNotExist))); return
        }
        let kept = staging.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? UUID().uuidString)
        do {
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch { finish(.failure(error)) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

public enum SightQuery {
    /// Names you've given people narrow the search; everything else describes the photo. "asha birthday cake" → Asha, "birthday cake".
    public static func split(_ text: String, people: [(id: Int64, name: String)]) -> (people: [Int64], words: String) {
        var rest = text, found: [Int64] = []
        for person in people.sorted(by: { $0.name.count > $1.name.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: person.name) + "\\b"
            guard let range = rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            found.append(person.id)
            rest.replaceSubrange(range, with: " ")
        }
        return (found, rest.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
