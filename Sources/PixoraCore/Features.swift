import Foundation
import CoreGraphics
import Vision
import ImageIO

// MARK: - Shot-quality enrichment

/// Measures things that make a shot weaker — closed eyes, soft focus — and groups bursts. Runs after a scan
/// on Pixora's own cached face crops and thumbnails, so it also works for photos on a card that's been ejected.
/// Nothing is ever hidden or deleted because of these signals; the UI marks and separates weaker frames.
public enum Enrichment {
    /// Eye height ÷ eye width (mean of both eyes) below this counts as "eyes may be closed".
    /// Calibrated by inspecting the lowest-ratio faces in LFW: below 0.06 is mostly closed or squeezed-shut eyes
    /// (~0.6% of faces); 0.06–0.12 is mostly squinting smiles, which are fine shots, so they are not flagged.
    public static var eyesClosedRatio = 0.06
    /// A face sharper than this fraction of the person's typical sharpness is fine; below it is "soft".
    public static var softFraction = 0.45
    /// Photos at most this far apart in time, and visually alike, form a burst.
    public static var burstGap: TimeInterval = 2.0
    public static var burstSimilarity: Float = 0.80

    public static func run(store: LibraryStore, isCancelled: () -> Bool = { false }) throws {
        try enrichFaces(store: store, isCancelled: isCancelled)
        try enrichPhotos(store: store, isCancelled: isCancelled)
        try groupBursts(store: store)
    }

