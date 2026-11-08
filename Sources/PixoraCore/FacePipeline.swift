import Foundation
import Vision
import CoreML
import CoreGraphics
import Accelerate

// MARK: - Embedders

/// How a face crop is prepared for an embedder.
public enum Alignment: Sendable, Equatable {
    /// Square crop around the detector box, rotated so the eyes are level (FaceNet / Basic).
    case eyeLevel(scale: CGFloat)
    /// Similarity transform of 5 landmarks onto the standard ArcFace 112×112 template.
    case arcface5
}

/// Turns an aligned face crop into an identity vector. Vectors from different embedders are not comparable,
/// so every stored face records which embedder produced it.
public protocol FaceEmbedder: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var detail: String { get }
    var inputSide: Int { get }
    var alignment: Alignment { get }
    var thresholds: MatchThresholds { get }
    func embed(_ crop: CGImage) throws -> [Float]
}

extension FaceEmbedder {
    public var cropScale: CGFloat { if case let .eyeLevel(s) = alignment { return s }; return 1 }
}

/// Similarity thresholds (cosine) for one embedder. Calibrated with `pixora-eval` — see README.
public struct MatchThresholds: Sendable, Equatable {
    /// At or above: assign automatically as a certain match.
    public var certain: Float
    /// At or above (but below `certain`): suggest, and ask the user.
    public var suggest: Float
    /// Two unassigned faces at or above this are grouped together.
    public var group: Float
    /// Shift all thresholds (positive = stricter).
    public func adjusted(by delta: Float) -> MatchThresholds {
        MatchThresholds(certain: certain + delta, suggest: suggest + delta, group: group + delta)
    }
}

public enum EmbedderError: Error, LocalizedError {
    case modelMissing, badOutput, featurePrintFailed
    public var errorDescription: String? {
        switch self {
        case .modelMissing: "The face-recognition model is not installed."
        case .badOutput: "The face model returned an unexpected output."
        case .featurePrintFailed: "Vision could not compute a feature print."
        }
    }
}

/// A Core ML face-embedding model: ArcFace R50 (default) or FaceNet, converted by the scripts in tools/.
/// Runs on-device on the Neural Engine / GPU; no data leaves the Mac.
extension MLModel {
    /// Neural Engine and GPU on real hardware. The iOS Simulator emulates the GPU and returned all-zero face
    /// templates from ArcFace there, so simulator builds run the models on the CPU.
    static var faceComputeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .all
        #endif
    }
}

public final class CoreMLFaceEmbedder: FaceEmbedder {
    public let id: String
    public let displayName: String
    public var detail: String { "Core ML model \(modelURL.deletingPathExtension().lastPathComponent). 512-number face template per face." }
    public let inputSide: Int
    public let alignment: Alignment
    public let thresholds: MatchThresholds
    public let modelURL: URL
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let constraint: MLImageConstraint
    private let lock = NSLock()

    public init(compiledModelURL: URL) throws {
        modelURL = compiledModelURL
        let config = MLModelConfiguration()
        config.computeUnits = MLModel.faceComputeUnits
        model = try MLModel(contentsOf: compiledModelURL, configuration: config)
        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let c = input.imageConstraint,
              let output = desc.outputDescriptionsByName.values.first(where: { $0.type == .multiArray }) else {
            throw EmbedderError.badOutput
        }
        inputName = input.name
        outputName = output.name
        constraint = c
        inputSide = c.pixelsWide
        let meta = desc.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        // Metadata keys keep the app's original name ("rollcall.*"): they are baked into the converted models.
        id = meta["rollcall.embedderID"] ?? "coreml-\(compiledModelURL.deletingPathExtension().lastPathComponent)"
        if meta["rollcall.alignment"] == "arcface5" {
            alignment = .arcface5
        } else {
            alignment = .eyeLevel(scale: CGFloat(Double(meta["rollcall.cropScale"] ?? "") ?? 1.3))
        }
        switch id {
        case "arcface-r50-w600k": thresholds = Calibration.arcFace; displayName = "ArcFace (on-device)"
        case "facenet-vggface2-512": thresholds = Calibration.faceNet; displayName = "FaceNet (on-device)"
        default: thresholds = Calibration.unknownModel; displayName = "Custom model (on-device)"
        }
    }

