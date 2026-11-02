import Foundation
import CryptoKit

/// Private Space.
///
/// Key design
/// - A random X25519 key pair is created at setup. The **public key** encrypts new private items (so scans can
///   route a private person's photos in even while Private Space is locked). The **private key** decrypts them.
/// - The private key is stored only *wrapped*: AES-256-GCM under a key derived from the user's password with
///   PBKDF2-HMAC-SHA256 (600,000 iterations, random salt). The wrapped key, salt and public key live in the
///   macOS Keychain (this device only). The password itself is never stored anywhere.
/// - There is no recovery mechanism: a forgotten password means deleting Private Space (`destroy`) and creating
///   a new one. The only copy of the password outside the user's head is a file they choose to save themselves.
/// - Each private photo becomes one encrypted file `Private/items/<uuid>.pxv` holding its metadata, faces (with
///   face templates and crops) and preview. Plaintext rows are deleted from the library with SQLite
///   `secure_delete` on, the WAL is checkpointed, and preview / face-crop cache files are removed.
/// - Two things must stay usable while locked, so they use a separate random **device key** kept in the
///   Keychain: keyed hashes (HMAC-SHA256) of private photos' paths and fingerprints, so a rescan doesn't re-add
///   them; and the face templates of private people, so new matches can be routed. These are protected at rest
///   (useless without the Keychain item) but not by the password.
public final class PrivateVault: @unchecked Sendable {
    public let store: LibraryStore
    public let keychain: Keychain
    private let lock = NSLock()
    private var secretKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedDeviceKey: SymmetricKey?

    public init(store: LibraryStore, keychain: Keychain = .app) {
        self.store = store
        self.keychain = keychain
    }

    public static var itemsDirectory: URL {
        let url = AppPaths.root.appendingPathComponent("Private/items", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Configuration

    struct Config: Codable {
        var version = 2
        var iterations: Int
        var salt: Data
        var wrappedKey: Data
        var publicKey: Data
        var createdAt: Date
        var passwordChangedAt: Date?
    }

    var config: Config? {
        keychain.data(for: "vault").flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    private func save(_ c: Config) throws { try keychain.set(try JSONEncoder().encode(c), for: "vault") }

    public var isSetUp: Bool { config != nil }
    public var isUnlocked: Bool { lock.withLock { secretKey != nil } }
    public var createdAt: Date? { config?.createdAt }
    public var passwordChangedAt: Date? { config?.passwordChangedAt }

    /// What Private Space holds, countable while locked — shown before deleting it.
    public struct Footprint: Equatable, Sendable {
        public var items = 0          // encrypted photo copies (including ones waiting in private review)
        public var people = 0         // private people (encrypted names, face templates for routing)
        public var faceTemplates = 0
        public var bytes: Int64 = 0   // size of the encrypted files
        public var isEmpty: Bool { items == 0 && people == 0 && faceTemplates == 0 && bytes == 0 }
        public init() {}
    }

    public func footprint() -> Footprint {
        var f = Footprint()
        f.items = (try? store.db.read { try $0.query("SELECT COUNT(*) FROM private_items") { Int($0.int(0)) } }.first) ?? 0
        f.people = (try? store.db.read { try $0.query("SELECT COUNT(*) FROM people WHERE is_private = 1") { Int($0.int(0)) } }.first) ?? 0
        f.faceTemplates = (try? store.db.read { try $0.query("SELECT COUNT(*) FROM private_refs") { Int($0.int(0)) } }.first) ?? 0
        let dir = AppPaths.root.appendingPathComponent("Private", isDirectory: true)
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { f.bytes += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return f
    }

    /// Private data left behind without a usable key (e.g. from an earlier version whose Keychain items this
    /// build can't read). Creating a new Private Space deletes it first.
    public var hasLeftovers: Bool { !isSetUp && !footprint().isEmpty }

    private func publicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let c = config else { throw VaultError.notSetUp }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: c.publicKey)
    }

    private func requireKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let k = lock.withLock({ secretKey }) else { throw VaultError.locked }
        return k
    }

    /// At least 10 characters, not all the same character.
    public static func checkStrength(_ password: String) throws {
        if password.count < 10 { throw VaultError.weakPassword("Use at least 10 characters — a short phrase is easiest to remember.") }
        if Set(password).count < 4 { throw VaultError.weakPassword("That password is too repetitive.") }
    }

    // MARK: Setup, unlock, lock, password

    /// Create Private Space with a password made for this app. Anything left from an earlier Private Space that
    /// can no longer be opened is deleted first (never source files).
    public func setUp(password: String, iterations: Int = VaultCrypto.defaultIterations) throws {
        guard config == nil else { throw VaultError.alreadySetUp }
        try Self.checkStrength(password)
        if hasLeftovers { try destroy() }
        let sk = Curve25519.KeyAgreement.PrivateKey()
        let salt = VaultCrypto.randomBytes(16)
        let kek = try VaultCrypto.deriveKey(password: password, salt: salt, iterations: iterations)
        let c = Config(iterations: iterations, salt: salt,
                       wrappedKey: try VaultCrypto.wrap(sk.rawRepresentation, with: kek),
                       publicKey: sk.publicKey.rawRepresentation, createdAt: Date())
        try save(c)
        lock.withLock { secretKey = sk }
    }

    public func unlock(password: String) throws {
        guard let c = config else { throw VaultError.notSetUp }
        try checkAttempts()
        let kek = try VaultCrypto.deriveKey(password: password, salt: c.salt, iterations: c.iterations)
        guard let raw = try? VaultCrypto.unwrap(c.wrappedKey, with: kek),
              let sk = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            recordFailure()
            throw VaultError.wrongPassword
        }
        keychain.delete("vault.attempts")
        lock.withLock { secretKey = sk }
    }

