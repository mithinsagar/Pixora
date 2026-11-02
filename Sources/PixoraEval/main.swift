import Foundation
import CoreGraphics
import PixoraCore
import ImageIO
import CoreText

// Accuracy harness. Point it at a folder of folders (one per person, e.g. LFW):
//   pixora-eval <dataset> [--embedder facenet|vision] [--model path.mlmodelc] [--scale 1.3] [--max-images 13233]
// It runs Pixora's real pipeline (Vision detection → alignment → embedding → Matcher) and prints
// verification, assignment and grouping numbers. Nothing here is simulated.

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--pairs", args.count >= 3 {
    // Official pair list (CPLFW-style CSV: is_same, image_a, image_b). Images that yield no face score -1,
    // so detection failures count against the pipeline instead of being skipped.
    let dir = URL(fileURLWithPath: args[1])
    let rows = try String(contentsOfFile: args[2], encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst().map { $0.split(separator: ",").map(String.init) }
    let useVision = args.contains("--detector") && option("--detector") == "vision"
    let emb: FaceEmbedder = try option("--model").map { try CoreMLFaceEmbedder(compiledModelURL: URL(fileURLWithPath: $0)) } ?? Embedders.makeDefault()
    let det: FaceDetector = useVision ? VisionFaceDetector() : Detectors.makeDefault()
    let analyzer = FaceAnalyzer(embedder: emb, detector: det)
    var cache: [String: [Float]?] = [:]
    func embedding(_ name: String) -> [Float]? {
        if let c = cache[name] { return c }
        let person = String(name.dropLast(4).split(separator: "_").dropLast().joined(separator: "_"))
        var e: [Float]?
        if let img = ImageLoader.image(at: dir.appendingPathComponent(person).appendingPathComponent(name), maxPixel: 2400),
           let faces = try? analyzer.analyze(img), let best = faces.filter({ $0.embedding != nil }).max(by: { a, b in
               Double(a.rect.width * a.rect.height) - Double(hypot(a.rect.midX - 0.5, a.rect.midY - 0.5)) < Double(b.rect.width * b.rect.height) - Double(hypot(b.rect.midX - 0.5, b.rect.midY - 0.5)) }) {
            e = best.embedding
        }
        cache[name] = e
        return e
    }
    var scored: [(same: Bool, score: Float)] = []
    var failures = 0
    for r in rows where r.count >= 6 {
        let a = embedding(r[4]), b = embedding(r[5])
        if a == nil || b == nil { failures += 1 }
        scored.append((r[3] == "1", (a != nil && b != nil) ? Vector.dot(a!, b!) : -1))
    }
    let pos = scored.filter(\.same).map(\.score), neg = scored.filter { !$0.same }.map(\.score)
    var best: (Float, Double) = (0, 0)
    for t in stride(from: Float(0.0), through: 0.9, by: 0.01) {
        let acc = Double(pos.filter { $0 >= t }.count + neg.filter { $0 < t }.count) / Double(scored.count)
        if acc > best.1 { best = (t, acc) }
    }
    let th = emb.thresholds
    func rate(_ v: [Float], _ t: Float) -> String { String(format: "%.2f%%", Double(v.filter { $0 >= t }.count) * 100 / Double(max(v.count, 1))) }
    print("detector: \(det.name)  embedder: \(emb.id)")
    print("pairs: \(scored.count) (\(pos.count) same, \(neg.count) different)  pairs with a face not found: \(failures)")
    print(String(format: "best accuracy %.2f%% at %.2f", best.1 * 100, best.0))
    print("at 'certain' \(th.certain): same-person pairs accepted \(rate(pos, th.certain)), different-person pairs wrongly accepted \(rate(neg, th.certain))")
    print("at 'suggest' \(th.suggest): same-person pairs accepted \(rate(pos, th.suggest)), different-person pairs wrongly accepted \(rate(neg, th.suggest))")
    exit(0)
}
if args.first == "--eyes", args.count >= 3 {
    // Eye-openness distribution on a labelled-free face set; writes the lowest-ratio crops into a grid image to inspect.
    let root = URL(fileURLWithPath: args[1]); let limit = Int(args.count >= 4 ? args[3] : "3000") ?? 3000
    let analyzer = FaceAnalyzer(embedder: Embedders.makeDefault(), detector: Detectors.makeDefault())
    var items: [(Double, CGImage)] = []
    let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }.prefix(limit)
    for f in files {
        guard let img = ImageLoader.image(at: f, maxPixel: 1200), let faces = try? analyzer.analyze(img) else { continue }
        for face in faces { if let d = face.thumbJPEG, let src = CGImageSourceCreateWithData(d as CFData, nil), let t = CGImageSourceCreateImageAtIndex(src, 0, nil), let r = Enrichment.eyeRatio(t) { items.append((r, t)) } }
    }
    let sorted = items.sorted { $0.0 < $1.0 }
    let v = sorted.map(\.0)
    func pct(_ p: Double) -> Double { v[min(v.count - 1, Int(Double(v.count) * p))] }
    print("faces measured: \(v.count)  p1 \(pct(0.01))  p5 \(pct(0.05))  p10 \(pct(0.10))  median \(pct(0.5))")
    for t in [0.08, 0.10, 0.12, 0.14, 0.16] { print("ratio < \(t): \(v.filter { $0 < t }.count)") }
    let n = min(48, sorted.count), cols = 8, cell = 120
    let ctx = CGContext(data: nil, width: cols * cell, height: ((n + cols - 1) / cols) * (cell + 16), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for i in 0..<n {
        let x = (i % cols) * cell, y = ctx.height - (i / cols + 1) * (cell + 16)
        ctx.draw(sorted[i].1, in: CGRect(x: x, y: y + 16, width: cell, height: cell))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(format: "%.3f", sorted[i].0), attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Menlo" as CFString, 11, nil)]))
        ctx.textPosition = CGPoint(x: x + 4, y: y + 3); CTLineDraw(line, ctx)
    }
    let rep = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(rep, ctx.makeImage()!, nil); CGImageDestinationFinalize(rep)
    exit(0)
}
if args.first == "--count", args.count >= 2 {
    // Count faces per folder with each detector (no images are saved or shown). Optional per-folder sample size.
    let root = URL(fileURLWithPath: args[1]); let perFolder = args.count >= 3 ? Int(args[2]) ?? 40 : 40
    let vision = VisionFaceDetector()
    guard let url = SCRFDDetector.locate(), let scrfd = try? SCRFDDetector(compiledModelURL: url) else { print("SCRFD missing"); exit(1) }
    let combined = Detectors.makeDefault()
    let preview = FileScanner.preview(root: root)
    print("folder                 photos  sampled   Vision@2400  SCRFD+tiles@3200  Combined@3200  (max faces in one photo: V/S/C)")
    for folder in preview.folders {
        let files = preview.files.filter { $0.folder == folder.path }
        let sample = stride(from: 0, to: files.count, by: max(1, files.count / perFolder)).map { files[$0] }.prefix(perFolder)
        var v = 0, sc = 0, c = 0, mv = 0, ms = 0, mc = 0
        for f in sample {
            let u = root.appendingPathComponent(f.relPath)
            if let small = ImageLoader.image(at: u, maxPixel: 2400) { let n = (try? vision.detect(small).count) ?? 0; v += n; mv = max(mv, n) }
            if let big = ImageLoader.image(at: u, maxPixel: 3200) {
                let b = ImageLoader.brightenedIfDark(big)
                let n1 = (try? scrfd.detect(b).count) ?? 0; sc += n1; ms = max(ms, n1)
                let n2 = (try? combined.detect(b).count) ?? 0; c += n2; mc = max(mc, n2)
            }
        }
        print(String(format: "%-22@ %6d %8d %13d %17d %14d   (%d/%d/%d)", folder.path as NSString, files.count, sample.count, v, sc, c, mv, ms, mc))
    }
    exit(0)
}
if args.first == "--dump", args.count >= 3 {
    // Debug: save the aligned crops for the faces in one image, and print the raw detections.
    let det = Detectors.makeDefault()
    let emb = Embedders.makeDefault()
    let img = ImageLoader.image(at: URL(fileURLWithPath: args[1]), maxPixel: 3200)!
    let analyzer = FaceAnalyzer(embedder: emb, detector: det)
    for (i, raw) in try det.detect(img).enumerated() {
        print("face \(i): box \(raw.box) score \(raw.score) landmarks \(raw.landmarks ?? [])")
        if let c = analyzer.alignedCrop(raw, in: img), let d = ImageLoader.jpegData(c, quality: 0.9) {
            try d.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("crop\(i).jpg"))
        }
    }
    exit(0)
}
if args.first == "--e2e", args.count >= 3 {
    try await runE2E(card: URL(fileURLWithPath: args[1]), manifestURL: URL(fileURLWithPath: args[2]))
    exit(0)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let datasetPath = args.first, !datasetPath.hasPrefix("--") else {
    print("usage: pixora-eval <dataset-dir> [--embedder facenet|vision] [--model FaceNet512.mlmodelc] [--scale 1.3] [--max-images N]")
    exit(2)
}
let dataset = URL(fileURLWithPath: datasetPath)
let maxImages = Int(option("--max-images") ?? "") ?? Int.max

let baseEmbedder: FaceEmbedder
if option("--embedder") == "vision" {
    baseEmbedder = VisionFeaturePrintEmbedder()
} else if let m = option("--model") {
    baseEmbedder = try CoreMLFaceEmbedder(compiledModelURL: URL(fileURLWithPath: m))
} else if let url = CoreMLFaceEmbedder.locateModel() {
    baseEmbedder = try CoreMLFaceEmbedder(compiledModelURL: url)
} else {
    print("No Core ML face model found; pass --model or --embedder vision"); exit(1)
}

/// Lets us try a different crop scale or thresholds without touching the model.
final class ScaledEmbedder: FaceEmbedder {
    let base: FaceEmbedder; let alignment: Alignment
    init(_ b: FaceEmbedder, scale: CGFloat?) {
        base = b
        if let scale, case .eyeLevel = b.alignment { alignment = .eyeLevel(scale: scale) } else { alignment = b.alignment }
    }
    var id: String { base.id }; var displayName: String { base.displayName }; var detail: String { base.detail }
    var inputSide: Int { base.inputSide }
    var thresholds: MatchThresholds {
        var t = base.thresholds
        if let v = option("--certain").flatMap(Float.init) { t.certain = v }
        if let v = option("--suggest").flatMap(Float.init) { t.suggest = v }
        if let v = option("--group").flatMap(Float.init) { t.group = v }
        return t
    }
    func embed(_ crop: CGImage) throws -> [Float] { try base.embed(crop) }
}
let embedder: FaceEmbedder = ScaledEmbedder(baseEmbedder, scale: option("--scale").flatMap(Double.init).map { CGFloat($0) })
let detector: FaceDetector = option("--detector") == "vision" ? VisionFaceDetector() : Detectors.makeDefault()
let t = embedder.thresholds
print("detector: \(detector.name)  embedder: \(embedder.id)  alignment: \(embedder.alignment)  thresholds: certain \(t.certain) suggest \(t.suggest) group \(t.group)")

// 1. Embed one face per image (the largest face nearest the centre). Cached per dataset/model/scale for sweeps.
let fm = FileManager.default
let people = try fm.contentsOfDirectory(at: dataset, includingPropertiesForKeys: [.isDirectoryKey]).map { $0.resolvingSymlinksInPath() }
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.path < $1.path }
var samples: [(person: Int, embedding: [Float])] = []
var images = 0, noFace = 0, tooSmall = 0
let analyzer = FaceAnalyzer(embedder: embedder, detector: detector)
let start = Date()
struct CachedSample: Codable { let p: Int; let e: [Float] }
let cacheURL = option("--cache").map { URL(fileURLWithPath: $0) }
if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([CachedSample].self, from: data) {
    samples = cached.map { ($0.p, $0.e) }
    images = samples.count
    print("loaded \(samples.count) cached embeddings from \(cacheURL.lastPathComponent)")
} else {
outer: for (pi, dir) in people.enumerated() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { ImageLoader.isImageFile(ext: $0.pathExtension) }.sorted { $0.path < $1.path } ?? []
        for f in files {
            if images >= maxImages { break outer }
            images += 1
            guard let img = ImageLoader.image(at: f, maxPixel: 2400), let faces = try? analyzer.analyze(img), !faces.isEmpty else { noFace += 1; continue }
            let best = faces.max { a, b in
                func score(_ x: DetectedFace) -> Double { Double(x.rect.width * x.rect.height) - Double(hypot(x.rect.midX - 0.5, x.rect.midY - 0.5)) }
                return score(a) < score(b)
            }!
            guard let e = best.embedding else { tooSmall += 1; continue }
            samples.append((pi, e))
        }
    }
    
    if let cacheURL, !samples.isEmpty { try? JSONEncoder().encode(samples.map { CachedSample(p: $0.person, e: $0.embedding) }).write(to: cacheURL) }
}
let elapsed = Date().timeIntervalSince(start)
print(String(format: "images: %d  embedded: %d  no face found: %d  too small: %d  (%.1f ms/image)", images, samples.count, noFace, tooSmall, elapsed * 1000 / Double(max(images, 1))))