    public func embed(_ crop: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(cgImage: crop, constraint: constraint, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        let out = try lock.withLock { try model.prediction(from: provider) }
        guard let array = out.featureValue(for: outputName)?.multiArrayValue else { throw EmbedderError.badOutput }
        var v = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { v[i] = array[i].floatValue }
        // A broken run (seen in the iOS Simulator's GPU emulation) returns all zeros. Storing that would make
        // every face look identical to matching, so treat it as "no template" instead.
        guard v.contains(where: { $0 != 0 && $0.isFinite }) else { throw EmbedderError.badOutput }
        return Vector.normalized(v)
    }

    /// Finds an installed recognition model, preferring ArcFace: bundled with the app, or added in Settings.
    public static func locateModel() -> URL? {
        let fm = FileManager.default
        let preferred = ["ArcFaceR50", "FaceNet512"]
        let dirs = [Bundle.main.resourceURL, AppPaths.models].compactMap { $0 }
        for name in preferred {
            for dir in dirs {
                let u = dir.appendingPathComponent(name + ".mlmodelc")
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        // A user-installed .mlpackage/.mlmodel is compiled once and cached.
        let items = (try? fm.contentsOfDirectory(at: AppPaths.models, includingPropertiesForKeys: nil)) ?? []
        if let compiled = items.first(where: { $0.pathExtension == "mlmodelc" && !$0.lastPathComponent.hasPrefix("SCRFD") }) { return compiled }
        if let raw = items.first(where: { ["mlpackage", "mlmodel"].contains($0.pathExtension) && !$0.lastPathComponent.hasPrefix("SCRFD") }) {
            return try? install(modelAt: raw)
        }
        return nil
    }

    /// Compile a Core ML model into the app's Models folder. The source file is not modified.
    @discardableResult
    public static func install(modelAt url: URL) throws -> URL {
        let compiled = try MLModel.compileModel(at: url)
        let dest = AppPaths.models.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mlmodelc")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: compiled, to: dest)
        return dest
    }
}

/// Fallback when no face model is installed: Apple Vision's generic image feature print on the face crop.
/// It is not trained to tell people apart. Labelled "Basic" in the UI.
public final class VisionFeaturePrintEmbedder: FaceEmbedder {
    public let id = "vision-featureprint"
    public let displayName = "Basic (Apple Vision feature print)"
    public let detail = "Built into macOS but not designed to tell people apart. Measured on LFW: 81% verification accuracy (ArcFace: 99%+). Grouping barely works and most suggestions need correcting."
    public let inputSide = 224
    public let alignment = Alignment.eyeLevel(scale: 1.2)
    public let thresholds = Calibration.visionFeaturePrint
    public init() {}

    public func embed(_ crop: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: crop).perform([request])
        guard let obs = request.results?.first else { throw EmbedderError.featurePrintFailed }
        var v = [Float](repeating: 0, count: obs.elementCount)
        obs.data.withUnsafeBytes { raw in
            if obs.elementType == .float {
                for i in 0..<obs.elementCount { v[i] = raw.load(fromByteOffset: i * 4, as: Float.self) }
            } else {
                for i in 0..<obs.elementCount { v[i] = Float(raw.load(fromByteOffset: i * 8, as: Double.self)) }
            }
        }
        return Vector.normalized(v)
    }
}

public enum Embedders {
    /// The best available embedder: ArcFace if installed, then FaceNet, otherwise the Basic fallback.
    public static func makeDefault() -> FaceEmbedder {
        if let url = CoreMLFaceEmbedder.locateModel(), let e = try? CoreMLFaceEmbedder(compiledModelURL: url) { return e }
        return VisionFeaturePrintEmbedder()
    }
}

// MARK: - Detection

/// A face found by a detector, in the analysed image's pixel space (origin top-left).
public struct RawFace {
    public var box: CGRect
    /// Five landmarks: image-left eye, image-right eye, nose tip, left mouth corner, right mouth corner.
    public var landmarks: [CGPoint]?
    public var score: Float
}

public protocol FaceDetector: AnyObject {
    var name: String { get }
    func detect(_ image: CGImage) throws -> [RawFace]
}

/// InsightFace SCRFD-10G, converted by tools/convert_scrfd.py. Finds smaller, more side-on and darker faces than
/// Vision and returns the 5 landmarks ArcFace was trained with. Large photos are scanned whole and in 4
/// overlapping tiles, so faces in big group shots are not lost to downscaling.
public final class SCRFDDetector: FaceDetector {
    public let name = "SCRFD-10G (on-device)"
    private let model: MLModel
    private let constraint: MLImageConstraint
    private let lock = NSLock()
    public var scoreThreshold: Float = 0.5
    public var nmsIoU: CGFloat = 0.4
    private static let side = 640

    public init(compiledModelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = MLModel.faceComputeUnits
        model = try MLModel(contentsOf: compiledModelURL, configuration: config)
        guard let c = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw EmbedderError.badOutput }
        constraint = c
    }

    public static func locate() -> URL? {
        [Bundle.main.resourceURL, AppPaths.models].compactMap { $0?.appendingPathComponent("SCRFD10G.mlmodelc") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func detect(_ image: CGImage) throws -> [RawFace] {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var faces = try pass(image, offset: .zero)
        if max(W, H) >= 1400 && AppSettings.tiledDetection {
            let tw = (W * 0.6).rounded(), th = (H * 0.6).rounded()
            for ox in [0, W - tw] {
                for oy in [0, H - th] {
                    guard let tile = image.cropping(to: CGRect(x: ox, y: oy, width: tw, height: th)) else { continue }
                    faces += try pass(tile, offset: CGPoint(x: ox, y: oy))
                }
            }
        }
        return Self.nms(faces, iou: nmsIoU)
    }

    /// One detector pass on a letterboxed 640×640 copy (image placed top-left, as InsightFace does).
    private func pass(_ image: CGImage, offset: CGPoint) throws -> [RawFace] {
        let side = Self.side
        let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let nw = CGFloat(image.width) * scale, nh = CGFloat(image.height) * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(side) - nh, width: nw, height: nh))
        guard let letterboxed = ctx.makeImage() else { return [] }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(cgImage: letterboxed, constraint: constraint, options: nil)])
        let out = try lock.withLock { try model.prediction(from: input) }

