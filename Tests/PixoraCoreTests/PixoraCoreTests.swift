import XCTest
import CoreGraphics
@testable import PixoraCore

final class PixoraCoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("PIXORA_HOME", tmp.appendingPathComponent("home").path, 1)   // never touch the real library
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // A unit vector pointing mostly along axis `axis`, with a little noise.
    func vec(_ axis: Int, noise: Float = 0.05, seed: Int, dim: Int = 64) -> [Float] {
        var g = SeededRNG(seed: UInt64(seed * 7919 + axis))
        var v = (0..<dim).map { _ in Float.random(in: -noise...noise, using: &g) }
        v[axis] += 1
        return Vector.normalized(v)
    }

    // MARK: Matcher

    func testAssignCertainSuggestedAndUnassigned() {
        let m = Matcher(thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        let refs = (0..<3).map { Matcher.Reference(personID: 1, embedding: vec(0, seed: $0)) }
            + (0..<3).map { Matcher.Reference(personID: 2, embedding: vec(1, seed: $0)) }
        var halfway = vec(0, noise: 0, seed: 9); halfway[2] = 1.1; halfway = Vector.normalized(halfway) // ~0.67 to person 1
        let cands = [
            Matcher.Candidate(id: 10, photoID: 100, embedding: vec(0, seed: 50)),
            Matcher.Candidate(id: 11, photoID: 101, embedding: halfway),
            Matcher.Candidate(id: 12, photoID: 102, embedding: vec(5, seed: 51)),
        ]
        let a = Dictionary(uniqueKeysWithValues: m.assign(cands, references: refs).map { ($0.faceID, $0) })
        XCTAssertEqual(a[10]?.state, .auto); XCTAssertEqual(a[10]?.personID, 1)
        XCTAssertEqual(a[11]?.state, .suggested); XCTAssertEqual(a[11]?.personID, 1)
        XCTAssertEqual(a[12]?.state, .unassigned); XCTAssertNil(a[12]?.personID)
    }

    func testLowQualityFaceIsNeverCertainOrGrouped() {
        let m = Matcher(thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        let refs = [Matcher.Reference(personID: 1, embedding: vec(0, seed: 1))]
        let blurry = Matcher.Candidate(id: 1, photoID: 1, embedding: vec(0, seed: 2), quality: 0.1)
        XCTAssertEqual(m.assign([blurry], references: refs).first?.state, .suggested, "a side-on/blurry face goes to review")
        let faces = (0..<3).map { Matcher.Candidate(id: Int64($0), photoID: Int64($0), embedding: vec(0, seed: $0), quality: 0.1) }
        XCTAssertTrue(m.cluster(faces).isEmpty, "low-quality faces don't seed groups")
    }

    func testRejectedPersonIsNeverSuggestedAgain() {
        let m = Matcher(thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        let refs = [Matcher.Reference(personID: 1, embedding: vec(0, seed: 1))]
        let c = Matcher.Candidate(id: 1, photoID: 1, embedding: vec(0, seed: 2), rejected: [1])
        XCTAssertEqual(m.assign([c], references: refs).first?.state, .unassigned)
    }

    func testSamePersonAtMostOncePerPhoto() {
        let m = Matcher(thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        let refs = [Matcher.Reference(personID: 1, embedding: vec(0, seed: 1))]
        let cands = [Matcher.Candidate(id: 1, photoID: 7, embedding: vec(0, noise: 0.02, seed: 2)),
                     Matcher.Candidate(id: 2, photoID: 7, embedding: vec(0, noise: 0.06, seed: 3))]
        let a = m.assign(cands, references: refs)
        XCTAssertEqual(a.filter { $0.state == .auto }.count, 1, "two faces in one photo can't both be certain matches for one person")
        XCTAssertEqual(a.filter { $0.state == .suggested }.count, 1)
    }

    func testClusterSeparatesPeopleAndKeepsOneFacePerPhoto() {
        let m = Matcher(thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        var faces: [Matcher.Candidate] = []
        var id: Int64 = 0
        for axis in [0, 1, 2] { for s in 0..<4 { id += 1; faces.append(.init(id: id, photoID: id, embedding: vec(axis, seed: s))) } }
        id += 1; faces.append(.init(id: id, photoID: 1, embedding: vec(0, seed: 99)))   // same photo as face 1
        id += 1; faces.append(.init(id: id, photoID: id, embedding: vec(9, seed: 0)))  // a stranger
        let groups = m.cluster(faces)
        XCTAssertEqual(groups.count, 3)
        for g in groups { XCTAssertEqual(g.count, 4) }
        XCTAssertFalse(groups.flatMap { $0 }.contains(id), "a singleton stranger stays unsorted")
    }

    // MARK: Store: search semantics

    func makeStore() throws -> LibraryStore { LibraryStore(db: try Database(url: tmp.appendingPathComponent("lib.sqlite"))) }

    func insertPhoto(_ store: LibraryStore, source: Int64, name: String, faces: [(Int64?, FaceState)], fingerprint: String? = nil) throws -> Int64 {
        try store.db.write { c in
            let pid = try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, fingerprint, scan_state, added_at) VALUES(?,?,?,?,?,?,?,1,?)",
                                source, name, name, "jpg", 100, 0, fingerprint ?? name, Date())
            for (person, state) in faces {
                try c.run("INSERT INTO faces(photo_id, x, y, w, h, person_id, state, created_at) VALUES(?,0,0,0.1,0.1,?,?,?)", pid, person, state.rawValue, Date())
            }
            return pid
        }
    }

    func testAllVersusAnySelectedPeople() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let me = try store.createPerson(name: "Me"), friend = try store.createPerson(name: "Friend")
        let both = try insertPhoto(store, source: src.id, name: "both.jpg", faces: [(me, .confirmed), (friend, .auto)])
        let onlyMe = try insertPhoto(store, source: src.id, name: "me.jpg", faces: [(me, .confirmed)])
        let onlyFriend = try insertPhoto(store, source: src.id, name: "friend.jpg", faces: [(friend, .confirmed), (nil, .unassigned)])
        let maybeBoth = try insertPhoto(store, source: src.id, name: "maybe.jpg", faces: [(me, .confirmed), (friend, .suggested)])
        _ = try insertPhoto(store, source: src.id, name: "nobody.jpg", faces: [(nil, .unassigned)])

        let all = try store.search(people: [me, friend], mode: .all, includeUncertain: false).map(\.photo.id)
        XCTAssertEqual(Set(all), [both])

        let allWithUncertain = try store.search(people: [me, friend], mode: .all, includeUncertain: true)
        XCTAssertEqual(Set(allWithUncertain.map(\.photo.id)), [both, maybeBoth])
        let maybe = allWithUncertain.first { $0.photo.id == maybeBoth }!
        XCTAssertEqual(maybe.matches.first { $0.personID == friend }?.state, .suggested, "uncertain matches stay marked as uncertain")

        let any = try store.search(people: [me, friend], mode: .any, includeUncertain: false).map(\.photo.id)
        XCTAssertEqual(Set(any), [both, onlyMe, onlyFriend, maybeBoth])
    }

    func testSamePhotoFromTwoSourcesAppearsOnce() throws {
        let store = try makeStore()
        let a = try store.addSource(url: tmp)
        let otherDir = tmp.appendingPathComponent("copy"); try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let b = try store.addSource(url: otherDir)
        let me = try store.createPerson(name: "Me")
        _ = try insertPhoto(store, source: a.id, name: "x.jpg", faces: [(me, .confirmed)], fingerprint: "same")
        _ = try insertPhoto(store, source: b.id, name: "x.jpg", faces: [(me, .confirmed)], fingerprint: "same")
        XCTAssertEqual(try store.search(people: [me], mode: .any, includeUncertain: false).count, 1)
    }

    func testRejectRemembersAndNamingConfirms() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let group = try store.createPerson(name: nil)
        let p = try insertPhoto(store, source: src.id, name: "a.jpg", faces: [(group, .auto), (group, .auto)])
        let faces = try store.faces(photoID: p)
        try store.reject(faceIDs: [faces[1].id])
        try store.name(personID: group, as: "Ana")
        let after = try store.faces(photoID: p)
        XCTAssertEqual(after.first { $0.id == faces[0].id }?.state, .confirmed)
        XCTAssertNil(after.first { $0.id == faces[1].id }?.personID)
        let rejections = try store.db.read { try $0.scalar("SELECT COUNT(*) FROM rejections WHERE person_id = ?", [group]) }
        XCTAssertEqual(rejections, 1)
    }

    func testNamingWithExistingNameMergesAndForgetDeletesTemplates() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let ana = try store.createPerson(name: "Ana")
        let group = try store.createPerson(name: nil)
        _ = try insertPhoto(store, source: src.id, name: "a.jpg", faces: [(ana, .confirmed)])
        _ = try insertPhoto(store, source: src.id, name: "b.jpg", faces: [(group, .auto)])
        XCTAssertEqual(try store.name(personID: group, as: "ana"), ana)
        XCTAssertEqual(try store.people().count, 1)
        try store.forget(personID: ana)
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM faces") }, 0)
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM photos") }, 2, "photos stay indexed")
    }

    // MARK: Export

    func testExportNeverOverwritesAndSkipsIdenticalDuplicates() throws {
        let src = tmp.appendingPathComponent("card"); let dest = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("photo-A".utf8).write(to: src.appendingPathComponent("IMG_1.jpg"))
        try Data("photo-B".utf8).write(to: src.appendingPathComponent("IMG_2.jpg"))
        try Data("photo-A".utf8).write(to: dest.appendingPathComponent("IMG_1.jpg"))          // identical → duplicate
        try Data("someone else".utf8).write(to: dest.appendingPathComponent("IMG_2.jpg"))     // same name, different → "IMG_2 2.jpg"
        func photo(_ id: Int64, _ name: String) -> Photo {
            Photo(id: id, sourceID: 1, relPath: name, filename: name, ext: "jpg", siblings: [], fileSize: 7, fingerprint: nil, width: nil, height: nil,
                  takenAt: nil, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
        }
        let items = [ExportItem(photo: photo(1, "IMG_1.jpg"), sourceRoot: src, people: ["Me"]),
                     ExportItem(photo: photo(2, "IMG_2.jpg"), sourceRoot: src, people: ["Me"]),
                     ExportItem(photo: photo(3, "missing.jpg"), sourceRoot: src, people: ["Me"])]
        let report = Exporter.export(items, options: ExportOptions(destination: dest))
        XCTAssertEqual(report.duplicatesSkipped, ["IMG_1.jpg"])
        XCTAssertEqual(report.copied.map(\.lastPathComponent), ["IMG_2 2.jpg"])
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("IMG_2.jpg"), encoding: .utf8), "someone else", "existing file untouched")
        XCTAssertEqual(try String(contentsOf: src.appendingPathComponent("IMG_1.jpg"), encoding: .utf8), "photo-A", "original untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix(".pixora-partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExportByPersonCopiesIntoEachSelectedPersonsFolder() throws {
        let src = tmp.appendingPathComponent("card"); let dest = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("G.jpg"))
        let p = Photo(id: 1, sourceID: 1, relPath: "G.jpg", filename: "G.jpg", ext: "jpg", siblings: [], fileSize: 1, fingerprint: nil, width: nil,
                      height: nil, takenAt: nil, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
        var o = ExportOptions(destination: dest); o.organization = .byPerson
        let r = Exporter.export([ExportItem(photo: p, sourceRoot: src, people: ["Me", "A/B"])], options: o)
        XCTAssertEqual(r.copied.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Me/G.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("A-B/G.jpg").path), "slashes in names can't create nested folders")
    }

    // MARK: Scanner

    func testRawJpegPairsBecomeOnePhoto() throws {
        let dir = tmp.appendingPathComponent("DCIM/100CANON"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let jpg = ImageLoader.jpegData(ctx.makeImage()!, quality: 0.8)!
        try jpg.write(to: dir.appendingPathComponent("IMG_0001.JPG"))
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("IMG_0001.CR3"))
        try jpg.write(to: dir.appendingPathComponent("IMG_0002.JPG"))
        try Data().write(to: dir.appendingPathComponent("MVI_0003.MOV"))
        try Data().write(to: dir.appendingPathComponent(".hidden.jpg"))
        let p = FileScanner.preview(root: tmp)
        XCTAssertEqual(p.files.count, 2)
        XCTAssertEqual(p.rawPairs, 1)
        XCTAssertEqual(p.files.first { $0.filename == "IMG_0001.JPG" }?.siblings, ["DCIM/100CANON/IMG_0001.CR3"])
        XCTAssertEqual(p.videosSkipped, 1)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