let byPerson = Dictionary(grouping: samples.indices, by: { samples[$0].person })

// 2. Verification: all genuine pairs (≤10 images/person) vs. the same number of random impostor pairs.
var rng = SystemRandomNumberGenerator()
var genuine: [Float] = [], impostor: [Float] = []
for (_, idx) in byPerson where idx.count > 1 {
    let s = Array(idx.prefix(10))
    for i in 0..<s.count { for j in (i + 1)..<s.count { genuine.append(Vector.dot(samples[s[i]].embedding, samples[s[j]].embedding)) } }
}
while impostor.count < genuine.count && samples.count > 1 {
    let a = Int.random(in: 0..<samples.count, using: &rng), b = Int.random(in: 0..<samples.count, using: &rng)
    if samples[a].person != samples[b].person { impostor.append(Vector.dot(samples[a].embedding, samples[b].embedding)) }
}
print("\nVERIFICATION  genuine pairs: \(genuine.count)  impostor pairs: \(impostor.count)")
print(" thresh   TPR(same≥t)  FPR(diff≥t)  accuracy")
var bestAcc: (Float, Double) = (0, 0)
for k in stride(from: Float(0.30), through: 0.95, by: 0.025) {
    let tpr = Double(genuine.filter { $0 >= k }.count) / Double(max(genuine.count, 1))
    let fpr = Double(impostor.filter { $0 >= k }.count) / Double(max(impostor.count, 1))
    let acc = (tpr + (1 - fpr)) / 2
    if acc > bestAcc.1 { bestAcc = (k, acc) }
    print(String(format: "  %.3f    %6.2f%%      %6.3f%%     %6.2f%%", k, tpr * 100, fpr * 100, acc * 100))
}
print(String(format: " best balanced accuracy %.2f%% at %.3f", bestAcc.1 * 100, bestAcc.0))