        var faces: [RawFace] = []
        for stride in [8, 16, 32] {
            guard let scores = out.featureValue(for: "score\(stride)")?.multiArrayValue,
                  let boxes = out.featureValue(for: "bbox\(stride)")?.multiArrayValue,
                  let kps = out.featureValue(for: "kps\(stride)")?.multiArrayValue else { continue }
            let fw = side / stride
            let s = Float(stride)
            let n = scores.count
            let sp = Self.floats(scores), bp = Self.floats(boxes), kp = Self.floats(kps)
            for i in 0..<n where sp[i] >= scoreThreshold {
                let cell = i / 2
                let cx = Float(cell % fw) * s, cy = Float(cell / fw) * s
                let x1 = cx - bp[i * 4] * s, y1 = cy - bp[i * 4 + 1] * s
                let x2 = cx + bp[i * 4 + 2] * s, y2 = cy + bp[i * 4 + 3] * s
                func map(_ x: Float, _ y: Float) -> CGPoint {
                    CGPoint(x: CGFloat(x) / scale + offset.x, y: CGFloat(y) / scale + offset.y)
                }
                let p1 = map(x1, y1), p2 = map(x2, y2)
                let marks = (0..<5).map { k in map(cx + kp[i * 10 + k * 2] * s, cy + kp[i * 10 + k * 2 + 1] * s) }
                faces.append(RawFace(box: CGRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y), landmarks: marks, score: sp[i]))
            }
        }
        return faces
    }

    /// Compact row-major copy of an [N, C] output. Core ML may pad rows, so read through the strides.
    private static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let rows = shape.dropLast().reduce(1, *), cols = shape.last ?? 1
        let rowStride = strides.count >= 2 ? strides[strides.count - 2] : cols, colStride = strides.last ?? 1
        var out = [Float](repeating: 0, count: rows * cols)
        if a.dataType == .float32 {
            a.withUnsafeBufferPointer(ofType: Float.self) { p in
                for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = p[r * rowStride + c * colStride] } }
            }
        } else {
            for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = a[r * rowStride + c * colStride].floatValue } }
        }
        return out
    }

    static func nms(_ faces: [RawFace], iou threshold: CGFloat) -> [RawFace] {
        var kept: [RawFace] = []
        for f in faces.sorted(by: { $0.score > $1.score }) {
            let overlaps = kept.contains { k in
                let inter = k.box.intersection(f.box)
                guard !inter.isNull else { return false }
                let i = inter.width * inter.height
                let u = k.box.width * k.box.height + f.box.width * f.box.height - i
                // Also drop a box mostly inside a stronger one (a face cut by a tile edge).
                return i / u > threshold || i / min(k.box.width * k.box.height, f.box.width * f.box.height) > 0.7
            }
            if !overlaps { kept.append(f) }
        }
        return kept
    }
}

