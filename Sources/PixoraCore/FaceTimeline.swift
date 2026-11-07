import Foundation
import CoreGraphics
import ImageIO
import Vision

/// One photo in a person's Through Time reel.
public struct FaceMoment: Identifiable, Hashable, Sendable {
    public var id: Int64 { faceID }
    public let faceID: Int64
    public let photo: Photo
    public let date: Date
    /// Where the face is in the photo: normalised, origin top-left.
    public let rect: CGRect
    public let score: Double
    public let burstID: Int64?
    public init(faceID: Int64, photo: Photo, date: Date, rect: CGRect, score: Double, burstID: Int64? = nil) {
        self.faceID = faceID; self.photo = photo; self.date = date; self.rect = rect; self.score = score; self.burstID = burstID
    }
}

public enum FaceTimeline {
    public static let minimumFrames = 6
    public static let maximumFrames = 90
    /// Face quality falls fast as a head turns; below this the eyes can't be lined up well enough to look right.
    static let minimumQuality = 0.55
    static let minimumPixels = 70.0

    /// A person's dated photos that make a good frame: eyes open, in focus, facing the camera, big enough.
    public static func moments(personID: Int64, store: LibraryStore) throws -> [FaceMoment] {
        let results = try store.search(people: [personID], mode: .all, includeUncertain: false).filter { $0.photo.takenAt != nil }
        let faces = try store.faceGeometry(ids: results.compactMap { $0.matches.first?.faceID })
        func moments(strict: Bool) -> [FaceMoment] {
            results.compactMap { r in
                guard let date = r.photo.takenAt, let m = r.matches.first, let f = faces[m.faceID] else { return nil }
                if strict, r.eyesClosed || r.soft || f.quality < minimumQuality || f.pixelSize < minimumPixels { return nil }
                return FaceMoment(faceID: m.faceID, photo: r.photo, date: date, rect: f.rect, score: r.score, burstID: r.burstID)
            }
        }
        let good = moments(strict: true)
        return good.count >= minimumFrames ? good : moments(strict: false)
    }

    /// Chooses the frames, oldest first. Half the reel is spread evenly over the calendar so quiet years still show;
    /// the rest follows the photos, so a person with two busy weekends doesn't end up with only two frames.
    public static func plan(_ all: [FaceMoment], maximum: Int = maximumFrames) -> [FaceMoment] {
        var bestOfBurst: [Int64: FaceMoment] = [:]
        var pool: [FaceMoment] = []
        for m in all {
            guard let b = m.burstID else { pool.append(m); continue }
            if let cur = bestOfBurst[b], cur.score >= m.score { continue }
            bestOfBurst[b] = m
        }
        pool += bestOfBurst.values
        pool.sort { ($0.date, $0.faceID) < ($1.date, $1.faceID) }
        guard pool.count > maximum, let first = pool.first?.date, let last = pool.last?.date else { return pool }

        var chosen = Set<Int64>()
        let span = last.timeIntervalSince(first), slots = max(1, maximum / 2)
        if span > 0 {
            var buckets: [Int: FaceMoment] = [:]
            for m in pool {
                let b = min(slots - 1, Int(m.date.timeIntervalSince(first) / span * Double(slots)))
                if let cur = buckets[b], cur.score >= m.score { continue }
                buckets[b] = m
            }
            chosen.formUnion(buckets.values.map(\.faceID))
        }
        let remaining = pool.filter { !chosen.contains($0.faceID) }
        let wanted = maximum - chosen.count
        if wanted > 0, !remaining.isEmpty {
            let size = Double(remaining.count) / Double(wanted)
            for i in 0..<wanted {
                let lo = Int(Double(i) * size), hi = min(remaining.count, max(lo + 1, Int(Double(i + 1) * size)))
                guard lo < hi, let best = remaining[lo..<hi].max(by: { $0.score < $1.score }) else { continue }
                chosen.insert(best.faceID)
            }
        }
        return pool.filter { chosen.contains($0.faceID) }
    }

    /// "2019 to 2026", "March to October 2026", "8 October 2026".
    public static func spanLabel(_ moments: [FaceMoment], calendar: Calendar = .current) -> String {
        guard let a = moments.first?.date, let b = moments.last?.date else { return "" }
        let year = { calendar.component(.year, from: $0) }
        if year(a) != year(b) { return "\(year(a)) to \(year(b))" }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        if calendar.isDate(a, inSameDayAs: b) { f.dateFormat = "d MMMM yyyy"; return f.string(from: a) }
        if calendar.component(.month, from: a) == calendar.component(.month, from: b) { f.dateFormat = "MMMM yyyy"; return f.string(from: a) }
        f.dateFormat = "MMMM"
        let start = f.string(from: a)
        f.dateFormat = "MMMM yyyy"
        return "\(start) to \(f.string(from: b))"
    }
}

