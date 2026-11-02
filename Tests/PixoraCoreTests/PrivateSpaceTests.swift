import XCTest
import CryptoKit
import Security
@testable import PixoraCore

final class PrivateSpaceTests: XCTestCase {
    var tmp: URL!
    var keychain: Keychain!
    var store: LibraryStore!
    var vault: PrivateVault!
    let pw = "correct horse battery"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-ps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("PIXORA_HOME", tmp.appendingPathComponent("home").path, 1)
        keychain = Keychain(service: "local.pixora.Pixora.unittest.\(UUID().uuidString)")
        store = LibraryStore(db: try Database(url: tmp.appendingPathComponent("lib.sqlite")))
        vault = PrivateVault(store: store, keychain: keychain)
    }

    override func tearDownWithError() throws {
        keychain.deleteAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    func vec(_ axis: Int, noise: Float = 0.03, seed: Int) -> [Float] {
        var g = SeededRNG(seed: UInt64(seed * 31 + axis))
        var v = (0..<64).map { _ in Float.random(in: -noise...noise, using: &g) }
        v[axis] += 1
        return Vector.normalized(v)
    }

    @discardableResult
    func addPhoto(_ name: String, faces: [(person: Int64?, state: FaceState, embedding: [Float])], src: Int64) throws -> Int64 {
        let id = try store.db.write { c -> Int64 in
            let p = try c.run("INSERT INTO photos(source_id, rel_path, filename, ext, file_size, mtime, fingerprint, scan_state, added_at, import_id) VALUES(?,?,?,?,?,?,?,1,?,1)",
                              src, "DCIM/\(name)", name, "jpg", 100, 0, "fp-\(name)", Date())
            for f in faces {
                try c.run("INSERT INTO faces(photo_id, x, y, w, h, pixel_size, quality, embedding, embedder, person_id, state, thumb, created_at) VALUES(?,0.1,0.1,0.2,0.2,300,0.9,?,?,?,?,?,?)",
                          p, Vector.data(f.embedding), "test", f.person, f.state.rawValue, Data("FACE-\(name)".utf8), Date())
            }
            return p
        }
        // A preview file with recognisable bytes.
        try Data("JPEGPREVIEW-\(name)".utf8).write(to: AppPaths.thumbnail(photoID: id))
        return id
    }

    // MARK: Password, keys, Keychain

    func testPasswordIsNeverStoredAndWrongPasswordFails() throws {
        try vault.setUp(password: pw, iterations: 2_000)
        XCTAssertTrue(vault.isUnlocked)
        vault.lockNow()
        XCTAssertFalse(vault.isUnlocked)
        XCTAssertThrowsError(try vault.unlock(password: "wrong password!!")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
        try vault.unlock(password: pw)
        XCTAssertTrue(vault.isUnlocked)
        // The Keychain item holds only the wrapped key, salt and public key — never the password.
        let item = try XCTUnwrap(keychain.data(for: "vault"))
        XCTAssertNil(item.range(of: Data(pw.utf8)), "password must not appear in stored config")
        XCTAssertNil(UserDefaults.standard.string(forKey: "vaultPassword"))
        XCTAssertThrowsError(try VaultCrypto.unwrap(try JSONDecoder().decode(PrivateVault.Config.self, from: item).wrappedKey,
                                                    with: SymmetricKey(size: .bits256)), "wrapped key can't be opened with another key")
    }

    func testWeakPasswordRejectedAndAttemptsRateLimited() throws {
        XCTAssertThrowsError(try vault.setUp(password: "short", iterations: 1_000))
        try vault.setUp(password: pw, iterations: 1_000)
        vault.lockNow()
        for _ in 0..<5 { XCTAssertThrowsError(try vault.unlock(password: "nope nope nope")) }
        XCTAssertThrowsError(try vault.unlock(password: pw)) { error in
            guard case .tooManyAttempts = error as? VaultError else { return XCTFail("expected rate limit, got \(error)") }
        }
    }

    func testChangePasswordRewrapsSameKey() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let src = try store.addSource(url: tmp)
        let id = try addPhoto("a.jpg", faces: [], src: src.id)
        try vault.makePhotosPrivate([id])
        try vault.changePassword(current: pw, new: "a brand new passphrase")
        vault.lockNow()
        XCTAssertThrowsError(try vault.unlock(password: pw))
        try vault.unlock(password: "a brand new passphrase")
        XCTAssertEqual(try vault.loadContent().items.count, 1, "items stay readable after a password change")
    }

    // MARK: Forgotten password: delete and recreate

    /// Writes real files to a pretend memory card so the test can prove deleting Private Space never touches them.
    func makeCard(_ names: [String]) throws -> (Source, [String: (Data, Date)]) {
        let card = tmp.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        var snapshot: [String: (Data, Date)] = [:]
        for n in names {
            let url = card.appendingPathComponent("DCIM/\(n)")
            try Data("ORIGINAL-BYTES-\(n)-\(UUID().uuidString)".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path)
            snapshot[n] = (try Data(contentsOf: url), try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date)
        }
        return (try store.addSource(url: card), snapshot)
    }

    func assertCardUntouched(_ src: Source, _ snapshot: [String: (Data, Date)], file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = src.url.appendingPathComponent("DCIM")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), Set(snapshot.keys), "no file added, removed or renamed", file: file, line: line)
        for (n, (bytes, mtime)) in snapshot {
            let url = dir.appendingPathComponent(n)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "\(n) unchanged", file: file, line: line)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, mtime, "\(n) not rewritten", file: file, line: line)
        }
    }

    func testDeletingPrivateSpaceRemovesOnlyPrivateDataAndNeverSourcePhotos() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let (src, snapshot) = try makeCard(["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg"])
        let ana = try store.createPerson(name: "Ana"), ben = try store.createPerson(name: "Ben")
        let p1 = try addPhoto("IMG_1.jpg", faces: [(ana, .confirmed, vec(0, seed: 1))], src: src.id)
        _ = try addPhoto("IMG_2.jpg", faces: [(ana, .confirmed, vec(0, seed: 2))], src: src.id)
        _ = try addPhoto("IMG_3.jpg", faces: [(ben, .confirmed, vec(1, seed: 3))], src: src.id)
        _ = try addPhoto("IMG_4.jpg", faces: [(ben, .confirmed, vec(1, seed: 4))], src: src.id)
        try vault.makePhotosPrivate([p1])
        try vault.makePersonPrivate(ben)
        XCTAssertEqual(try store.photos().map(\.filename), ["IMG_2.jpg"])

        vault.lockNow()   // forgotten password: everything below happens locked
        let f = vault.footprint()
        XCTAssertEqual(f.items, 3); XCTAssertEqual(f.people, 1); XCTAssertGreaterThan(f.faceTemplates, 0); XCTAssertGreaterThan(f.bytes, 0)

        try vault.destroy()

        try assertCardUntouched(src, snapshot)
        XCTAssertFalse(vault.isSetUp)
        XCTAssertTrue(vault.footprint().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.root.appendingPathComponent("Private").path), "private copies gone")
        XCTAssertNil(keychain.data(for: "vault")); XCTAssertNil(keychain.data(for: "device"))
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM people WHERE is_private = 1") }, 0)
        // The ordinary library is as it was: the public photo, Ana and her match.
        XCTAssertEqual(try store.photos().map(\.filename), ["IMG_2.jpg"])
        XCTAssertEqual(try store.search(people: [ana], mode: .any, includeUncertain: false).map(\.photo.filename), ["IMG_2.jpg"])
        XCTAssertNotNil(try store.people().first { $0.id == ana })
        // A rescan can find the formerly private photos again: nothing marks them private any more.
        XCTAssertTrue(vault.privateTokens().isEmpty)

        // A new Private Space with a new password; the old password means nothing.
        try vault.setUp(password: "a different passphrase", iterations: 1_000)
        vault.lockNow()
        XCTAssertThrowsError(try vault.unlock(password: pw))
        XCTAssertNoThrow(try vault.unlock(password: "a different passphrase"))
        XCTAssertTrue(try vault.loadContent().items.isEmpty, "the old encrypted Private Space is not recoverable")
        try assertCardUntouched(src, snapshot)
    }

    func testNewPrivateSpaceClearsUnopenableLeftovers() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let (src, snapshot) = try makeCard(["IMG_1.jpg", "IMG_2.jpg"])
        let p1 = try addPhoto("IMG_1.jpg", faces: [], src: src.id)
        _ = try addPhoto("IMG_2.jpg", faces: [], src: src.id)
        try vault.makePhotosPrivate([p1])
        keychain.delete("vault")   // the key is gone (e.g. Keychain items an older build wrote)
        XCTAssertTrue(vault.hasLeftovers)
        try vault.setUp(password: "a different passphrase", iterations: 1_000)
        XCTAssertFalse(vault.hasLeftovers)
        XCTAssertEqual(vault.footprint().items, 0)
        XCTAssertEqual(try store.photos().map(\.filename), ["IMG_2.jpg"])
        try assertCardUntouched(src, snapshot)
    }

    // MARK: Private photos

    func testPrivatePhotoIsEncryptedHiddenAndRestorable() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let src = try store.addSource(url: tmp)
        let ana = try store.createPerson(name: "Ana")
        let id = try addPhoto("SECRET_0042.jpg", faces: [(ana, .confirmed, vec(0, seed: 1))], src: src.id)
        _ = try addPhoto("public.jpg", faces: [(ana, .confirmed, vec(0, seed: 2))], src: src.id)
        vault.lockNow()
        try vault.makePhotosPrivate([id])   // works while locked

        // Gone from ordinary browsing, search, counts and caches.
        XCTAssertEqual(try store.photos().map(\.filename), ["public.jpg"])
        XCTAssertEqual(try store.search(people: [ana], mode: .any, includeUncertain: true).map(\.photo.filename), ["public.jpg"])
        XCTAssertEqual(try store.stats(currentEmbedder: "test").photos, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.thumbnail(photoID: id).path), "plaintext preview removed")
        XCTAssertEqual(try store.db.read { try $0.scalar("SELECT COUNT(*) FROM faces WHERE photo_id = ?", [id]) }, 0)

        // Encrypted at rest: the item file contains none of the plaintext.
        let files = try FileManager.default.contentsOfDirectory(at: PrivateVault.itemsDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let blob = try Data(contentsOf: files[0])
        for marker in ["SECRET_0042", "JPEGPREVIEW", "FACE-SECRET", "DCIM"] { XCTAssertNil(blob.range(of: Data(marker.utf8)), "\(marker) leaked") }
        XCTAssertFalse(files[0].lastPathComponent.contains("SECRET"), "file name reveals nothing")
        XCTAssertEqual(try store.db.read { try $0.query("PRAGMA secure_delete") { $0.int(0) }.first }, 1, "deleted rows are overwritten")

        // Locked: nothing can be read.
        XCTAssertThrowsError(try vault.loadContent()) { XCTAssertEqual($0 as? VaultError, .locked) }
        // Unlocked: it's there, with preview and faces.
        try vault.unlock(password: pw)
        let content = try vault.loadContent()
        XCTAssertEqual(content.items.map(\.photo.filename), ["SECRET_0042.jpg"])
        XCTAssertEqual(content.items[0].preview, Data("JPEGPREVIEW-SECRET_0042.jpg".utf8))
        XCTAssertLessThan(content.items[0].photo.id, 0, "stand-in id is never a library id")
        XCTAssertTrue(vault.privateTokens().contains(vault.pathToken(sourceID: src.id, relPath: "DCIM/SECRET_0042.jpg")), "rescans will skip it")

        // Back to the library.
        try vault.moveToLibrary([content.items[0].id])
        XCTAssertEqual(Set(try store.photos().map(\.filename)), ["public.jpg", "SECRET_0042.jpg"])
        XCTAssertTrue(try vault.loadContent().items.isEmpty)
        XCTAssertEqual(try store.search(people: [ana], mode: .any, includeUncertain: false).count, 2, "face links restored")
    }

    // MARK: Private people

    func testPrivatePersonRoutesFutureConfidentAndUncertainMatches() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let src = try store.addSource(url: tmp)
        let secret = try store.createPerson(name: "Secret Sam")
        let ben = try store.createPerson(name: "Ben")
        for i in 0..<3 { try addPhoto("sam\(i).jpg", faces: [(secret, .confirmed, vec(0, seed: i))], src: src.id) }
        try addPhoto("ben.jpg", faces: [(ben, .confirmed, vec(1, seed: 9))], src: src.id)
        vault.lockNow()

        try vault.makePersonPrivate(secret)
        XCTAssertEqual(try store.photos().map(\.filename), ["ben.jpg"], "existing photos of the private person moved in")
        XCTAssertFalse(try store.people().contains { $0.id == secret }, "private person hidden from People")
        XCTAssertNil(try store.db.read { try $0.query("SELECT name FROM people WHERE id = ?", [secret]) { $0.optText(0) }.first ?? nil }, "name not stored in plaintext")
        XCTAssertEqual(try store.stats(currentEmbedder: "test").namedPeople, 1)

        // A new scan brings a clear match, a borderline match and a stranger.
        try addPhoto("new-sam.jpg", faces: [(nil, .unassigned, vec(0, seed: 50))], src: src.id)
        var borderline = vec(0, noise: 0, seed: 0); borderline[5] = 0.9; borderline = Vector.normalized(borderline)   // ~0.74 similar
        try addPhoto("maybe-sam.jpg", faces: [(nil, .unassigned, borderline)], src: src.id)
        try addPhoto("stranger.jpg", faces: [(nil, .unassigned, vec(7, seed: 3))], src: src.id)
        try vault.matchAndRoute(embedderID: "test", thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))

        XCTAssertEqual(Set(try store.photos().map(\.filename)), ["ben.jpg", "stranger.jpg"], "matches never reach the public library")
        try vault.unlock(password: pw)
        let content = try vault.loadContent()
        XCTAssertEqual(content.people.map(\.name), ["Secret Sam"])
        let byName = Dictionary(uniqueKeysWithValues: content.items.map { ($0.photo.filename, $0) })
        XCTAssertEqual(byName["new-sam.jpg"]?.persons, [secret])
        XCTAssertFalse(byName["new-sam.jpg"]!.isPendingReview)
        XCTAssertTrue(byName["maybe-sam.jpg"]!.isPendingReview, "uncertain match goes to the private review queue")

        // Review: reject the borderline one → back to the library, not suggested for Sam again.
        try vault.rejectPending(byName["maybe-sam.jpg"]!.id)
        XCTAssertTrue(try store.photos().contains { $0.filename == "maybe-sam.jpg" })
        try vault.matchAndRoute(embedderID: "test", thresholds: MatchThresholds(certain: 0.8, suggest: 0.5, group: 0.8))
        XCTAssertTrue(try store.photos().contains { $0.filename == "maybe-sam.jpg" }, "a rejected match isn't routed back")

        // Making Sam public again returns photos that were private only because of Sam.
        try vault.makePersonPublic(secret)
        XCTAssertEqual(try store.people().first { $0.id == secret }?.name, "Secret Sam")
        XCTAssertEqual(try store.search(people: [secret], mode: .any, includeUncertain: false).count, 4)
        XCTAssertTrue(try vault.loadContent().items.isEmpty)
    }

    func testHandMarkedPhotoStaysPrivateWhenPersonMadePublic() throws {
        try vault.setUp(password: pw, iterations: 1_000)
        let src = try store.addSource(url: tmp)
        let sam = try store.createPerson(name: "Sam")
        let a = try addPhoto("a.jpg", faces: [(sam, .confirmed, vec(0, seed: 1))], src: src.id)
        try vault.makePhotosPrivate([a])
        try vault.makePersonPrivate(sam)
        try vault.makePersonPublic(sam)
        XCTAssertEqual(try vault.loadContent().items.map(\.photo.filename), ["a.jpg"], "marked private by hand stays private")
    }
}