    /// Forget the private key. Decrypted content held by the app must be dropped by the caller too.
    public func lockNow() { lock.withLock { secretKey = nil } }

    /// Re-wrap the same private key under a new password (items don't need re-encrypting).
    public func changePassword(current: String, new: String) throws {
        guard var c = config else { throw VaultError.notSetUp }
        try Self.checkStrength(new)
        try checkAttempts()
        let oldKek = try VaultCrypto.deriveKey(password: current, salt: c.salt, iterations: c.iterations)
        guard let raw = try? VaultCrypto.unwrap(c.wrappedKey, with: oldKek) else { recordFailure(); throw VaultError.wrongPassword }
        keychain.delete("vault.attempts")
        c.salt = VaultCrypto.randomBytes(16)
        c.wrappedKey = try VaultCrypto.wrap(raw, with: try VaultCrypto.deriveKey(password: new, salt: c.salt, iterations: c.iterations))
        c.passwordChangedAt = Date()
        try save(c)
    }

    // Unlock attempts: 5 free, then 30 s, 1 min, 5 min, then 15 min between tries. Stored in the Keychain.
    private struct Attempts: Codable { var failures: Int; var last: Date }

    private func checkAttempts() throws {
        guard let d = keychain.data(for: "vault.attempts"), let a = try? JSONDecoder().decode(Attempts.self, from: d), a.failures >= 5 else { return }
        let wait: TimeInterval = [30, 60, 300][min(a.failures - 5, 2)] + (a.failures >= 8 ? 600 : 0)
        let left = Int((a.last.addingTimeInterval(wait)).timeIntervalSinceNow.rounded(.up))
        if left > 0 { throw VaultError.tooManyAttempts(retryAfter: left) }
    }

    private func recordFailure() {
        var a = keychain.data(for: "vault.attempts").flatMap { try? JSONDecoder().decode(Attempts.self, from: $0) } ?? Attempts(failures: 0, last: Date())
        a.failures += 1; a.last = Date()
        try? keychain.set(try JSONEncoder().encode(a), for: "vault.attempts")
    }

    // MARK: Device key & tokens (usable while locked)

