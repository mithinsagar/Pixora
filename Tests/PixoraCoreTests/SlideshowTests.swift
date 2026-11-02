import XCTest
@testable import PixoraCore

final class SlideshowTests: XCTestCase {
    func photo(_ id: Int64, _ day: Double?) -> Photo {
        Photo(id: id, sourceID: 1, relPath: "DCIM/\(id).jpg", filename: "\(id).jpg", ext: "jpg", siblings: [], fileSize: 1, fingerprint: nil,
              width: 4000, height: 3000, takenAt: day.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 * 86_400) },
              camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
    }
    func face(_ person: Int64?, h: Double, certain: Bool = true) -> SlideFace {
        SlideFace(personID: person, certain: certain, rect: CGRect(x: 0.3, y: 0.2, width: h * 0.75, height: h), pixelSize: h * 3000)
    }

    func testStylesPickWhatTheySay() {
        let ana: Int64 = 1, ben: Int64 = 2
        let closeUp = SlideCandidate(photo: photo(1, 3), faces: [face(ana, h: 0.3)])
        let pair = SlideCandidate(photo: photo(2, 1), faces: [face(ana, h: 0.2), face(ben, h: 0.2)], favorite: true)
        let group = SlideCandidate(photo: photo(3, 2), faces: [face(ana, h: 0.08), face(ben, h: 0.08), face(nil, h: 0.08)])
        let blink = SlideCandidate(photo: photo(4, 0), faces: [face(ana, h: 0.25)], eyesClosed: true)
        let all = [closeUp, pair, group, blink]

        XCTAssertEqual(SlideshowPlanner.pick(.portraits, from: all, people: [ana]).map(\.id), [4, 2, 1], "close-ups, oldest first")
        XCTAssertEqual(SlideshowPlanner.pick(.portraits, from: all, people: [ana], skipEyesClosed: true).map(\.id), [2, 1])
        XCTAssertEqual(SlideshowPlanner.pick(.together, from: all, people: [ana, ben]).map(\.id), [2, 3])
        XCTAssertEqual(SlideshowPlanner.pick(.candid, from: all, people: [ana]).map(\.id), [3])
        XCTAssertEqual(SlideshowPlanner.pick(.story, from: all).map(\.id), [4, 2, 3, 1])
        XCTAssertEqual(SlideshowPlanner.pick(.favorites, from: all).map(\.id), [2])
        let window = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000 + 0.5 * 86_400), duration: 2 * 86_400)
        XCTAssertEqual(SlideshowPlanner.pick(.event, from: all, event: window).map(\.id), [2, 3])
        XCTAssertTrue(SlideshowPlanner.pick(.event, from: all).isEmpty, "no event chosen, nothing guessed")
    }

    func testEventsSplitOnGapsAndNeedEnoughDates() {
        var photos: [Photo] = []
        for i in 0..<8 { photos.append(photo(Int64(i), Double(i) * 0.2)) }         // a trip over ~1.5 days
        for i in 0..<6 { photos.append(photo(Int64(100 + i), 20 + Double(i) * 0.1)) } // a party 20 days later
        photos.append(photo(999, nil))
        let events = SlideshowPlanner.events(photos)
        XCTAssertEqual(events.map(\.count), [6, 8], "newest first")
        XCTAssertTrue(SlideshowPlanner.events(Array(photos.prefix(3))).isEmpty)
    }

    func testFavoritesTableFollowsPhotos() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-fav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LibraryStore(db: try Database(url: tmp.appendingPathComponent("lib.sqlite")))
        let src = try store.addSource(url: tmp)
        let id = try store.db.write { c in
            try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, scan_state, added_at) VALUES(?,?,?,?,?,?,1,?)", src.id, "a.jpg", "a.jpg", "jpg", 1, 0, Date())
        }
        try store.setFavorite([id], true)
        XCTAssertEqual(try store.favoriteIDs(), [id])
        try store.db.write { c in _ = try c.run("DELETE FROM photos WHERE id = ?", id) }
        XCTAssertTrue(try store.favoriteIDs().isEmpty, "a deleted (or privatised) photo leaves no favourite behind")
    }
}
