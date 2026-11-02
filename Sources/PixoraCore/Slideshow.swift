import Foundation
import CoreGraphics

// MARK: - Favorites

extension LibraryStore {
    /// Photos the user marked with ♥. Stored in their own table, so a photo made private loses the mark with
    /// its library row and nothing about it is left behind.
    public func favoriteIDs() throws -> Set<Int64> {
        Set(try db.read { try $0.query("SELECT photo_id FROM favorites") { $0.int(0) } })
    }

    public func setFavorite(_ photoIDs: [Int64], _ on: Bool) throws {
        try db.write { c in
            for id in photoIDs where id > 0 {
                if on { try c.run("INSERT OR IGNORE INTO favorites(photo_id, added_at) VALUES(?, ?)", id, Date()) }
                else { try c.run("DELETE FROM favorites WHERE photo_id = ?", id) }
            }
        }
    }

    /// Every detected face in the given photos (position and size only), for slideshow suggestions.
    public func slideFaces(photoIDs: [Int64]) throws -> [Int64: [SlideFace]] {
        var out: [Int64: [SlideFace]] = [:]
        try db.read { c in
            for chunk in stride(from: 0, to: photoIDs.count, by: 500).map({ Array(photoIDs[$0..<min($0 + 500, photoIDs.count)]) }) {
                let q = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try c.query("SELECT photo_id, person_id, state, x, y, w, h, pixel_size FROM faces WHERE photo_id IN (\(q))", chunk) {
                    ($0.int(0), SlideFace(personID: $0.optInt(1), certain: $0.int(2) >= 2,
                                          rect: CGRect(x: $0.double(3), y: $0.double(4), width: $0.double(5), height: $0.double(6)),
                                          pixelSize: $0.double(7)))
                }
                for (pid, f) in rows { out[pid, default: []].append(f) }
            }
        }
        return out
    }
}

// MARK: - Slideshow suggestions

public struct SlideFace: Hashable, Sendable {
    public var personID: Int64?
    public var certain: Bool
    public var rect: CGRect        // normalised, origin top-left
    public var pixelSize: Double
    public init(personID: Int64?, certain: Bool, rect: CGRect, pixelSize: Double) {
        self.personID = personID; self.certain = certain; self.rect = rect; self.pixelSize = pixelSize
    }
}

public struct SlideCandidate: Identifiable, Hashable, Sendable {
    public var id: Int64 { photo.id }
    public let photo: Photo
    public var faces: [SlideFace]
    public var eyesClosed: Bool
    public var soft: Bool
    public var favorite: Bool
    public init(photo: Photo, faces: [SlideFace], eyesClosed: Bool = false, soft: Bool = false, favorite: Bool = false) {
        self.photo = photo; self.faces = faces; self.eyesClosed = eyesClosed; self.soft = soft; self.favorite = favorite
    }

    /// Faces big enough to count as someone being in the picture (not a stranger far in the background).
    var visibleFaces: [SlideFace] { faces.filter { $0.pixelSize >= 40 && $0.rect.height >= 0.04 } }
}

public enum SlideStyle: String, CaseIterable, Identifiable, Sendable {
    case portraits, together, candid, story, favorites, event
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .portraits: "Portraits"
        case .together: "Together"
        case .candid: "Candid"
        case .story: "Story"
        case .favorites: "Favorites"
        case .event: "Event or Trip"
        }
    }
    /// What the suggestion actually does — shown in the studio, so it never promises more than a heuristic.
    public var rule: String {
        switch self {
        case .portraits: "Close-ups: the person’s face fills a good part of the frame and at most one other person is in it."
        case .together: "Photos where everyone you picked appears."
        case .candid: "Wider shots and group moments — photos that aren’t close-up portraits."
        case .story: "Everything, in the order it was taken."
        case .favorites: "Photos you marked with ♥."
        case .event: "Photos from one stretch of days — suggested from gaps in the dates, or dates you choose."
        }
    }
    public var symbol: String {
        switch self {
        case .portraits: "person.crop.square"
        case .together: "person.2.fill"
        case .candid: "camera.on.rectangle"
        case .story: "book.pages"
        case .favorites: "heart.fill"
        case .event: "calendar"
        }
    }
}

public struct SlideEvent: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let count: Int
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

public enum SlideshowPlanner {
    public static let portraitFaceHeight = 0.16

    static func isPortrait(_ c: SlideCandidate, people: Set<Int64>) -> Bool {
        let visible = c.visibleFaces
        guard visible.count <= 2 else { return false }
        return visible.contains { f in
            f.rect.height >= portraitFaceHeight && (people.isEmpty || f.personID.map(people.contains) == true)
        }
    }

    /// Candidates that fit a style, oldest first. Quality flags are guesses, so leaving those photos out is a
    /// choice the caller passes in (and the user can undo).
    public static func pick(_ style: SlideStyle, from candidates: [SlideCandidate], people: [Int64] = [],
                            event: DateInterval? = nil, skipEyesClosed: Bool = false, skipSoft: Bool = false) -> [SlideCandidate] {
        let set = Set(people)
        var out: [SlideCandidate]
        switch style {
        case .portraits: out = candidates.filter { isPortrait($0, people: set) }
        case .together:
            out = set.count < 2 ? candidates : candidates.filter { c in
                let here = Set(c.faces.filter(\.certain).compactMap(\.personID))
                return set.isSubset(of: here)
            }
        case .candid: out = candidates.filter { !isPortrait($0, people: set) && !$0.visibleFaces.isEmpty }
        case .story: out = candidates
        case .favorites: out = candidates.filter(\.favorite)
        case .event:
            guard let event else { return [] }
            out = candidates.filter { $0.photo.takenAt.map(event.contains) == true }
        }
        if skipEyesClosed { out.removeAll(where: \.eyesClosed) }
        if skipSoft { out.removeAll(where: \.soft) }
        return sortedByDate(out)
    }

    public static func sortedByDate(_ c: [SlideCandidate]) -> [SlideCandidate] {
        c.sorted { ($0.photo.takenAt ?? .distantFuture, $0.photo.filename) < ($1.photo.takenAt ?? .distantFuture, $1.photo.filename) }
    }

    /// Stretches of photos with no gap longer than `gap`, with at least `minCount` photos. Newest first.
    /// Empty when too few photos have dates to say anything.
    public static func events(_ photos: [Photo], gap: TimeInterval = 36 * 3600, minCount: Int = 6) -> [SlideEvent] {
        let dates = photos.compactMap(\.takenAt).sorted()
        guard dates.count >= minCount else { return [] }
        var out: [SlideEvent] = []
        var start = dates[0], last = dates[0], n = 1
        for d in dates.dropFirst() {
            if d.timeIntervalSince(last) > gap {
                if n >= minCount { out.append(SlideEvent(start: start, end: last, count: n)) }
                start = d; n = 0
            }
            last = d; n += 1
        }
        if n >= minCount { out.append(SlideEvent(start: start, end: last, count: n)) }
        return out.reversed()
    }
}