    private var deviceKey: SymmetricKey {
        if let k = lock.withLock({ cachedDeviceKey }) { return k }
        let data = keychain.data(for: "device") ?? {
            let d = VaultCrypto.randomBytes(32)
            try? keychain.set(d, for: "device")
            return d
        }()
        let k = SymmetricKey(data: data)
        lock.withLock { cachedDeviceKey = k }
        return k
    }

    private func mac(_ s: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: deviceKey).map { String(format: "%02x", $0) }.joined()
    }
    public func pathToken(sourceID: Int64, relPath: String) -> String { mac("path|\(sourceID)|\(relPath)") }
    public func fingerprintToken(_ fp: String) -> String { mac("fp|\(fp)") }

    /// Keyed hashes of every private photo's path and fingerprint, so scans can skip them.
    public func privateTokens() -> Set<String> {
        let rows = (try? store.db.read { try $0.query("SELECT path_token, fp_token FROM private_items") { [$0.optText(0), $0.optText(1)] } }) ?? []
        return Set(rows.flatMap { $0.compactMap { $0 } })
    }

    // MARK: Private people (face templates for routing)

    /// Face templates of private people, decrypted with the device key, for matching new photos.
    public func privateReferences(embedderID: String) -> [Matcher.Reference] {
        let rows = (try? store.db.read { try $0.query("SELECT person_id, blob FROM private_refs WHERE embedder = ?", [embedderID]) { ($0.int(0), $0.blob(1)) } }) ?? []
        return rows.compactMap { pid, blob in
            guard let blob, let data = try? VaultCrypto.unwrap(blob, with: deviceKey) else { return nil }
            return Matcher.Reference(personID: pid, embedding: Vector.floats(data))
        }
    }

    public func privatePersonIDs() -> Set<Int64> {
        Set((try? store.db.read { try $0.query("SELECT id FROM people WHERE is_private = 1") { $0.int(0) } }) ?? [])
    }

    /// Match faces (including against private people) and move private people's matches into Private Space.
    public func matchAndRoute(embedderID: String, thresholds: MatchThresholds) throws {
        try store.runMatching(embedderID: embedderID, thresholds: thresholds, extraReferences: privateReferences(embedderID: embedderID))
        if isSetUp { try routeMatches() }
    }

    struct PersonSecrets: Codable { var name: String?; var contactID: String?; var handles: String? }

    /// Make a person private: keep their face templates for routing, hide their name, move their photos in.
    /// Works while locked (uses the public key).
    public func makePersonPrivate(_ personID: Int64) throws {
        let pk = try publicKey()
        let row = try store.db.read { try $0.query("SELECT name, contact_id, contact_handles FROM people WHERE id = ?", [personID]) {
            PersonSecrets(name: $0.optText(0), contactID: $0.optText(1), handles: $0.optText(2)) }.first }
        guard let row else { return }
        let refs = try store.db.read { try $0.query("""
            SELECT embedding, embedder FROM faces WHERE person_id = ? AND state >= 2 AND embedding IS NOT NULL
            ORDER BY state DESC, quality DESC LIMIT 80
            """, [personID]) { ($0.blob(0)!, $0.text(1)) } }
        let sealedName = try VaultCrypto.seal(try JSONEncoder().encode(row), to: pk)
        try store.db.write { c in
            for (emb, embedder) in refs {
                try c.run("INSERT INTO private_refs(person_id, embedder, blob) VALUES(?,?,?)", personID, embedder, try VaultCrypto.wrap(emb, with: deviceKey))
            }
            try c.run("UPDATE people SET is_private = 1, name = NULL, name_enc = ?, cover_face_id = NULL, contact_id = NULL, contact_handles = NULL WHERE id = ?",
                      sealedName, personID)
        }
        try routeMatches()
    }

    /// Move every photo with a confident match of a private person into Private Space; photos with only an
    /// uncertain match go in as "to review". Returns how many photos moved.
    @discardableResult
    public func routeMatches() throws -> Int {
        let privateIDs = privatePersonIDs()
        guard !privateIDs.isEmpty else { return 0 }
        let q = privateIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try store.db.read { try $0.query("SELECT photo_id, person_id, state FROM faces WHERE person_id IN (\(q)) AND state >= 1",
                                                     Array(privateIDs)) { ($0.int(0), $0.int(1), Int($0.int(2))) } }
        var byPhoto: [Int64: (certain: Set<Int64>, pending: Int64?)] = [:]
        for (photo, person, state) in rows {
            var e = byPhoto[photo] ?? ([], nil)
            if state >= FaceState.auto.rawValue { e.certain.insert(person) } else { e.pending = e.pending ?? person }
            byPhoto[photo] = e
        }
        for (photo, e) in byPhoto {
            try movePhotoIn(photo, individual: false, persons: Array(e.certain), pendingPerson: e.certain.isEmpty ? e.pending : nil)
        }
        if !byPhoto.isEmpty { checkpoint() }
        return byPhoto.count
    }

    // MARK: Moving photos in

    public struct FaceRecord: Codable, Sendable {
        var x, y, w, h, pixelSize: Double
        var quality: Double?
        var embedding: Data?
        var embedder: String?
        var personID: Int64?
        var state: Int
        var score: Double?
        var thumb: Data?
        var sharpness: Double?
        var eyeRatio: Double?
    }

    public struct Payload: Codable, Sendable {
        var version = 1
        var sourceID: Int64
        var relPath: String
        var filename: String
        var ext: String
        var siblings: String?
        var fileSize: Int64
        var mtime: Double
        var fingerprint: String?
        var width: Int?
        var height: Int?
        var takenAt: Double?
        var camera: String?
        var lens: String?
        var rating: Int?
        var embedder: String?
        var addedAt: Double
        var faces: [FaceRecord]
        var preview: Data?
        /// Marked private by hand.
        var individual: Bool
        /// Private people confidently in it.
        var persons: [Int64]
        /// An uncertain match of a private person waiting for review.
        var pendingPerson: Int64?
    }

    /// Mark photos private by hand. Works while locked.
    public func makePhotosPrivate(_ photoIDs: [Int64]) throws {
        for id in photoIDs { try movePhotoIn(id, individual: true, persons: [], pendingPerson: nil) }
        if !photoIDs.isEmpty { checkpoint() }
    }

    private func movePhotoIn(_ photoID: Int64, individual: Bool, persons: [Int64], pendingPerson: Int64?) throws {
        let pk = try publicKey()
        guard var payload = try store.db.read({ c in
            try c.query("""
            SELECT source_id, rel_path, filename, ext, siblings, file_size, mtime, fingerprint, width, height, taken_at, camera, lens, rating, embedder, added_at
            FROM photos WHERE id = ?
            """, [photoID]) { r in
                Payload(sourceID: r.int(0), relPath: r.text(1), filename: r.text(2), ext: r.text(3), siblings: r.optText(4), fileSize: r.int(5),
                        mtime: r.double(6), fingerprint: r.optText(7), width: r.optInt(8).map(Int.init), height: r.optInt(9).map(Int.init),
                        takenAt: r.optDouble(10), camera: r.optText(11), lens: r.optText(12), rating: r.optInt(13).map(Int.init),
                        embedder: r.optText(14), addedAt: r.double(15), faces: [], preview: nil, individual: individual,
                        persons: persons, pendingPerson: pendingPerson)
            }.first
        }) else { return }
        let faceRows = try store.db.read { c in
            try c.query("SELECT id, x, y, w, h, pixel_size, quality, embedding, embedder, person_id, state, score, thumb, sharpness, eye_ratio FROM faces WHERE photo_id = ?", [photoID]) { r in
                (r.int(0), FaceRecord(x: r.double(1), y: r.double(2), w: r.double(3), h: r.double(4), pixelSize: r.double(5), quality: r.optDouble(6),
                                      embedding: r.blob(7), embedder: r.optText(8), personID: r.optInt(9), state: Int(r.int(10)), score: r.optDouble(11),
                                      thumb: r.blob(12), sharpness: r.optDouble(13), eyeRatio: r.optDouble(14)))
            }
        }
        payload.faces = faceRows.map(\.1)
        let thumbURL = AppPaths.thumbnail(photoID: photoID)
        payload.preview = try? Data(contentsOf: thumbURL)

        let uuid = UUID().uuidString
        let sealed = try VaultCrypto.seal(try JSONEncoder().encode(payload), to: pk)
        try sealed.write(to: Self.itemsDirectory.appendingPathComponent(uuid + ".pxv"), options: .atomic)
        let pathToken = pathToken(sourceID: payload.sourceID, relPath: payload.relPath)
        let fpToken = payload.fingerprint.map(fingerprintToken)
        try store.db.write { c in
            try c.run("INSERT INTO private_items(uuid, path_token, fp_token, created_at) VALUES(?,?,?,?)", uuid, pathToken, fpToken, Date())
            try c.run("UPDATE people SET cover_face_id = NULL WHERE cover_face_id IN (SELECT id FROM faces WHERE photo_id = ?)", photoID)
            try c.run("DELETE FROM photos WHERE id = ?", photoID)   // faces go with it (ON DELETE CASCADE)
        }
        // Plaintext copies outside the library database.
        try? FileManager.default.removeItem(at: thumbURL)
        removeFaceCrops(faceRows.map(\.0))
    }

    private func removeFaceCrops(_ faceIDs: [Int64]) {
        let fm = FileManager.default
        let dir = AppPaths.faceCrops
        let ids = Set(faceIDs.map { "\($0)-" })
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where ids.contains(where: { name.hasPrefix($0) }) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Flush the write-ahead log so deleted plaintext pages don't linger in it.
    private func checkpoint() { try? store.db.read { try $0.exec("PRAGMA wal_checkpoint(TRUNCATE)") } }

    // MARK: Reading (unlocked)

    public struct Item: Identifiable, Sendable {
        public let id: String
        public let payload: Payload
        /// A stand-in id (negative, never in the library database) so the photo can use the normal views.
        public let photo: Photo
        public let faces: [Face]
        public var isPendingReview: Bool { payload.pendingPerson != nil }
        public var pendingPerson: Int64? { payload.pendingPerson }
        public var individual: Bool { payload.individual }
        public var persons: [Int64] { payload.persons }
        public var preview: Data? { payload.preview }
    }

    public struct Person: Identifiable, Sendable {
        public let id: Int64
        public let name: String
        public let contactID: String?
        public let handles: [String]
    }

    public struct Content: Sendable {
        public var items: [Item] = []
        public var people: [Person] = []
        public init() {}
    }

    /// Decrypt everything in Private Space. Requires it to be unlocked.
    public func loadContent() throws -> Content {
        let sk = try requireKey()
        var content = Content()
        let uuids = try store.db.read { try $0.query("SELECT uuid FROM private_items ORDER BY created_at DESC") { $0.text(0) } }
        var nextPhoto: Int64 = -1, nextFace: Int64 = -1_000_000
        for uuid in uuids {
            let url = Self.itemsDirectory.appendingPathComponent(uuid + ".pxv")
            guard let sealed = try? Data(contentsOf: url) else { continue }
            let payload = try JSONDecoder().decode(Payload.self, from: try VaultCrypto.open(sealed, with: sk))
            let pid = nextPhoto; nextPhoto -= 1
            let photo = Photo(id: pid, sourceID: payload.sourceID, relPath: payload.relPath, filename: payload.filename, ext: payload.ext,
                              siblings: payload.siblings?.components(separatedBy: "\n") ?? [], fileSize: payload.fileSize, fingerprint: payload.fingerprint,
                              width: payload.width, height: payload.height, takenAt: payload.takenAt.map(Date.init(timeIntervalSince1970:)),
                              camera: payload.camera, lens: payload.lens, rating: payload.rating, scanState: 1, scanError: nil)
            let faces = payload.faces.map { f -> Face in
                defer { nextFace -= 1 }
                return Face(id: nextFace, photoID: pid, rect: CGRect(x: f.x, y: f.y, width: f.w, height: f.h), pixelSize: f.pixelSize, quality: f.quality,
                            personID: f.personID, state: FaceState(rawValue: f.state) ?? .unassigned, score: f.score, hasEmbedding: f.embedding != nil, thumb: f.thumb)
            }
            content.items.append(Item(id: uuid, payload: payload, photo: photo, faces: faces))
        }
        let people = try store.db.read { try $0.query("SELECT id, name_enc FROM people WHERE is_private = 1") { ($0.int(0), $0.blob(1)) } }
        for (id, blob) in people {
            let secrets = blob.flatMap { try? JSONDecoder().decode(PersonSecrets.self, from: try VaultCrypto.open($0, with: sk)) }
            content.people.append(Person(id: id, name: secrets?.name ?? "Private person", contactID: secrets?.contactID,
                                         handles: secrets?.handles?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []))
        }
        return content
    }

    // MARK: Moving photos out (unlocked)

    /// Return photos to the regular library. Faces linked to people who are still private are unlinked and that
    /// link is remembered as rejected, so the photo isn't routed straight back in.
    public func moveToLibrary(_ itemIDs: [String]) throws {
        let privateIDs = privatePersonIDs()
        for id in itemIDs { try moveOut(id, keepLinksTo: [], privateIDs: privateIDs) }
        checkpoint()
    }

    private func readPayload(_ uuid: String) throws -> Payload {
        let sk = try requireKey()
        let sealed = try Data(contentsOf: Self.itemsDirectory.appendingPathComponent(uuid + ".pxv"))
        return try JSONDecoder().decode(Payload.self, from: try VaultCrypto.open(sealed, with: sk))
    }

    private func rewrite(_ uuid: String, _ payload: Payload) throws {
        let sealed = try VaultCrypto.seal(try JSONEncoder().encode(payload), to: try publicKey())
        try sealed.write(to: Self.itemsDirectory.appendingPathComponent(uuid + ".pxv"), options: .atomic)
    }

    private func moveOut(_ uuid: String, keepLinksTo keep: Set<Int64>, privateIDs: Set<Int64>) throws {
        let p = try readPayload(uuid)
        try store.db.write { c in
            if try c.scalar("SELECT COUNT(*) FROM photos WHERE source_id = ? AND rel_path = ?", [p.sourceID, p.relPath]) == 0 {
                let photoID = try c.run("""
                INSERT INTO photos(source_id, rel_path, filename, ext, siblings, file_size, mtime, fingerprint, width, height, taken_at, camera, lens,
                                   rating, scan_state, embedder, added_at, enriched)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,0)
                """, args: [p.sourceID, p.relPath, p.filename, p.ext, p.siblings, p.fileSize, p.mtime, p.fingerprint, p.width, p.height, p.takenAt,
                            p.camera, p.lens, p.rating, p.embedder, p.addedAt])
                for f in p.faces {
                    var person = f.personID, state = f.state
                    var rejected: Int64?
                    if let pid = person, privateIDs.contains(pid), !keep.contains(pid) { rejected = pid; person = nil; state = 0 }
                    let faceID = try c.run("""
                    INSERT INTO faces(photo_id, x, y, w, h, pixel_size, quality, embedding, embedder, person_id, state, score, thumb, created_at, sharpness, eye_ratio, enriched)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
                    """, args: [photoID, f.x, f.y, f.w, f.h, f.pixelSize, f.quality, f.embedding, f.embedder, person, state, f.score, f.thumb, Date(),
                                f.sharpness, f.eyeRatio])
                    if let rejected { try c.run("INSERT OR IGNORE INTO rejections(face_id, person_id) VALUES(?,?)", faceID, rejected) }
                }
                if AppSettings.keepPreviews, let preview = p.preview { try? preview.write(to: AppPaths.thumbnail(photoID: photoID), options: .atomic) }
            }
            try c.run("DELETE FROM private_items WHERE uuid = ?", uuid)
        }
        try? FileManager.default.removeItem(at: Self.itemsDirectory.appendingPathComponent(uuid + ".pxv"))
    }

    /// Review queue: yes, it's them — the photo stays private and the match is confirmed.
    public func confirmPending(_ uuid: String) throws {
        var p = try readPayload(uuid)
        guard let person = p.pendingPerson else { return }
        for i in p.faces.indices where p.faces[i].personID == person && p.faces[i].state == FaceState.suggested.rawValue { p.faces[i].state = FaceState.confirmed.rawValue }
        p.pendingPerson = nil
        if !p.persons.contains(person) { p.persons.append(person) }
        try rewrite(uuid, p)
    }

    /// Review queue: not them — the photo goes back to the library and won't be suggested for them again.
    public func rejectPending(_ uuid: String) throws {
        try moveOut(uuid, keepLinksTo: [], privateIDs: privatePersonIDs())
        checkpoint()
    }

    /// Make a private person public again: their name comes back, and photos that were private only because of
    /// them return to the library (keeping the link to them).
    public func makePersonPublic(_ personID: Int64) throws {
        let sk = try requireKey()
        let blob = try store.db.read { try $0.query("SELECT name_enc FROM people WHERE id = ?", [personID]) { $0.blob(0) }.first ?? nil }
        let secrets = blob.flatMap { try? JSONDecoder().decode(PersonSecrets.self, from: try VaultCrypto.open($0, with: sk)) }
        try store.db.write { c in
            try c.run("UPDATE people SET is_private = 0, name = ?, name_enc = NULL, contact_id = ?, contact_handles = ? WHERE id = ?",
                      secrets?.name, secrets?.contactID, secrets?.handles, personID)
            try c.run("DELETE FROM private_refs WHERE person_id = ?", personID)
        }
        let privateIDs = privatePersonIDs()
        let uuids = try store.db.read { try $0.query("SELECT uuid FROM private_items") { $0.text(0) } }
        for uuid in uuids {
            var p = try readPayload(uuid)
            guard p.persons.contains(personID) || p.pendingPerson == personID else { continue }
            p.persons.removeAll { $0 == personID }
            if p.pendingPerson == personID { p.pendingPerson = nil }
            if !p.individual && p.persons.isEmpty && p.pendingPerson == nil {
                try rewrite(uuid, p)
                try moveOut(uuid, keepLinksTo: [personID], privateIDs: privateIDs)
            } else {
                try rewrite(uuid, p)
            }
        }
        checkpoint()
    }

    // MARK: Erase

    /// Delete Private Space entirely: encrypted items, keys and private people's templates.
    /// Delete Private Space and everything Pixora keeps for it: the encrypted photo copies (previews, faces,
    /// details), private people with their encrypted names and face templates, the review queue, the keyed
    /// indexes that keep private photos out of the library, and the keys. Touches nothing else: no source file
    /// is read, moved, renamed or deleted, and ordinary library photos and people stay as they are.
    public func destroy() throws {
        lockNow()
        try? FileManager.default.removeItem(at: AppPaths.root.appendingPathComponent("Private", isDirectory: true))
        try store.db.write { c in
            try c.run("DELETE FROM private_items")
            try c.run("DELETE FROM private_refs")
            try c.run("UPDATE faces SET person_id = NULL, state = 0, score = NULL WHERE person_id IN (SELECT id FROM people WHERE is_private = 1)")
            try c.run("DELETE FROM people WHERE is_private = 1")
        }
        checkpoint()
        keychain.delete("vault"); keychain.delete("vault.attempts"); keychain.delete("device")
        lock.withLock { cachedDeviceKey = nil }
    }
}