/// Apple Vision detector (fallback when SCRFD isn't installed). Derives the same 5 landmarks from Vision's
/// landmark regions so ArcFace alignment still works.
public final class VisionFaceDetector: FaceDetector {
    public let name = "Apple Vision"
    public init() {}
    public func detect(_ image: CGImage) throws -> [RawFace] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let size = CGSize(width: W, height: H)
        return (request.results ?? []).map { obs in
            let bb = obs.boundingBox
            let box = CGRect(x: bb.minX * W, y: (1 - bb.maxY) * H, width: bb.width * W, height: bb.height * H)
            func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: H - $0.y) } }
            func mean(_ p: [CGPoint]) -> CGPoint { CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)) }
            var marks: [CGPoint]?
            let l = pts(obs.landmarks?.leftEye), r = pts(obs.landmarks?.rightEye)
            let nose = pts(obs.landmarks?.noseCrest) + pts(obs.landmarks?.nose)
            let lips = pts(obs.landmarks?.outerLips)
            if !l.isEmpty, !r.isEmpty, !nose.isEmpty, lips.count >= 2 {
                let eyes = [mean(l), mean(r)].sorted { $0.x < $1.x }
                let tip = nose.max { $0.y < $1.y }!
                marks = [eyes[0], eyes[1], tip, lips.min { $0.x < $1.x }!, lips.max { $0.x < $1.x }!]
            }
            return RawFace(box: box, landmarks: marks, score: obs.confidence)
        }
    }
}

/// SCRFD first; Apple Vision as a second opinion. Faces only Vision finds (often very dark or unusual ones) are
/// added, slightly down-weighted because Vision's landmarks align less precisely.
public final class CombinedDetector: FaceDetector {
    public let name = "SCRFD-10G + Apple Vision (on-device)"
    let primary: SCRFDDetector
    let secondary = VisionFaceDetector()
    init(primary: SCRFDDetector) { self.primary = primary }

    public func detect(_ image: CGImage) throws -> [RawFace] {
        let main = try primary.detect(image)
        let extra = ((try? secondary.detect(image)) ?? []).filter { v in
            !main.contains { m in
                let i = m.box.intersection(v.box)
                return !i.isNull && (i.width * i.height) / min(m.box.width * m.box.height, v.box.width * v.box.height) > 0.3
            }
        }.map { RawFace(box: $0.box, landmarks: $0.landmarks, score: min($0.score, 0.8) * 0.8) }
        return main + extra
    }
}

public enum Detectors {
    public static func makeDefault() -> FaceDetector {
        if let url = SCRFDDetector.locate(), let d = try? SCRFDDetector(compiledModelURL: url) { return CombinedDetector(primary: d) }
        return VisionFaceDetector()
    }
}

// MARK: - Analysis

public struct DetectedFace {
    /// Normalised, top-left origin, in the upright image.
    public var rect: CGRect
    /// Face box size in pixels of the original photo (long edge of the box).
    public var pixelSize: Double
    /// 0…1: detector confidence × how frontal the face is × enough resolution. Low-quality faces are never
    /// matched automatically — they go to Review.
    public var quality: Double?
    public var embedding: [Float]?
    public var thumbJPEG: Data?
}

public struct FaceAnalyzer {
    public let embedder: FaceEmbedder
    public let detector: FaceDetector
    /// Faces smaller than this (in analysed pixels) are recorded but not used for recognition.
    public var minRecognizableSide: CGFloat = 36

    public init(embedder: FaceEmbedder, detector: FaceDetector = Detectors.makeDefault()) {
        self.embedder = embedder
        self.detector = detector
    }

    public static let thumbSide = 320

    /// The ArcFace 112×112 reference positions for the 5 landmarks.
    static let arcTemplate: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Detect, align and embed every face in an upright image.
    public func analyze(_ original: CGImage, originalLongEdge: Int? = nil) throws -> [DetectedFace] {
        let image = ImageLoader.brightenedIfDark(original)   // low-light photos: lift exposure for analysis only
        let raws = try detector.detect(image)
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let toOriginal = CGFloat(originalLongEdge ?? max(image.width, image.height)) / max(W, H)
        return raws.compactMap { raw in
            let box = raw.box.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !box.isNull, box.width > 4, box.height > 4 else { return nil }
            let side = max(box.width, box.height)
            var face = DetectedFace(rect: CGRect(x: box.minX / W, y: box.minY / H, width: box.width / W, height: box.height / H),
                                    pixelSize: Double(side * toOriginal))
            let frontal = raw.landmarks.map(Self.frontalness) ?? 0.6
            let resolution = min(1, Double(side) / 80)
            face.quality = Double(raw.score) * frontal * resolution

            // Thumbnail: upright face with some context. 320 px so grids stay sharp on Retina screens.
            let t = CGFloat(Self.thumbSide)
            if let marks = raw.landmarks {
                let thumbTemplate = Self.arcTemplate.map { CGPoint(x: ($0.x - 56) * t / 112 / 1.8 + t / 2, y: ($0.y - 56) * t / 112 / 1.8 + t / 2) }
                if let img = Self.warp(image, from: marks, to: thumbTemplate, side: Self.thumbSide) { face.thumbJPEG = ImageLoader.jpegData(img, quality: 0.85) }
            } else if let img = Self.eyeLevelCrop(image, box: box, landmarks: nil, scale: 1.7, output: Self.thumbSide) {
                face.thumbJPEG = ImageLoader.jpegData(img, quality: 0.85)
            }

            guard side >= minRecognizableSide else { return face }
            if let crop = alignedCrop(raw, in: image) { face.embedding = try? embedder.embed(crop) }
            return face
        }
    }