    static func enrichFaces(store: LibraryStore, isCancelled: () -> Bool) throws {
        let pending = try store.db.read { try $0.query("SELECT id, thumb FROM faces WHERE enriched = 0 AND thumb IS NOT NULL") { ($0.int(0), $0.blob(1)) } }
        var batch: [(Int64, Double?, Double?)] = []
        func flush() throws {
            guard !batch.isEmpty else { return }
            try store.db.write { c in for (id, s, e) in batch { try c.run("UPDATE faces SET sharpness = ?, eye_ratio = ?, enriched = 1 WHERE id = ?", s, e, id) } }
            batch.removeAll()
        }
        for (id, data) in pending {
            if isCancelled() { break }
            autoreleasepool {
                guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    batch.append((id, nil, nil)); return
                }
                batch.append((id, sharpness(img), eyeRatio(img)))
            }
            if batch.count >= 200 { try flush() }
        }
        try flush()
    }

    static func enrichPhotos(store: LibraryStore, isCancelled: () -> Bool) throws {
        let pending = try store.db.read { try $0.query("SELECT id FROM photos WHERE enriched = 0 AND scan_state = 1") { $0.int(0) } }
        var batch: [(Int64, Data?)] = []
        func flush() throws {
            guard !batch.isEmpty else { return }
            try store.db.write { c in for (id, p) in batch { try c.run("UPDATE photos SET print = ?, enriched = 1 WHERE id = ?", p, id) } }
            batch.removeAll()
        }
        for id in pending {
            if isCancelled() { break }
            autoreleasepool {
                let url = AppPaths.thumbnail(photoID: id)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    batch.append((id, nil)); return
                }
                batch.append((id, featurePrint(img).map(Vector.data)))
            }
            if batch.count >= 200 { try flush() }
        }
        try flush()
    }

    /// Recompute bursts from scratch: same source, ≤ 2 s apart, visually alike.
    public static func groupBursts(store: LibraryStore) throws {
        let rows = try store.db.read {
            try $0.query("SELECT id, source_id, taken_at, print FROM photos WHERE scan_state = 1 AND taken_at IS NOT NULL ORDER BY source_id, taken_at, filename") {
                (id: $0.int(0), source: $0.int(1), t: $0.double(2), print: $0.blob(3).map(Vector.floats))
            }
        }
        var assignments: [(Int64, Int64)] = []
        var run: [Int64] = []
        func close() {
            if run.count >= 2 { for id in run { assignments.append((id, run[0])) } }
            run.removeAll()
        }
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let prev = rows[i - 1]
                let alike: Bool = {
                    guard let a = prev.print, let b = r.print, a.count == b.count else { return true }  // no print: trust time
                    return Vector.dot(a, b) >= burstSimilarity
                }()
                if prev.source != r.source || r.t - prev.t > burstGap || !alike { close() }
            }
            run.append(r.id)
        }
        close()
        try store.db.write { c in
            try c.run("UPDATE photos SET burst_id = NULL")
            for (id, burst) in assignments { try c.run("UPDATE photos SET burst_id = ? WHERE id = ?", burst, id) }
        }
    }

    /// Variance of the Laplacian over the centre of the face crop (higher = sharper).
    public static func sharpness(_ image: CGImage) -> Double? {
        let side = 96
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Central 60% of the crop is mostly face.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let center = image.cropping(to: CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6)) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(center, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: side * side)
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let lap = 4.0 * Double(p[i]) - Double(p[i - 1]) - Double(p[i + 1]) - Double(p[i - side]) - Double(p[i + side])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Mean eye openness (height ÷ width of the eye outline) from Vision landmarks on the face crop.
    /// nil when the eyes can't be measured (strong profile, occlusion).
    public static func eyeRatio(_ image: CGImage) -> Double? {
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        func ratio(_ r: VNFaceLandmarkRegion2D?) -> Double? {
            guard let pts = r?.pointsInImage(imageSize: size), pts.count >= 4 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let width = (xs.max()! - xs.min()!), height = (ys.max()! - ys.min()!)
            guard width > 4 else { return nil }
            return Double(height / width)
        }
        let l = ratio(lm.leftEye), r = ratio(lm.rightEye)
        switch (l, r) {
        case let (a?, b?):
            // Very different eye widths = turned head; the far eye is unreliable.
            return (a + b) / 2
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    public static func featurePrint(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let obs = request.results?.first else { return nil }
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

// MARK: - Insights: who appears with whom, and coverage

public struct TogetherEdge: Hashable, Sendable {
    public let a: Int64
    public let b: Int64
    public let photos: Int
}

public struct CoverageRow: Identifiable, Hashable, Sendable {
    public var id: Int64 { personID }
    public let personID: Int64
    public let photos: Int
    public let solo: Int
    public let uncertain: Int
    public let first: Date?
    public let last: Date?
}

extension LibraryStore {
    /// For every pair of named people: how many photos they appear in together (certain matches).
    public func togetherEdges(from: Date? = nil, to: Date? = nil) throws -> [TogetherEdge] {
        var clauses = ["a.state >= 2", "b.state >= 2", "pa.name IS NOT NULL", "pb.name IS NOT NULL"]
        var args: [Any?] = []
        if let from { clauses.append("ph.taken_at >= ?"); args.append(from) }
        if let to { clauses.append("ph.taken_at < ?"); args.append(to) }
        return try db.read {
            try $0.query("""
            SELECT a.person_id, b.person_id, COUNT(DISTINCT a.photo_id)
            FROM faces a JOIN faces b ON a.photo_id = b.photo_id AND a.person_id < b.person_id
            JOIN people pa ON pa.id = a.person_id JOIN people pb ON pb.id = b.person_id
            JOIN photos ph ON ph.id = a.photo_id
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY a.person_id, b.person_id
            """, args) { TogetherEdge(a: $0.int(0), b: $0.int(1), photos: Int($0.int(2))) }
        }
    }

    /// Photos, solo photos and uncertain faces per named person, optionally within a date range.
    public func coverage(from: Date? = nil, to: Date? = nil) throws -> [CoverageRow] {
        var dateClause = ""
        var args: [Any?] = []
        if let from { dateClause += " AND ph.taken_at >= ?"; args.append(from) }
        if let to { dateClause += " AND ph.taken_at < ?"; args.append(to) }
        return try db.read {
            try $0.query("""
            SELECT p.id,
              COUNT(DISTINCT CASE WHEN f.state >= 2 THEN f.photo_id END),
              COUNT(DISTINCT CASE WHEN f.state >= 2 AND NOT EXISTS (
                  SELECT 1 FROM faces o WHERE o.photo_id = f.photo_id AND o.id != f.id AND o.pixel_size >= 0.4 * f.pixel_size
                    AND (o.person_id IS NULL OR o.person_id != p.id)) THEN f.photo_id END),
              SUM(CASE WHEN f.state = 1 THEN 1 ELSE 0 END),
              MIN(CASE WHEN f.state >= 2 THEN ph.taken_at END), MAX(CASE WHEN f.state >= 2 THEN ph.taken_at END)
            FROM people p JOIN faces f ON f.person_id = p.id JOIN photos ph ON ph.id = f.photo_id
            WHERE p.name IS NOT NULL\(dateClause)
            GROUP BY p.id ORDER BY 2 DESC
            """, args) {
                CoverageRow(personID: $0.int(0), photos: Int($0.int(1)), solo: Int($0.int(2)), uncertain: Int($0.int(3)),
                            first: $0.optDouble(4).map(Date.init(timeIntervalSince1970:)), last: $0.optDouble(5).map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// Accept every uncertain suggestion: for one person, or for everyone Review lists (named, not private).
    public func confirmAllUncertain(personID: Int64? = nil) throws {
        try db.write { c in
            if let personID { try c.run("UPDATE faces SET state = 3 WHERE state = 1 AND person_id = ?", personID) }
            else { try c.run("UPDATE faces SET state = 3 WHERE \(LibraryStore.reviewableUncertain)") }   // only what Review shows
        }
    }

    /// Reject every uncertain suggestion for one person (remembered: never suggested again).
    public func rejectAllUncertain(personID: Int64) throws {
        let ids = try db.read { try $0.query("SELECT id FROM faces WHERE state = 1 AND person_id = ?", [personID]) { $0.int(0) } }
        try reject(faceIDs: ids)
    }

    public func setContact(personID: Int64, contactID: String?, handles: [String]) throws {
        try db.write { try $0.run("UPDATE people SET contact_id = ?, contact_handles = ? WHERE id = ?",
                                  contactID, handles.isEmpty ? nil : handles.joined(separator: "\n"), personID) }
    }

    /// Photos in one burst, in shooting order.
    public func burstPhotos(_ burstID: Int64) throws -> [Photo] {
        try db.read { try $0.query("SELECT \(Self.photoColumns) FROM photos ph WHERE ph.burst_id = ? ORDER BY ph.taken_at, ph.filename", [burstID], Self.photo) }
    }

    /// Photos on a source that are not yet in the library (for the "card inserted" prompt).
    public func newFileCount(sourceID: Int64, root: URL) -> Int {
        let existing = (try? existingPhotos(sourceID: sourceID)) ?? [:]
        return FileScanner.preview(root: root).files.filter { existing[$0.relPath] == nil }.count
    }
}

// MARK: - ⌘K command parser

/// Turns "me + asha, october, solo, best, copy to desktop" into a structured request. Deterministic and
/// local: names are matched against your named people; anything not understood is reported back, never guessed.
public struct ParsedCommand: Equatable, Sendable {
    public var people: [Int64] = []
    public var mode: MatchMode?
    public var from: Date?
    public var to: Date?
    public var bestOnly = false
    public var hideWeaker = false
    public var includeUncertain = false
    public enum Action: Equatable, Sendable { case none, export(destination: String?), share, contactSheet }
    public var action: Action = .none
    public var understood: [String] = []
    public var unknown: [String] = []
}

public enum CommandParser {
    public static func parse(_ text: String, people: [(id: Int64, name: String)], now: Date = Date(), calendar: Calendar = .current) -> ParsedCommand {
        var cmd = ParsedCommand()
        var rest = " " + text.lowercased() + " "
        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return nil }
            let groups = (0..<m.numberOfRanges).map { i -> String in
                guard let r = Range(m.range(at: i), in: rest) else { return "" }
                return String(rest[r])
            }
            rest.replaceSubrange(Range(m.range, in: rest)!, with: " ")
            return groups
        }

        // Actions
        if let g = take(#"\b(?:copy|export|save)(?:\s+(?:them|photos|all))?(?:\s+to\s+(desktop|downloads|documents|pictures))?\b"#) {
            cmd.action = .export(destination: g[1].isEmpty ? nil : g[1]); cmd.understood.append(g[1].isEmpty ? "export" : "copy to \(g[1])")
        } else if take(#"\b(?:share|airdrop|send)\b"#) != nil { cmd.action = .share; cmd.understood.append("share") }
        else if take(#"\bcontact\s*sheet|\bproofs?\b|\bpdf\b"#) != nil { cmd.action = .contactSheet; cmd.understood.append("contact sheet") }

        // Modes and flags
        if take(#"\b(?:solo|alone|only(?:\s+(?:them|him|her))?|just\s+(?:them|him|her))\b"#) != nil { cmd.mode = .only; cmd.understood.append("only them") }
        else if take(#"\b(?:any|either|or)\b"#) != nil { cmd.mode = .any; cmd.understood.append("any of them") }
        else if take(#"\b(?:together|both|all|with|and)\b"#) != nil { cmd.mode = .all; cmd.understood.append("together") }
        if take(#"\bbest\b"#) != nil { cmd.bestOnly = true; cmd.understood.append("best shots") }
        if take(#"\b(?:eyes\s+open|no\s+blinks?|sharp)\b"#) != nil { cmd.hideWeaker = true; cmd.understood.append("eyes open & sharp") }
        if take(#"\b(?:uncertain|maybe|unsure)\b"#) != nil { cmd.includeUncertain = true; cmd.understood.append("include uncertain") }

        // Dates
        let startOfToday = calendar.startOfDay(for: now)
        if take(#"\btoday\b"#) != nil { cmd.from = startOfToday; cmd.to = calendar.date(byAdding: .day, value: 1, to: startOfToday); cmd.understood.append("today") }
        else if take(#"\byesterday\b"#) != nil { cmd.from = calendar.date(byAdding: .day, value: -1, to: startOfToday); cmd.to = startOfToday; cmd.understood.append("yesterday") }
        else if let g = take(#"\blast\s+(week|month|year)\b"#) {
            let comp: Calendar.Component = g[1] == "week" ? .weekOfYear : g[1] == "month" ? .month : .year
            if let interval = calendar.dateInterval(of: comp, for: calendar.date(byAdding: comp, value: -1, to: now)!) {
                cmd.from = interval.start; cmd.to = interval.end; cmd.understood.append("last \(g[1])")
            }
        } else if let g = take(#"\bthis\s+(week|month|year)\b"#) {
            let comp: Calendar.Component = g[1] == "week" ? .weekOfYear : g[1] == "month" ? .month : .year
            if let interval = calendar.dateInterval(of: comp, for: now) { cmd.from = interval.start; cmd.to = interval.end; cmd.understood.append("this \(g[1])") }
        } else {
            let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
            let short = months.map { String($0.prefix(3)) }
            let monthPattern = (months + short).joined(separator: "|")
            if let g = take("\\b(\(monthPattern))\\b(?:\\s+(\\d{4}))?") {
                let idx = (months.firstIndex(of: g[1]) ?? short.firstIndex(of: g[1]))! + 1
                var year = Int(g[2]) ?? calendar.component(.year, from: now)
                if g[2].isEmpty, idx > calendar.component(.month, from: now) { year -= 1 }   // "october" in March = last October
                if let start = calendar.date(from: DateComponents(year: year, month: idx, day: 1)) {
                    cmd.from = start; cmd.to = calendar.date(byAdding: .month, value: 1, to: start)
                    cmd.understood.append(g[2].isEmpty ? g[1].capitalized : "\(g[1].capitalized) \(year)")
                }
            } else if let g = take(#"\b(20\d{2}|19\d{2})\b"#), let y = Int(g[1]),
                      let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) {
                cmd.from = start; cmd.to = calendar.date(byAdding: .year, value: 1, to: start); cmd.understood.append(g[1])
            }
        }

        // People: longest names first so "Ana Maria" wins over "Ana".
        for p in people.sorted(by: { $0.name.count > $1.name.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: p.name.lowercased()).replacingOccurrences(of: "_", with: "[ _]") + "\\b"
            if take(pattern) != nil { cmd.people.append(p.id); cmd.understood.append(p.name) }
        }
        // First names alone ("asha" for "Asha Rao"), if unambiguous.
        let leftoverWords = rest.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
        let filler: Set<String> = ["me", "photos", "photo", "pics", "of", "in", "the", "from", "to", "at", "on", "for", "find", "show", "where", "are", "is", "a", "an"]
        for word in leftoverWords where !filler.contains(word) {
            let candidates = people.filter { p in !cmd.people.contains(p.id) && p.name.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" }).contains { $0 == word } }
            if candidates.count == 1 { cmd.people.append(candidates[0].id); cmd.understood.append(candidates[0].name) }
            else { cmd.unknown.append(word) }
        }
        return cmd
    }
}
