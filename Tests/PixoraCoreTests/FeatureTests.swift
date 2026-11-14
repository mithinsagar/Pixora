import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PixoraCore

final class FeatureTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-ft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("PIXORA_HOME", tmp.appendingPathComponent("home").path, 1)   // never touch the real library
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func makeStore() throws -> LibraryStore { LibraryStore(db: try Database(url: tmp.appendingPathComponent("lib.sqlite"))) }

    @discardableResult
    func photo(_ store: LibraryStore, _ source: Int64, _ name: String, taken: Double? = nil, faces: [(Int64?, FaceState, Double)]) throws -> Int64 {
        try store.db.write { c in
            let pid = try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, fingerprint, scan_state, taken_at, added_at) VALUES(?,?,?,?,?,?,?,1,?,?)",
                                source, name, name, "jpg", 100, 0, name, taken, Date())
            for (person, state, size) in faces {
                try c.run("INSERT INTO faces(photo_id, x, y, w, h, pixel_size, person_id, state, created_at) VALUES(?,0,0,0.1,0.1,?,?,?,?)", pid, size, person, state.rawValue, Date())
            }
            return pid
        }
    }

    func testOnlyThemMeansNobodyElseOfSimilarSize() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let me = try store.createPerson(name: "Me"), friend = try store.createPerson(name: "Friend")
        let solo = try photo(store, src.id, "solo.jpg", faces: [(me, .confirmed, 400)])
        let soloWithTinyBackground = try photo(store, src.id, "solo-bg.jpg", faces: [(me, .confirmed, 400), (nil, .unassigned, 60)])
        _ = try photo(store, src.id, "with-stranger.jpg", faces: [(me, .confirmed, 400), (nil, .unassigned, 350)])
        let withFriend = try photo(store, src.id, "with-friend.jpg", faces: [(me, .confirmed, 400), (friend, .auto, 380)])
        _ = try photo(store, src.id, "with-small-unrecognisable.jpg", faces: [(me, .confirmed, 400), (nil, .unassigned, 200)])
        let got = Set(try store.search(people: [me], mode: .only, includeUncertain: false).map(\.photo.id))
        XCTAssertEqual(got, [solo, soloWithTinyBackground])
        // Two people "only": both present, nobody else.
        let pair = try photo(store, src.id, "pair.jpg", faces: [(me, .confirmed, 400), (friend, .confirmed, 390)])
        _ = try photo(store, src.id, "pair-plus.jpg", faces: [(me, .confirmed, 400), (friend, .confirmed, 390), (nil, .unassigned, 380)])
        XCTAssertEqual(Set(try store.search(people: [me, friend], mode: .only, includeUncertain: false).map(\.photo.id)), [pair, withFriend])
    }

    func testBurstsGroupByTimeAndSource() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let a = try photo(store, src.id, "a.jpg", taken: 1000, faces: [])
        let b = try photo(store, src.id, "b.jpg", taken: 1001, faces: [])
        let c = try photo(store, src.id, "c.jpg", taken: 1002.5, faces: [])
        let d = try photo(store, src.id, "d.jpg", taken: 1010, faces: [])
        try Enrichment.groupBursts(store: store)
        let bursts = try store.db.read { try $0.query("SELECT id, burst_id FROM photos") { ($0.int(0), $0.optInt(1)) } }
        let map = Dictionary(uniqueKeysWithValues: bursts)
        XCTAssertEqual(map[a]!, a); XCTAssertEqual(map[b]!, a); XCTAssertEqual(map[c]!, a)
        XCTAssertNil(map[d]!, "a photo 7.5 s later is not part of the burst")
    }

    func testReviewAsksOnlyAboutNamedPeople() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let ana = try store.createPerson(name: "Ana"), group = try store.createPerson(name: nil)
        try photo(store, src.id, "1.jpg", faces: [(ana, .confirmed, 300), (ana, .suggested, 300)])
        try photo(store, src.id, "2.jpg", faces: [(group, .auto, 300), (group, .suggested, 300)])
        let asked = try store.uncertainFaces()
        XCTAssertEqual(asked.map(\.personID), [ana], "no “Is this Unnamed?” questions")
        let stats = try store.stats(currentEmbedder: "x")
        XCTAssertEqual(stats.uncertainItems, 1, "the question count matches what Review asks")
        XCTAssertEqual(stats.reviewItems, 2, "the Mac badge adds the unnamed group to name")
        try store.confirmAllUncertain()
        let states = try store.db.read { try $0.query("SELECT person_id, state FROM faces WHERE state <> 2") { ($0.int(0), $0.int(1)) } }
        XCTAssertFalse(states.contains { $0 == (ana, 1) }, "Ana's suggestion was accepted")
        XCTAssertTrue(states.contains { $0 == (group, 1) }, "Accept All leaves the unnamed group's suggestion alone")
        // Once the group gets a name, its suggestion is asked about.
        _ = try store.name(personID: group, as: "Ben")
        XCTAssertEqual(try store.uncertainFaces().count, 1)
    }

    func testAcceptAllUncertainForOnePerson() throws {
        let store = try makeStore()
        let src = try store.addSource(url: tmp)
        let ana = try store.createPerson(name: "Ana"), ben = try store.createPerson(name: "Ben")
        try photo(store, src.id, "1.jpg", faces: [(ana, .suggested, 300), (ben, .suggested, 300)])
        try store.confirmAllUncertain(personID: ana)
        let states = try store.db.read { try $0.query("SELECT person_id, state FROM faces") { ($0.int(0), $0.int(1)) } }
        XCTAssertEqual(states.first { $0.0 == ana }?.1, 3)
        XCTAssertEqual(states.first { $0.0 == ben }?.1, 1, "other people's suggestions are untouched")
        try store.rejectAllUncertain(personID: ben)
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM rejections WHERE person_id = ?", [ben]) }, 1)
    }

    func testCommandParser() {
        let people: [(id: Int64, name: String)] = [(1, "Asha Rao"), (2, "Ben"), (3, "me")]
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        var c = CommandParser.parse("me + asha, october, solo, best, copy to desktop", people: people, now: now)
        XCTAssertEqual(Set(c.people), [3, 1])
        XCTAssertEqual(c.mode, .only)
        XCTAssertTrue(c.bestOnly)
        XCTAssertEqual(c.action, .export(destination: "desktop"))
        XCTAssertEqual(c.from, Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(c.to, Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        c = CommandParser.parse("ben or asha share", people: people, now: now)
        XCTAssertEqual(c.mode, .any); XCTAssertEqual(c.action, .share); XCTAssertEqual(Set(c.people), [1, 2])
        c = CommandParser.parse("ben with zorblax", people: people, now: now)
        XCTAssertEqual(c.unknown, ["zorblax"], "unknown words are reported, never guessed")
        c = CommandParser.parse("asha december", people: people, now: now)
        XCTAssertEqual(Calendar.current.component(.year, from: c.from!), 2025, "a future month means last year's")
    }

    func makeJPEG(_ url: URL) throws {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        try ImageLoader.jpegData(ctx.makeImage()!, quality: 0.9)!.write(to: url)
    }

    func testNamesAreWrittenIntoExportedCopiesNotOriginals() throws {
        let src = tmp.appendingPathComponent("card"), dest = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeJPEG(src.appendingPathComponent("IMG_1.jpg"))
        try Data("raw bytes".utf8).write(to: src.appendingPathComponent("IMG_1.CR3"))
        let before = Fingerprint.full(url: src.appendingPathComponent("IMG_1.jpg"))
        let p = Photo(id: 1, sourceID: 1, relPath: "IMG_1.jpg", filename: "IMG_1.jpg", ext: "jpg", siblings: ["IMG_1.CR3"], fileSize: 1, fingerprint: nil,
                      width: 64, height: 48, takenAt: nil, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
        var o = ExportOptions(destination: dest); o.preset = .originalsWithRAW
        let r = Exporter.export([ExportItem(photo: p, sourceRoot: src, people: ["Ana", "Ben"])], options: o)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(PeopleMetadata.names(in: dest.appendingPathComponent("IMG_1.jpg")), ["Ana", "Ben"])
        XCTAssertTrue(PeopleMetadata.names(in: src.appendingPathComponent("IMG_1.jpg")).isEmpty, "original untouched")
        XCTAssertEqual(Fingerprint.full(url: src.appendingPathComponent("IMG_1.jpg")), before)
        let sidecar = try String(contentsOf: dest.appendingPathComponent("IMG_1.xmp"), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("Ana") && sidecar.contains("PersonInImage"), "RAW gets an XMP sidecar")
        // Exporting again: identical tagged copy is recognised as a duplicate.
        let again = Exporter.export([ExportItem(photo: p, sourceRoot: src, people: ["Ana", "Ben"])], options: o)
        XCTAssertTrue(again.duplicatesSkipped.contains("IMG_1.jpg"))
    }

    func testExportFoldersOverrideAndZip() throws {
        let src = tmp.appendingPathComponent("card"), dest = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeJPEG(src.appendingPathComponent("G.jpg"))
        let p = Photo(id: 1, sourceID: 1, relPath: "G.jpg", filename: "G.jpg", ext: "jpg", siblings: [], fileSize: 1, fingerprint: nil,
                      width: 64, height: 48, takenAt: nil, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
        var o = ExportOptions(destination: dest); o.zipFolders = true
        let r = Exporter.export([ExportItem(photo: p, sourceRoot: src, people: ["Ana", "Ben"], folders: ["Ana"]),
                                 ExportItem(photo: p, sourceRoot: src, people: ["Ana", "Ben"], folders: ["Ben"])], options: o)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Ana/G.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Ben/G.jpg").path))
        XCTAssertEqual(Set(r.zips.map(\.lastPathComponent)), ["Ana.zip", "Ben.zip"])
    }

    func testContactSheetPDF() throws {
        let url = tmp.appendingPathComponent("sheet.pdf")
        let photos = (1...23).map { i in Photo(id: Int64(i), sourceID: 1, relPath: "x\(i).jpg", filename: "x\(i).jpg", ext: "jpg", siblings: [], fileSize: 1,
                                               fingerprint: nil, width: nil, height: nil, takenAt: nil, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil) }
        try ContactSheet.render(photos.map { .init(photo: $0, caption: "Ana") }, title: "Ana", subtitle: "23 photos", watermark: "PROOF", to: url)
        let doc = CGPDFDocument(url as CFURL)
        XCTAssertEqual(doc?.numberOfPages, 2, "20 frames per page")
    }
}

final class UndoTests: XCTestCase {
    func testUndoRestoresPeopleExactly() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("PIXORA_HOME", tmp.appendingPathComponent("home").path, 1)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LibraryStore(db: try Database(url: tmp.appendingPathComponent("lib.sqlite")))
        let src = try store.addSource(url: tmp)
        let ana = try store.createPerson(name: "Ana"), group = try store.createPerson(name: nil), ben = try store.createPerson(name: "Ben")
        try store.db.write { c in
            let p = try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, scan_state, added_at) VALUES(?,?,?,?,?,?,1,?)", src.id, "a.jpg", "a.jpg", "jpg", 1, 0, Date())
            for (person, state) in [(ana, 3), (ana, 1), (group, 2), (group, 2), (ben, 3)] {
                try c.run("INSERT INTO faces(photo_id, x, y, w, h, embedding, embedder, person_id, state, thumb, created_at) VALUES(?,0,0,0.1,0.1,?,?,?,?,?,?)",
                          p, Vector.data([1, 2, 3]), "arcface", person, state, Data([9, 9]), Date())
            }
        }
        func dump() throws -> String {
            try store.db.read { c in
                let f = try c.query("SELECT id, person_id, state, score, embedding IS NOT NULL, length(thumb) FROM faces ORDER BY id") { "\($0.int(0)):\($0.optInt(1) ?? -1):\($0.int(2)):\($0.int(4)):\($0.int(5))" }
                let p = try c.query("SELECT id, name FROM people ORDER BY id") { "\($0.int(0)):\($0.optText(1) ?? "-")" }
                let r = try c.query("SELECT face_id, person_id FROM rejections ORDER BY 1, 2") { "\($0.int(0))>\($0.int(1))" }
                return (f + ["|"] + p + ["|"] + r).joined(separator: " ")
            }
        }
        let before = try dump()
        let benFaces = try store.faces(personID: ben).map(\.id)
        let snap = try store.captureUndo("several things", fragileFaceIDs: benFaces + [try store.faces(personID: group).first!.id])
        try store.name(personID: group, as: "ana")                    // merges the group into Ana
        try store.reject(faceIDs: [try store.faces(personID: ana).first!.id])
        try store.forget(personID: ben)                               // deletes Ben and his face templates
        try store.confirmAllUncertain()
        XCTAssertNotEqual(try dump(), before)
        try store.restore(snap)
        XCTAssertEqual(try dump(), before, "undo puts every person, face, template and rejection back")
    }
}