    /// The crop the embedder sees for a detected face (nil if it can't be aligned).
    public func alignedCrop(_ raw: RawFace, in image: CGImage) -> CGImage? {
        switch embedder.alignment {
        case .arcface5:
            guard let marks = raw.landmarks else { return nil }  // can't align properly → not used for recognition
            let k = CGFloat(embedder.inputSide) / 112
            return Self.warp(image, from: marks, to: Self.arcTemplate.map { CGPoint(x: $0.x * k, y: $0.y * k) }, side: embedder.inputSide)
        case let .eyeLevel(scale):
            return Self.eyeLevelCrop(image, box: raw.box, landmarks: raw.landmarks, scale: scale, output: embedder.inputSide)
        }
    }

    /// 1 for a frontal face, falling towards 0 for a full profile (nose far off the eye midline).
    static func frontalness(_ m: [CGPoint]) -> Double {
        guard m.count == 5 else { return 0.6 }
        let eyeMid = CGPoint(x: (m[0].x + m[1].x) / 2, y: (m[0].y + m[1].y) / 2)
        let eyeDist = hypot(m[1].x - m[0].x, m[1].y - m[0].y)
        guard eyeDist > 1 else { return 0.2 }
        let offset = abs(m[2].x - eyeMid.x) / eyeDist   // ≈0 frontal, ≈0.5+ strong profile
        return max(0.1, min(1, 1.15 - Double(offset) * 1.5))
    }

    /// Least-squares similarity transform (rotation, uniform scale, translation) taking `src` onto `dst`.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            num1 += sx * dx + sy * dy
            num2 += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        let a = den > 0 ? num1 / den : 1, b = den > 0 ? num2 / den : 0
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
    }

    /// Render `side`×`side` pixels where the landmarks land on `template` (both in top-left pixel coordinates).
    static func warp(_ image: CGImage, from marks: [CGPoint], to template: [CGPoint], side: Int) -> CGImage? {
        let m = similarity(from: marks, to: template)
        let H = CGFloat(image.height), S = CGFloat(side)
        // CG draws with a bottom-left origin: flip into top-left image space, apply m, flip back for the output.
        let flipImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S)
        let t = flipImage.concatenating(m).concatenating(flipOut)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Square crop around the box (top-left pixel coords), rotated so the eye line is level.
    static func eyeLevelCrop(_ image: CGImage, box: CGRect, landmarks: [CGPoint]?, scale: CGFloat, output: Int) -> CGImage? {
        let H = CGFloat(image.height)
        var angle: CGFloat = 0
        if let m = landmarks, m.count >= 2 { angle = -atan2(m[1].y - m[0].y, m[1].x - m[0].x) }  // CG space is y-up
        let center = CGPoint(x: box.midX, y: H - box.midY)
        let side = max(box.width, box.height) * scale
        guard let ctx = CGContext(data: nil, width: output, height: output, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: output, height: output))
        let s = CGFloat(output) / side
        ctx.translateBy(x: CGFloat(output) / 2, y: CGFloat(output) / 2)
        ctx.scaleBy(x: s, y: s)
        ctx.rotate(by: -angle)
        ctx.translateBy(x: -center.x, y: -center.y)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

// MARK: - Vector maths

public enum Vector {
    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var d = norm
        vDSP_vsdiv(v, 1, &d, &out, 1, vDSP_Length(v.count))
        return out
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }

    public static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    public static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// C (m×n) = A (m×k, row-major) · Bᵀ where B is n×k row-major. Uses Accelerate.
    public static func similarity(_ a: [Float], rows m: Int, _ b: [Float], rows n: Int, dim k: Int) -> [Float] {
        guard m > 0, n > 0 else { return [] }
        var bt = [Float](repeating: 0, count: n * k)
        vDSP_mtrans(b, 1, &bt, 1, vDSP_Length(k), vDSP_Length(n))
        var c = [Float](repeating: 0, count: m * n)
        vDSP_mmul(a, 1, bt, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
        return c
    }
}
