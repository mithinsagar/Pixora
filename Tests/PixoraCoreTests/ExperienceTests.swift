import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import PixoraCore

final class ExperienceTests: XCTestCase {
    func photo(_ id: Int64, _ date: Date?) -> Photo {
        Photo(id: id, sourceID: 1, relPath: "\(id).jpg", filename: "\(id).jpg", ext: "jpg", siblings: [], fileSize: 1, fingerprint: nil,
              width: 4000, height: 3000, takenAt: date, camera: nil, lens: nil, rating: nil, scanState: 1, scanError: nil)
    }
    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }
    func solid(_ r: Double, _ g: Double, _ b: Double, side: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }
    func average(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let c = AmbientBackdrop.averageColor(of: image).components!
        return (Double(c[0]), Double(c[1]), Double(c[2]))
    }

    // MARK: Swipe

    func testSwipeLocksToOneAxisAndFollowsTheFingers() {
        var s = ViewerSwipe()
        s.add(CGSize(width: -3, height: 1), at: 0)
        XCTAssertNil(s.axis, "too short to know yet")
        s.add(CGSize(width: -5, height: 2), at: 0.01)
        XCTAssertEqual(s.axis, .horizontal)
        s.add(CGSize(width: -100, height: 40), at: 0.02)
        XCTAssertEqual(s.offset, CGSize(width: -108, height: 0), "a sideways swipe doesn't drift vertically")
    }

    func testSwipeNeedsDistanceOrSpeed() {
        var slow = ViewerSwipe()
        for i in 0..<10 { slow.add(CGSize(width: -10, height: 0), at: Double(i) * 0.1) }
        XCTAssertEqual(slow.outcome(width: 1000), .none, "100 pt, slowly, on a 1000 pt photo: goes back")
        var far = ViewerSwipe()
        for i in 0..<30 { far.add(CGSize(width: -10, height: 0), at: Double(i) * 0.1) }
        XCTAssertEqual(far.outcome(width: 1000), .left)
        var flick = ViewerSwipe()
        for i in 0..<6 { flick.add(CGSize(width: 20, height: 0), at: Double(i) * 0.01) }
        XCTAssertEqual(flick.outcome(width: 1000), .right, "short but fast")
    }

    func testFlickingBackCancelsASwipe() {
        var s = ViewerSwipe()
        for i in 0..<30 { s.add(CGSize(width: -3, height: 0), at: Double(i) * 0.01) }
        for i in 30..<38 { s.add(CGSize(width: 8, height: 0), at: Double(i) * 0.01) }
        XCTAssertEqual(s.outcome(width: 1000), .none, "ended near where it started, moving the other way")
    }

    func testLastPhotoRubberBandsAndStays() {
        var s = ViewerSwipe(allowLeft: false)
        for i in 0..<50 { s.add(CGSize(width: -20, height: 0), at: Double(i) * 0.01) }
        XCTAssertGreaterThan(s.offset.width, -90, "1000 pt of finger, under 90 pt of photo")
        XCTAssertLessThan(s.offset.width, -40)
        XCTAssertEqual(s.outcome(width: 1000), .none)
    }

    func testSwipeDownClosesAndNoVerticalMeansSideways() {
        var s = ViewerSwipe()
        for i in 0..<20 { s.add(CGSize(width: 0, height: 10), at: Double(i) * 0.1) }
        XCTAssertEqual(s.outcome(width: 1000), .down)
        var flat = ViewerSwipe(allowVertical: false)
        flat.add(CGSize(width: 2, height: 30), at: 0)
        XCTAssertEqual(flat.axis, .horizontal)
    }

    // MARK: Quick Pick

    func testPickSessionCountsAndUndoes() {
        var s = PickSession(ids: [1, 2, 3, 4])
        XCTAssertEqual(s.current, 1); XCTAssertEqual(s.upNext, 2)
        s.decide(.favorite)
        s.decide(.skip)
        s.decide(.keep, wasFavorite: true)
        XCTAssertEqual(s.current, 4)
        XCTAssertEqual(s.count(.favorite), 1); XCTAssertEqual(s.count(.skip), 1)
        XCTAssertEqual(s.kept, [1, 3], "skipped photos aren't picked")
        XCTAssertEqual(s.undo()?.wasFavorite, true)
        XCTAssertEqual(s.current, 3)
        s.decide(.skip); s.decide(.skip)
        XCTAssertTrue(s.isFinished)
        s.decide(.keep)
        XCTAssertEqual(s.history.count, 4, "nothing left to decide")
        XCTAssertEqual(s.progress, 1)
    }

    // MARK: Through Time

    func moment(_ id: Int64, _ date: Date, score: Double = 0.5, burst: Int64? = nil) -> FaceMoment {
        FaceMoment(faceID: id, photo: photo(id, date), date: date, rect: .zero, score: score, burstID: burst)
    }

    func testPlanKeepsTheBestOfABurstInDateOrder() {
        let t = day(2024, 1, 1)
        let plan = FaceTimeline.plan([moment(3, t.addingTimeInterval(100)), moment(1, t, score: 0.4, burst: 9), moment(2, t.addingTimeInterval(1), score: 0.9, burst: 9)])
        XCTAssertEqual(plan.map(\.faceID), [2, 3])
    }

    func testPlanSpreadsOverTheYearsAndStillFillsTheReel() {
        // 500 photos from one weekend, then one a year for ten years.
        var all = (0..<500).map { moment(Int64($0), day(2016, 3, 5).addingTimeInterval(Double($0) * 60)) }
        all += (1...10).map { moment(Int64(1000 + $0), day(2016 + $0, 6, 1)) }
        let plan = FaceTimeline.plan(all, maximum: 60)
        XCTAssertEqual(plan.count, 60)
        XCTAssertEqual(plan, plan.sorted { $0.date < $1.date })
        let years = Set(plan.map { Calendar.current.component(.year, from: $0.date) })
        XCTAssertEqual(years.count, 11, "the quiet years aren't crowded out: \(years.sorted())")
    }

    func testPlanOnOneDayStillGivesAFullReel() {
        let all = (0..<400).map { moment(Int64($0), day(2026, 10, 8).addingTimeInterval(Double($0) * 30)) }
        XCTAssertEqual(FaceTimeline.plan(all, maximum: 90).count, 90)
    }

    func testSpanLabelsReadNaturally() {
        XCTAssertEqual(FaceTimeline.spanLabel([moment(1, day(2019, 2, 1)), moment(2, day(2026, 3, 1))]), "2019 to 2026")
        XCTAssertEqual(FaceTimeline.spanLabel([moment(1, day(2026, 3, 1)), moment(2, day(2026, 10, 1))]), "March to October 2026")
        XCTAssertEqual(FaceTimeline.spanLabel([moment(1, day(2026, 10, 8, hour: 9)), moment(2, day(2026, 10, 8, hour: 18))]), "8 October 2026")
    }

    func testVideoHasEveryFrameAndPlays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("reel.mov")
        let frames = [solid(1, 0, 0), solid(0, 1, 0), solid(0, 0, 1)].enumerated().map { FaceTimeVideo.Frame(image: $1, caption: "Frame \($0)") }
        try await FaceTimeVideo.write(frames, title: "Ana", to: url, side: 240, secondsPerFrame: 0.2)
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 1.6, accuracy: 0.1, "3 × 0.2 s and a 1 s hold")
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 240, height: 240))
    }

    /// With `PIXORA_TEST_PORTRAIT` set to a photo of one person, checks the real Vision steps on it.
    func testEyesLandOnTheTemplateAndSubjectLifts() throws {
        guard let path = ProcessInfo.processInfo.environment["PIXORA_TEST_PORTRAIT"] else { throw XCTSkip("no portrait given") }
        let image = try XCTUnwrap(ImageLoader.image(at: URL(fileURLWithPath: path), maxPixel: 1600))
        let whole = CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        let frame = try XCTUnwrap(FaceFrames.frame(from: image, face: whole, side: 600))
        let eyes = try XCTUnwrap(FaceFrames.eyes(in: frame, near: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)))
        XCTAssertEqual(eyes.left.x / 600, FaceFrames.leftEye.x, accuracy: 0.02)
        XCTAssertEqual(eyes.left.y / 600, FaceFrames.leftEye.y, accuracy: 0.02)
        XCTAssertEqual(eyes.right.x / 600, FaceFrames.rightEye.x, accuracy: 0.02)

        let lift = try XCTUnwrap(SubjectLift.lift(image))
        XCTAssertEqual(lift.overlay.width, image.width)
        XCTAssertEqual(lift.overlay.height, image.height)
        XCTAssertLessThan(lift.cutout.width * lift.cutout.height, image.width * image.height, "trimmed to the subject")
        XCTAssertNotEqual(lift.cutout.alphaInfo, .none)
        let corner = try XCTUnwrap(SubjectLift.opaqueBounds(of: lift.overlay))
        XCTAssertGreaterThan(corner.width, 20)
    }

    // MARK: Colour

    func testAmbientTakesThePhotosColourAndStaysDark() throws {
        let red = average(try XCTUnwrap(AmbientBackdrop.make(from: solid(0.9, 0.1, 0.1))))
        XCTAssertGreaterThan(red.r, red.g * 2)
        XCTAssertGreaterThan(red.r, red.b * 2)
        let white = average(try XCTUnwrap(AmbientBackdrop.make(from: solid(1, 1, 1))))
        XCTAssertLessThan(0.2126 * white.r + 0.7152 * white.g + 0.0722 * white.b, 0.4, "a white photo must not light up the room")
        let black = average(try XCTUnwrap(AmbientBackdrop.make(from: solid(0, 0, 0))))
        XCTAssertLessThan(black.r + black.g + black.b, 0.05)
    }

    // MARK: Memories

    func testOnThisDayBeatsEverythingElse() throws {
        let today = day(2026, 11, 7)
        let m = try XCTUnwrap(Memories.make(from: [photo(1, day(2024, 11, 7)), photo(2, day(2023, 11, 7)), photo(3, day(2025, 11, 5)), photo(4, day(2026, 10, 7))], today: today))
        XCTAssertEqual(m.title, "On This Day")
        XCTAssertEqual(m.groups.map(\.label), ["Two Years Ago", "Three Years Ago"])
        XCTAssertEqual(Set(m.photos.map(\.id)), [1, 2])
    }

    func testMemoriesFallBackForAYoungLibrary() throws {
        let today = day(2026, 11, 7)
        XCTAssertEqual(Memories.make(from: [photo(1, day(2025, 11, 5))], today: today)?.title, "This Week in Past Years")
        XCTAssertEqual(Memories.make(from: [photo(1, day(2026, 10, 7))], today: today)?.title, "This Day, One Month Ago")
        XCTAssertEqual(Memories.make(from: [photo(1, day(2026, 10, 8))], today: today)?.title, "Around This Time, One Month Ago")
        XCTAssertEqual(Memories.make(from: [photo(1, day(2026, 5, 6))], today: today)?.title, "This Day, Six Months Ago".replacingOccurrences(of: "This Day", with: "Around This Time"))
    }

    func testNoMemoryWithoutSomethingToRemember() {
        let today = day(2026, 11, 7)
        XCTAssertNil(Memories.make(from: [], today: today))
        XCTAssertNil(Memories.make(from: [photo(1, nil)], today: today))
        XCTAssertNil(Memories.make(from: [photo(1, day(2026, 11, 7, hour: 9))], today: today), "today isn't a memory yet")
        XCTAssertNil(Memories.make(from: [photo(1, day(2026, 10, 20))], today: today), "two and a half weeks ago: no anniversary")
    }

    func testMemorySamplesEvenly() {
        let photos = (0..<400).map { photo(Int64($0), day(2025, 11, 7).addingTimeInterval(Double($0))) }
        let s = Memories.sample(photos, limit: 40)
        XCTAssertEqual(s.count, 40)
        XCTAssertEqual(s.first?.id, 0)
        XCTAssertEqual(s.last?.id, 390)
    }

    // MARK: Places

    func jpeg(gps: [CFString: Any]?, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(dest, solid(0.5, 0.5, 0.5), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testReadsGPSWithHemispheres() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let south = dir.appendingPathComponent("s.jpg"), none = dir.appendingPathComponent("n.jpg"), unset = dir.appendingPathComponent("u.jpg")
        try jpeg(gps: [kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S", kCGImagePropertyGPSLongitude: 70.5, kCGImagePropertyGPSLongitudeRef: "W"], to: south)
        try jpeg(gps: nil, to: none)
        try jpeg(gps: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"], to: unset)
        let m = ImageLoader.metadata(at: south)
        XCTAssertEqual(try XCTUnwrap(m.latitude), -33.86, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m.longitude), -70.5, accuracy: 0.001)
        XCTAssertNil(ImageLoader.metadata(at: none).latitude)
        XCTAssertNil(ImageLoader.metadata(at: unset).latitude, "0,0 means no fix, not the Gulf of Guinea")
    }

    func testLocationLeavesWithThePhoto() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(db: try Database(url: dir.appendingPathComponent("lib.sqlite")))
        let source = try store.addSource(url: dir)
        let id = try store.db.write { c in
            try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, scan_state, added_at) VALUES(?,?,?,?,?,?,?,?)",
                      source.id, "a.jpg", "a.jpg", "jpg", 1, 0.0, 1, Date())
        }
        XCTAssertEqual(try store.uncheckedPlaceCount(), 1)
        try store.setPlace(photoID: id, latitude: 13.08, longitude: 80.27)
        XCTAssertEqual(try store.placedPhotos().map(\.id), [id])
        XCTAssertEqual(try store.uncheckedPlaceCount(), 0)
        // What making a photo private does to its library row: nothing about where it was taken may stay behind.
        try store.db.write { try $0.run("DELETE FROM photos WHERE id = ?", id) }
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM photo_places") }, 0)
    }

    func testClustersGroupNeighboursAndSplitAsYouZoomIn() {
        let chennai = (0..<5).map { PlacedPhoto(photo: photo(Int64($0), day(2026, 1, 1 + $0)), latitude: 13.08 + Double($0) * 0.001, longitude: 80.27) }
        let paris = PlacedPhoto(photo: photo(10, day(2025, 1, 1)), latitude: 48.85, longitude: 2.35)
        let wide = Places.cluster(chennai + [paris], cell: 5)
        XCTAssertEqual(wide.map(\.photos.count), [5, 1])
        XCTAssertEqual(wide[0].latitude, 13.082, accuracy: 0.0001)
        XCTAssertEqual(wide[0].photos.first?.id, 4, "newest on top")
        XCTAssertEqual(Places.cluster(chennai + [paris], cell: 0.0005).count, 6)
    }
}
