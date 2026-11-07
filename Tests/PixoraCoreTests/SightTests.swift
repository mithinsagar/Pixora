import XCTest
import ImageIO
@testable import PixoraCore

final class SightTests: XCTestCase {
    /// a=10 b=11 c=12, ab=20 abc=21, and "▁"=13.
    private var tiny: SightTokenizer {
        SightTokenizer(singles: [97: 10, 98: 11, 99: 12, 0x2581: 13],
                       merges: [(left: 10, right: 11, token: 20), (left: 20, right: 12, token: 21)])
    }

    func testMergesInRankOrderEndsAndPads() {
        let ids = tiny.encode("ABC ab")
        XCTAssertEqual(Array(ids.prefix(5)), [21, 13, 20, 1, 0])
        XCTAssertEqual(ids.count, SightTokenizer.length)
    }

    func testUnknownCharactersFallBackToBytes() {
        XCTAssertEqual(Array(tiny.encode("é").prefix(3)), [217 + 0xC3, 217 + 0xA9, 1])
    }

    func testLongTextKeepsTheEndMarker() {
        let ids = tiny.encode(String(repeating: "a ", count: 200))
        XCTAssertEqual(ids.count, SightTokenizer.length)
        XCTAssertEqual(ids.last, 1)
    }

    /// Checked against the model's own tokenizer when the packed file is to hand.
    func testMatchesTheModelsTokenizer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let tokens = env["PIXORA_SIGHT_TOKENS"], let cases = env["PIXORA_SIGHT_CASES"] else { throw XCTSkip("needs the packed tokenizer") }
        let tokenizer = try SightTokenizer(contentsOf: URL(fileURLWithPath: tokens))
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cases))) as! [[String: Any]]
        XCTAssertFalse(list.isEmpty)
        for item in list {
            let text = item["text"] as! String
            XCTAssertEqual(tokenizer.encode(text), (item["ids"] as! [Int]).map(Int32.init), text)
        }
    }

    private func vector(_ axis: Int, _ weight: Float) -> [Float16] {
        var v = [Float16](repeating: 0, count: Sight.dimension)
        v[axis] = Float16(weight)
        return v
    }

    private func library(_ photos: [(Int64, [[Float16]])]) -> SightLibrary {
        var out = SightLibrary()
        for (id, views) in photos {
            out.ids.append(id)
            for view in views { view.withUnsafeBytes { out.vectors.append(contentsOf: $0) } }
        }
        return out
    }

    func testAPhotoScoresAsWellAsItsBestViewAndWeakOnesStayMaybes() {
        var query = [Float](repeating: 0, count: Sight.dimension)
        query[7] = 1
        let empty = vector(0, 0)
        let lib = library([(1, [empty, empty, empty, empty, vector(7, 0.5)]),   // only in a corner
                           (2, [vector(7, 0.2), empty, empty, empty, empty]),
                           (3, [vector(7, 0.01), empty, empty, empty, empty])])
        let hits = lib.hits(for: query, best: 0.3, maybe: 0.1)
        XCTAssertEqual(hits.map(\.photoID), [1, 2])
        XCTAssertEqual(hits.map(\.isBest), [true, false])
        XCTAssertEqual(hits[0].score, 0.5, accuracy: 0.001)
    }

    func testScoresAreRightPastTheFirstChunkOfPhotos() {
        var query = [Float](repeating: 0, count: Sight.dimension)
        query[3] = 1
        let empty = vector(0, 0), photos = (0..<1100).map { i in (Int64(i), [i == 1050 ? vector(3, 0.9) : empty, empty, empty, empty, empty]) }
        XCTAssertEqual(library(photos).hits(for: query, best: 0.5, maybe: 0.1).map(\.photoID), [1050])
    }

    func testNothingCloseEnoughMeansNoResults() {
        var query = [Float](repeating: 0, count: Sight.dimension)
        query[3] = 1
        XCTAssertTrue(library([(1, Array(repeating: vector(9, 1), count: 5))]).hits(for: query).isEmpty)
        XCTAssertTrue(SightLibrary().hits(for: query).isEmpty)
    }

    func testViewsCoverTheWholePhotoAndOverlap() {
        let rects = Sight.viewRects(width: 640, height: 480)
        XCTAssertEqual(rects.count, Sight.views)
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(rects[4].maxX, 640)
        XCTAssertEqual(rects[4].maxY, 480)
        XCTAssertTrue(rects[1].intersects(rects[4]), "a subject in the middle isn't cut in half by every corner")
    }

    private func storeWithPhotos(_ count: Int) throws -> (LibraryStore, [Int64], URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryStore(db: try Database(url: dir.appendingPathComponent("lib.sqlite")))
        let source = try store.addSource(url: dir)
        let ids = try (0..<count).map { i in
            try store.db.write { c in
                try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, scan_state, added_at) VALUES(?,?,?,?,?,?,?,?)",
                          source.id, "\(i).jpg", "\(i).jpg", "jpg", 1, 0.0, 1, Date())
            }
        }
        return (store, ids, dir)
    }

    func testDeepScanPicksUpWhereItLeftOffAndSkipsUnreadablePhotos() throws {
        let (store, ids, dir) = try storeWithPhotos(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try store.sightPending(), ids)
        try store.saveSight(photoID: ids[0], vectors: Data(count: Sight.vectorBytes))
        try store.saveSight(photoID: ids[1], vectors: Data())
        XCTAssertEqual(try store.sightPending(), [ids[2]])
        XCTAssertEqual(try store.sightCounts().done, 2)
        XCTAssertEqual(try store.sightLibrary().ids, [ids[0]], "a photo that couldn't be read is never searched")
    }

    func testThePhotosRowGoingTakesItsNumbersWithIt() throws {
        let (store, ids, dir) = try storeWithPhotos(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveSight(photoID: ids[0], vectors: Data(count: Sight.vectorBytes))
        try store.db.write { try $0.run("DELETE FROM photos WHERE id = ?", ids[0]) }
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM photo_sight") }, 0)
        try store.saveSight(photoID: ids[0], vectors: Data(count: Sight.vectorBytes))
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM photo_sight") }, 0, "a late save can't bring a private photo back")
    }

    func testAChangedFileIsLookedAtAgain() throws {
        let (store, ids, dir) = try storeWithPhotos(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveSight(photoID: ids[0], vectors: Data(count: Sight.vectorBytes))
        let file = ScanFile(relPath: "0.jpg", filename: "0.jpg", ext: "jpg", size: 2, mtime: 5, siblings: [])
        _ = try store.recordScan(sourceID: 1, importID: try store.db.write { c in try c.run("INSERT INTO imports(source_id, started_at, status) VALUES(1,?,'done')", Date()) },
                                 file: file, metadata: PhotoMetadata(), fingerprint: nil, faces: [], embedderID: "t", error: nil)
        XCTAssertEqual(try store.sightPending(), ids)
    }

    private func zipped(in dir: URL, named name: String) throws -> Sight.Asset {
        let folder = dir.appendingPathComponent("made-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights \(name)".utf8).write(to: folder.appendingPathComponent("\(name).bin"))
        let zip = dir.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return Sight.Asset(name: "\(name).zip", bytes: Int64(size), sha256: try Sight.sha256(of: zip))
    }

    func testInstallerPutsEverythingInPlaceOnlyWhenItAllChecksOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = [try zipped(in: dir, named: "one"), try zipped(in: dir, named: "two")]
        let target = dir.appendingPathComponent("Models/Sight", isDirectory: true)

        try await SightInstaller(assets: good, base: dir, destination: target) { _ in }.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("one.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("two.bin").path))
        try FileManager.default.removeItem(at: target)

        let damaged = [good[0], Sight.Asset(name: good[1].name, bytes: good[1].bytes, sha256: String(repeating: "0", count: 64))]
        do {
            try await SightInstaller(assets: damaged, base: dir, destination: target) { _ in }.run()
            XCTFail("a file that doesn't match its checksum must not install")
        } catch {
            XCTAssertEqual(error as? SightInstallError, .damaged(good[1].name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing half-installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("SightIncoming").path))
    }

    func testNamesNarrowTheSearchAndTheRestDescribesThePhoto() {
        let people: [(id: Int64, name: String)] = [(1, "Asha"), (2, "Ana Maria"), (3, "Ana")]
        let both = SightQuery.split("Ana Maria and asha  birthday cake", people: people)
        XCTAssertEqual(both.people.sorted(), [1, 2])
        XCTAssertEqual(both.words, "and birthday cake")
        XCTAssertEqual(SightQuery.split("banana", people: people).people, [], "only whole words are names")
        XCTAssertEqual(SightQuery.split("a parrot on a branch", people: people).words, "a parrot on a branch")
    }

    /// Searching while the deep scan runs: this aborted the app until the models took turns.
    func testSearchingDuringADeepScanIsSafe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PIXORA_SIGHT_REFS"], let home = env["PIXORA_SIGHT_HOME"] else { throw XCTSkip("needs the installed model") }
        setenv("PIXORA_HOME", home, 1)   // other tests move it
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let refs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let file = (refs["images"] as! [[String: Any]])[0]["file"] as! String
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(base.appendingPathComponent(file) as CFURL, nil)!, 0, nil)!
        async let scanned: Int = Task.detached(priority: .utility) {
            let vision = try SightVision()
            for _ in 0..<12 { _ = try vision.vectors(for: image) }
            return 12
        }.value
        async let searched: Int = Task.detached {
            let text = try SightText()
            for i in 0..<60 { _ = try text.vector(for: "search number \(i)") }
            return 60
        }.value
        let (a, b) = try await (scanned, searched)
        XCTAssertEqual(a + b, 72)
    }

    /// The real model, run the way the app runs it, against the numbers the accuracy tests were measured on.
    func testSwiftSeesWhatTheMeasuredModelSaw() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PIXORA_SIGHT_REFS"], let home = env["PIXORA_SIGHT_HOME"] else { throw XCTSkip("needs the installed model and reference numbers") }
        setenv("PIXORA_HOME", home, 1)   // other tests move it
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let refs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let dot = { (a: [Float], b: [Float]) in zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        let text = try SightText()
        let started = Date()
        _ = try text.vector(for: "warm up")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the first search has to feel immediate")
        for item in refs["texts"] as! [[String: Any]] {
            let agreement = dot(try text.vector(for: item["text"] as! String), (item["vector"] as! [Double]).map(Float.init))
            XCTAssertGreaterThan(agreement, 0.999, item["text"] as! String)
        }
        let vision = try SightVision()
        var worst: Float = 1
        for item in refs["images"] as! [[String: Any]] {
            let url = base.appendingPathComponent(item["file"] as! String)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let data = try vision.vectors(for: CGImageSourceCreateImageAtIndex(source, 0, nil)!)
            XCTAssertEqual(data.count, Sight.vectorBytes)
            let halves: [Float16] = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            let whole = halves[..<Sight.dimension].map { Float($0) }
            worst = min(worst, dot(whole, (item["whole"] as! [Double]).map(Float.init)))
        }
        print("worst agreement with the measured model:", worst)
        XCTAssertGreaterThan(worst, 0.97)
    }
}