// 3. Assignment: people with ≥6 images; 3 references each. Remaining images are genuine queries;
//    images of people with a single image are strangers who should NOT be matched.
var refs: [Matcher.Reference] = [], queries: [(Int64, Matcher.Candidate)] = []
var nextID: Int64 = 1
for (p, idx) in byPerson where idx.count >= 6 {
    for i in idx.prefix(3) { refs.append(.init(personID: Int64(p), embedding: samples[i].embedding)) }
    for i in idx.dropFirst(3).prefix(10) { queries.append((Int64(p), .init(id: nextID, photoID: nextID, embedding: samples[i].embedding))); nextID += 1 }
}
var strangers: [Matcher.Candidate] = []
for (_, idx) in byPerson where idx.count == 1 { strangers.append(.init(id: nextID, photoID: nextID, embedding: samples[idx[0]].embedding)); nextID += 1 }
let matcher = Matcher(thresholds: embedder.thresholds)
let qa = matcher.assign(queries.map(\.1), references: refs)
let truth = Dictionary(uniqueKeysWithValues: queries.map { ($0.1.id, $0.0) })
let autoRight = qa.filter { $0.state == .auto && $0.personID == truth[$0.faceID] }.count
let autoWrong = qa.filter { $0.state == .auto && $0.personID != truth[$0.faceID] }.count
let sugRight = qa.filter { $0.state == .suggested && $0.personID == truth[$0.faceID] }.count
let sugWrong = qa.filter { $0.state == .suggested && $0.personID != truth[$0.faceID] }.count
let unassigned = qa.filter { $0.state == .unassigned }.count
let sa = matcher.assign(strangers, references: refs)
func pct(_ a: Int, _ b: Int) -> String { String(format: "%5.1f%%", Double(a) * 100 / Double(max(b, 1))) }
print("\nASSIGNMENT  known people: \(Set(refs.map(\.personID)).count) (3 reference faces each)  queries: \(qa.count)  strangers: \(sa.count)")
print("  known person, certain & correct:   \(pct(autoRight, qa.count))")
print("  known person, certain but WRONG:   \(pct(autoWrong, qa.count))")
print("  known person, sent to review (right person suggested): \(pct(sugRight, qa.count))  (wrong person suggested): \(pct(sugWrong, qa.count))")
print("  known person, not matched:         \(pct(unassigned, qa.count))")
print("  stranger wrongly matched (certain): \(pct(sa.filter { $0.state == .auto }.count, sa.count))   suggested for review: \(pct(sa.filter { $0.state == .suggested }.count, sa.count))")