extension LibraryStore {
    public struct FaceGeometry: Sendable {
        public let rect: CGRect
        public let quality: Double
        public let pixelSize: Double
    }

    public func faceGeometry(ids: [Int64]) throws -> [Int64: FaceGeometry] {
        var out: [Int64: FaceGeometry] = [:]
        try db.read { c in
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let q = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try c.query("SELECT id, x, y, w, h, quality, pixel_size FROM faces WHERE id IN (\(q))", chunk) {
                    ($0.int(0), FaceGeometry(rect: CGRect(x: $0.double(1), y: $0.double(2), width: $0.double(3), height: $0.double(4)),
                                             quality: $0.optDouble(5) ?? 0.7, pixelSize: $0.double(6)))
                }
                for (id, g) in rows { out[id] = g }
            }
        }
        return out
    }
}

/// Square frames with the eyes in exactly the same place, which is what makes a reel of faces read as one person
/// changing. They use the same layout as the face thumbnails kept in the library, so the two can sit side by side.
public enum FaceFrames {
    /// Eye positions as a fraction of the frame, from the thumbnail template.
    static var leftEye: CGPoint { template(FaceAnalyzer.arcTemplate[0]) }
    static var rightEye: CGPoint { template(FaceAnalyzer.arcTemplate[1]) }
    private static func template(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - 56) / 112 / 1.8 + 0.5, y: (p.y - 56) / 112 / 1.8 + 0.5) }

    /// A sharp frame from the photo itself. `nil` when no eyes can be found near `rect`: the stored thumbnail is
    /// already aligned and is the better choice then.
    public static func frame(from image: CGImage, face rect: CGRect, side: Int) -> CGImage? {
        guard let eyes = eyes(in: image, near: rect) else { return nil }
        let s = CGFloat(side)
        let target = [CGPoint(x: leftEye.x * s, y: leftEye.y * s), CGPoint(x: rightEye.x * s, y: rightEye.y * s)]
        return warp(image, from: [eyes.left, eyes.right], to: target, side: side)
    }

    /// Eye centres in top-left pixel coordinates: image-left first.
    static func eyes(in image: CGImage, near rect: CGRect) -> (left: CGPoint, right: CGPoint)? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let box = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H)
        let margin = max(box.width, box.height) * 0.7
        let region = box.insetBy(dx: -margin, dy: -margin).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard !region.isNull, region.width > 8, region.height > 8, let crop = image.cropping(to: region) else { return nil }

        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return nil }
        // The crop can hold a neighbour's face too: take the one closest to the middle.
        let centre = CGPoint(x: 0.5, y: 0.5)
        let nearest = (request.results ?? []).min {
            hypot($0.boundingBox.midX - centre.x, $0.boundingBox.midY - centre.y) < hypot($1.boundingBox.midX - centre.x, $1.boundingBox.midY - centre.y)
        }
        guard let marks = nearest?.landmarks else { return nil }
        let size = CGSize(width: crop.width, height: crop.height)
        func centreOf(_ pupil: VNFaceLandmarkRegion2D?, _ eye: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let pts = (pupil?.pointCount ?? 0 > 0 ? pupil : eye)?.pointsInImage(imageSize: size) ?? []
            guard !pts.isEmpty else { return nil }
            let n = CGFloat(pts.count)
            let mid = CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
            return CGPoint(x: mid.x + region.minX, y: size.height - mid.y + region.minY)   // Vision's origin is bottom-left
        }
        guard let a = centreOf(marks.leftPupil, marks.leftEye), let b = centreOf(marks.rightPupil, marks.rightEye) else { return nil }
        return a.x <= b.x ? (a, b) : (b, a)
    }

    /// Like the thumbnail warp, but anything outside the photo takes its average colour instead of black.
    static func warp(_ image: CGImage, from marks: [CGPoint], to target: [CGPoint], side: Int) -> CGImage? {
        let m = FaceAnalyzer.similarity(from: marks, to: target)
        let H = CGFloat(image.height), S = CGFloat(side)
        let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H).concatenating(m)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(AmbientBackdrop.averageColor(of: image))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