// 4. Grouping: people with ≥4 images (≤15 each), everything unassigned, as on a first import.
var pool: [Matcher.Candidate] = []
var poolTruth: [Int64: Int] = [:]
for (p, idx) in byPerson where idx.count >= 4 {
    for i in idx.prefix(15) { pool.append(.init(id: nextID, photoID: nextID, embedding: samples[i].embedding)); poolTruth[nextID] = p; nextID += 1 }
}
let groups = matcher.cluster(pool)
var samePairsTotal = 0, samePairsTogether = 0, groupedPairs = 0, groupedPairsCorrect = 0
let perPerson = Dictionary(grouping: pool.map(\.id), by: { poolTruth[$0]! })
for (_, ids) in perPerson { samePairsTotal += ids.count * (ids.count - 1) / 2 }
var pureGroups = 0
for g in groups {
    let labels = g.map { poolTruth[$0]! }
    for i in 0..<labels.count { for j in (i + 1)..<labels.count { groupedPairs += 1; if labels[i] == labels[j] { groupedPairsCorrect += 1; samePairsTogether += 1 } } }
    if Set(labels).count == 1 { pureGroups += 1 }
}
let inGroups = groups.reduce(0) { $0 + $1.count }
print("\nGROUPING  faces: \(pool.count) of \(perPerson.count) people  →  groups: \(groups.count)  faces left unsorted: \(pool.count - inGroups)")
print("  pair precision (grouped pairs that are the same person): \(pct(groupedPairsCorrect, groupedPairs))")
print("  pair recall    (same-person pairs that ended up together): \(pct(samePairsTogether, samePairsTotal))")
print("  groups containing only one person: \(pct(pureGroups, groups.count))")
