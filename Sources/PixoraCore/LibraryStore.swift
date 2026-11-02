import Foundation
import CoreGraphics

/// Filters shared by search results and the All Photos browser.
public struct PhotoFilter: Equatable, Sendable {
    public var text: String = ""          // filename contains
    public var from: Date?
    public var to: Date?
    public var camera: String?
    public var lens: String?
    public var fileType: String?          // lowercased extension, or "raw"
    public var minRating: Int?
    public var importID: Int64?
    public var sourceID: Int64?
    public init() {}

    public var isEmpty: Bool { self == PhotoFilter() }

    func sql(alias p: String = "ph") -> (String, [Any?]) {
        var clauses: [String] = []
        var args: [Any?] = []
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { clauses.append("\(p).filename LIKE ?"); args.append("%\(text)%") }
        if let from { clauses.append("\(p).taken_at >= ?"); args.append(from) }
        if let to { clauses.append("\(p).taken_at < ?"); args.append(to) }
        if let camera { clauses.append("\(p).camera = ?"); args.append(camera) }
        if let lens { clauses.append("\(p).lens = ?"); args.append(lens) }
        if let fileType {
            if fileType == "raw" {
                let list = FileTypes.rawExtensions.map { "'\($0)'" }.joined(separator: ",")
                clauses.append("(\(p).ext IN (\(list)) OR \(p).siblings IS NOT NULL)")
            } else if fileType == "jpg" {
                clauses.append("\(p).ext IN ('jpg','jpeg')")
            } else { clauses.append("\(p).ext = ?"); args.append(fileType) }
        }
        if let minRating { clauses.append("\(p).rating >= ?"); args.append(minRating) }
        if let importID { clauses.append("\(p).import_id = ?"); args.append(importID) }
        if let sourceID { clauses.append("\(p).source_id = ?"); args.append(sourceID) }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), args)
    }
}

public struct LibraryStats: Sendable {
    public var photos = 0
    public var scanned = 0
    public var failed = 0
    public var faces = 0
    public var recognizableFaces = 0
    public var people = 0
    public var namedPeople = 0
    public var reviewItems = 0
    public var facesFromOtherEmbedder = 0
    public var databaseBytes: Int64 = 0
    public var thumbnailBytes: Int64 = 0
    public init() {}
}

/// All reads and writes of the people library. Never touches the user's photo files.
public final class LibraryStore: @unchecked Sendable {
    public let db: Database

    public init(db: Database) { self.db = db }

    public static func openDefault() throws -> LibraryStore {
        LibraryStore(db: try Database(url: AppPaths.database))
    }

    // MARK: Sources

    private static let sourceColumns = "id, name, path, bookmark, volume_uuid, volume_name, is_removable, added_at, last_scan_at"
    private static func source(_ r: Row) -> Source {
        Source(id: r.int(0), name: r.text(1), path: r.text(2), bookmark: r.blob(3), volumeUUID: r.optText(4),
               volumeName: r.optText(5), isRemovable: r.int(6) != 0, addedAt: Date(timeIntervalSince1970: r.double(7)),
               lastScanAt: r.optDouble(8).map(Date.init(timeIntervalSince1970:)))
    }

    public func sources() throws -> [Source] {
        try db.read { try $0.query("SELECT \(Self.sourceColumns) FROM sources ORDER BY last_scan_at DESC, added_at DESC", [], Self.source) }
    }

    /// Register a folder or card. If it is the same card/folder as an existing source (same volume and
    /// relative path, or same path), that source is reused and re-pointed — no duplicate records.
    public func addSource(url: URL) throws -> Source {
        let info = VolumeInfo(for: url)
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try db.write { c in
            if let uuid = info.uuid, let rel = info.relativePath,
               let id = try c.query("SELECT id FROM sources WHERE volume_uuid = ? AND volume_rel = ?", [uuid, rel], { $0.int(0) }).first {
                try c.run("UPDATE sources SET path = ?, bookmark = ? WHERE id = ?", url.path, bookmark, id)
                return try c.query("SELECT \(Self.sourceColumns) FROM sources WHERE id = ?", [id], Self.source)[0]
            }
            if let id = try c.query("SELECT id FROM sources WHERE path = ?", [url.path], { $0.int(0) }).first {
                return try c.query("SELECT \(Self.sourceColumns) FROM sources WHERE id = ?", [id], Self.source)[0]
            }
            let name = info.isRemovable && info.relativePath == "" ? (info.name ?? url.lastPathComponent) : url.lastPathComponent
            let id = try c.run("""
                INSERT INTO sources(name, path, bookmark, volume_uuid, volume_name, volume_rel, is_removable, added_at)
                VALUES(?,?,?,?,?,?,?,?)
                """, name, url.path, bookmark, info.uuid, info.name, info.relativePath, info.isRemovable, Date())
            return try c.query("SELECT \(Self.sourceColumns) FROM sources WHERE id = ?", [id], Self.source)[0]
        }
    }

    /// For offline sources, try to find where they are now: the bookmark, or a mounted volume with the same UUID.
    public func reconnectSources() throws -> [Source] {
        let all = try sources()
        let volumes = VolumeInfo.mountedVolumes()
        for s in all where !s.isOnline {
            var found: URL?
            if let bm = s.bookmark {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: u.path) { found = u }
            }
            if found == nil, let uuid = s.volumeUUID,
               let rel = try db.read({ try $0.query("SELECT volume_rel FROM sources WHERE id = ?", [s.id]) { $0.optText(0) }.first ?? nil }),
               let vol = volumes.first(where: { $0.uuid == uuid }) {
                let u = rel.isEmpty ? vol.url : vol.url.appendingPathComponent(rel, isDirectory: true)
                if FileManager.default.fileExists(atPath: u.path) { found = u }
            }
            if let found { try relocate(sourceID: s.id, to: found) }
        }
        return try sources()
    }

    /// How many of a source's known photos exist (same relative path and size) under a candidate folder.
    public func verifyRelocation(sourceID: Int64, to url: URL, sample: Int = 25) throws -> (checked: Int, matched: Int) {
        let rows = try db.read { try $0.query("SELECT rel_path, file_size FROM photos WHERE source_id = ? ORDER BY RANDOM() LIMIT ?", [sourceID, sample]) { ($0.text(0), $0.int(1)) } }
        let fm = FileManager.default
        let matched = rows.filter { rel, size in
            let attrs = try? fm.attributesOfItem(atPath: url.appendingPathComponent(rel).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == size
        }.count
        return (rows.count, matched)
    }

    public func relocate(sourceID: Int64, to url: URL) throws {
        let info = VolumeInfo(for: url)
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try db.write { try $0.run("UPDATE sources SET path = ?, bookmark = ?, volume_uuid = COALESCE(?, volume_uuid), volume_rel = COALESCE(?, volume_rel) WHERE id = ?",
                                  url.path, bookmark, info.uuid, info.relativePath, sourceID) }
    }

    /// Removes a source and everything Pixora learned from it. The photo files themselves are untouched.
    public func removeSource(_ id: Int64) throws {
        let photoIDs = try db.read { try $0.query("SELECT id FROM photos WHERE source_id = ?", [id]) { $0.int(0) } }
        try db.write { c in
            try c.run("DELETE FROM sources WHERE id = ?", id)
            try c.run("DELETE FROM people WHERE name IS NULL AND is_private = 0 AND id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
        }
        for pid in photoIDs { try? FileManager.default.removeItem(at: AppPaths.thumbnail(photoID: pid)) }
    }

    // MARK: Imports

    public func startImport(sourceID: Int64, total: Int) throws -> Int64 {
        try db.write { try $0.run("INSERT INTO imports(source_id, started_at, status, files_total) VALUES(?,?,?,?)", sourceID, Date(), "running", total) }
    }

    public func finishImport(_ id: Int64, status: String, new: Int, skipped: Int, faces: Int, errors: Int) throws {
        try db.write { c in
            try c.run("UPDATE imports SET finished_at=?, status=?, files_new=?, files_skipped=?, faces_found=?, errors=? WHERE id=?",
                      Date(), status, new, skipped, faces, errors, id)
            try c.run("UPDATE sources SET last_scan_at = ? WHERE id = (SELECT source_id FROM imports WHERE id = ?)", Date(), id)
        }
    }

    public func imports(limit: Int = 50) throws -> [ImportRecord] {
        try db.read {
            try $0.query("""
            SELECT i.id, i.source_id, s.name, i.started_at, i.finished_at, i.status, i.files_total, i.files_new,
                   i.files_skipped, i.faces_found, i.errors
            FROM imports i JOIN sources s ON s.id = i.source_id ORDER BY i.started_at DESC LIMIT ?
            """, [limit]) { r in
                ImportRecord(id: r.int(0), sourceID: r.int(1), sourceName: r.text(2), startedAt: Date(timeIntervalSince1970: r.double(3)),
                             finishedAt: r.optDouble(4).map(Date.init(timeIntervalSince1970:)), status: r.text(5),
                             filesTotal: Int(r.int(6)), filesNew: Int(r.int(7)), filesSkipped: Int(r.int(8)),
                             facesFound: Int(r.int(9)), errors: Int(r.int(10)))
            }
        }
    }

    // MARK: Photos

    public struct ExistingPhoto { public let id: Int64; public let size: Int64; public let mtime: Double; public let scanState: Int; public let embedder: String? }

    public func existingPhotos(sourceID: Int64) throws -> [String: ExistingPhoto] {
        let rows = try db.read {
            try $0.query("SELECT rel_path, id, file_size, mtime, scan_state, embedder FROM photos WHERE source_id = ?", [sourceID]) {
                ($0.text(0), ExistingPhoto(id: $0.int(1), size: $0.int(2), mtime: $0.double(3), scanState: Int($0.int(4)), embedder: $0.optText(5)))
            }
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    /// Insert or refresh a photo row and replace its faces with a fresh analysis, in one transaction.
    public func recordScan(sourceID: Int64, importID: Int64, file: ScanFile, metadata: PhotoMetadata, fingerprint: String?,
                           faces: [DetectedFace], embedderID: String, error: String?) throws -> Int64 {
        try db.write { c in
            let siblings = file.siblings.isEmpty ? nil : file.siblings.joined(separator: "\n")
            let state = error == nil ? 1 : 2
            let existing = try c.query("SELECT id FROM photos WHERE source_id = ? AND rel_path = ?", [sourceID, file.relPath]) { $0.int(0) }.first
            let photoID: Int64
            if let existing {
                photoID = existing
                try c.run("""
                UPDATE photos SET siblings=?, file_size=?, mtime=?, fingerprint=?, width=?, height=?, taken_at=?, camera=?, lens=?,
                rating=?, scan_state=?, scan_error=?, embedder=?, import_id=? WHERE id=?
                """, args: [siblings, file.size, file.mtime, fingerprint, metadata.width, metadata.height, metadata.takenAt,
                            metadata.camera, metadata.lens, metadata.rating, state, error, embeddedID(embedderID, error), importID, photoID])
                try c.run("DELETE FROM faces WHERE photo_id = ?", photoID)
            } else {
                photoID = try c.run("""
                INSERT INTO photos(source_id, rel_path, filename, ext, siblings, file_size, mtime, fingerprint, width, height,
                taken_at, camera, lens, rating, scan_state, scan_error, embedder, import_id, added_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, args: [sourceID, file.relPath, file.filename, file.ext, siblings, file.size, file.mtime, fingerprint,
                            metadata.width, metadata.height, metadata.takenAt, metadata.camera, metadata.lens, metadata.rating,
                            state, error, embeddedID(embedderID, error), importID, Date()])
            }
            let now = Date()
            for f in faces {
                try c.run("""
                INSERT INTO faces(photo_id, x, y, w, h, pixel_size, quality, embedding, embedder, state, thumb, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,0,?,?)
                """, args: [photoID, Double(f.rect.minX), Double(f.rect.minY), Double(f.rect.width), Double(f.rect.height),
                            f.pixelSize, f.quality, f.embedding.map(Vector.data), f.embedding == nil ? nil : embedderID, f.thumbJPEG, now])
            }
            return photoID
        }
    }

    private func embeddedID(_ id: String, _ error: String?) -> String? { error == nil ? id : nil }

    public func markSkipped(photoID: Int64, importID: Int64) throws {
        try db.write { try $0.run("UPDATE photos SET import_id = COALESCE(import_id, ?) WHERE id = ?", importID, photoID) }
    }

    static let photoColumns = "ph.id, ph.source_id, ph.rel_path, ph.filename, ph.ext, ph.siblings, ph.file_size, ph.fingerprint, ph.width, ph.height, ph.taken_at, ph.camera, ph.lens, ph.rating, ph.scan_state, ph.scan_error"
    static func photo(_ r: Row) -> Photo {
        Photo(id: r.int(0), sourceID: r.int(1), relPath: r.text(2), filename: r.text(3), ext: r.text(4),
              siblings: r.optText(5)?.components(separatedBy: "\n") ?? [], fileSize: r.int(6), fingerprint: r.optText(7),
              width: r.optInt(8).map(Int.init), height: r.optInt(9).map(Int.init),
              takenAt: r.optDouble(10).map(Date.init(timeIntervalSince1970:)), camera: r.optText(11), lens: r.optText(12),
              rating: r.optInt(13).map(Int.init), scanState: Int(r.int(14)), scanError: r.optText(15))
    }

    public func photos(filter: PhotoFilter = PhotoFilter(), limit: Int = 20000) throws -> [Photo] {
        let (w, args) = filter.sql()
        return try db.read {
            try $0.query("SELECT \(Self.photoColumns) FROM photos ph WHERE \(w) AND ph.scan_state = 1 ORDER BY ph.taken_at IS NULL, ph.taken_at DESC, ph.filename LIMIT ?",
                         args + [limit], Self.photo)
        }
    }

    public func photos(ids: [Int64]) throws -> [Photo] {
        guard !ids.isEmpty else { return [] }
        return try db.read { c in
            var out: [Photo] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let q = chunk.map { _ in "?" }.joined(separator: ",")
                out += try c.query("SELECT \(Self.photoColumns) FROM photos ph WHERE ph.id IN (\(q))", chunk, Self.photo)
            }
            return out
        }
    }

    public func failedPhotos() throws -> [Photo] {
        try db.read { try $0.query("SELECT \(Self.photoColumns) FROM photos ph WHERE ph.scan_state = 2 ORDER BY ph.filename", [], Self.photo) }
    }

    public func distinctValues(_ column: String) throws -> [String] {
        precondition(["camera", "lens"].contains(column))
        return try db.read { try $0.query("SELECT DISTINCT \(column) FROM photos WHERE \(column) IS NOT NULL ORDER BY \(column)") { $0.text(0) } }
    }

    // MARK: People

    public func people() throws -> [Person] {
        try db.read {
            try $0.query("""
            SELECT p.id, p.name,
                   COALESCE(p.cover_face_id, (SELECT f2.id FROM faces f2 WHERE f2.person_id = p.id AND f2.state >= 2 ORDER BY f2.state DESC, f2.quality DESC LIMIT 1)),
                   COUNT(DISTINCT CASE WHEN f.state >= 2 THEN f.photo_id END),
                   SUM(CASE WHEN f.state >= 2 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN f.state = 1 THEN 1 ELSE 0 END),
                   MAX(CASE WHEN f.state >= 2 THEN ph.taken_at END),
                   p.contact_id, p.contact_handles
            FROM people p LEFT JOIN faces f ON f.person_id = p.id LEFT JOIN photos ph ON ph.id = f.photo_id
            WHERE p.is_private = 0
            GROUP BY p.id ORDER BY p.name IS NULL, p.name COLLATE NOCASE, 4 DESC
            """) { r in
                Person(id: r.int(0), name: r.optText(1), coverFaceID: r.optInt(2), photoCount: Int(r.int(3)),
                       faceCount: Int(r.int(4)), uncertainCount: Int(r.int(5)), lastSeen: r.optDouble(6).map(Date.init(timeIntervalSince1970:)),
                       contactID: r.optText(7), contactHandles: r.optText(8)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? [])
            }
        }
    }

    static let faceColumns = "id, photo_id, x, y, w, h, pixel_size, quality, person_id, state, score, embedding IS NOT NULL, thumb"
    static func face(_ r: Row) -> Face {
        Face(id: r.int(0), photoID: r.int(1), rect: CGRect(x: r.double(2), y: r.double(3), width: r.double(4), height: r.double(5)),
             pixelSize: r.double(6), quality: r.optDouble(7), personID: r.optInt(8), state: FaceState(rawValue: Int(r.int(9))) ?? .unassigned,
             score: r.optDouble(10), hasEmbedding: r.int(11) != 0, thumb: r.blob(12))
    }

    public func faces(personID: Int64, minState: FaceState = .auto) throws -> [Face] {
        try db.read { try $0.query("SELECT \(Self.faceColumns) FROM faces WHERE person_id = ? AND state >= ? ORDER BY state DESC, quality DESC", [personID, minState.rawValue], Self.face) }
    }

    public func faces(photoID: Int64) throws -> [Face] {
        try db.read { try $0.query("SELECT \(Self.faceColumns) FROM faces WHERE photo_id = ? ORDER BY x", [photoID], Self.face) }
    }

    public func face(id: Int64) throws -> Face? {
        try db.read { try $0.query("SELECT \(Self.faceColumns) FROM faces WHERE id = ?", [id], Self.face).first }
    }

    public func faceThumb(id: Int64) throws -> Data? {
        try db.read { try $0.query("SELECT thumb FROM faces WHERE id = ?", [id]) { $0.blob(0) }.first ?? nil }
    }

    /// Borderline matches waiting for a yes/no, best first.
    public func uncertainFaces(limit: Int = 500) throws -> [Face] {
        try db.read { try $0.query("SELECT \(Self.faceColumns) FROM faces WHERE state = 1 ORDER BY score DESC LIMIT ?", [limit], Self.face) }
    }

    /// Recognisable faces that matched nobody and grouped with nothing.
    public func unsortedFaces(limit: Int = 500) throws -> [Face] {
        try db.read { try $0.query("SELECT \(Self.faceColumns) FROM faces WHERE state = 0 AND person_id IS NULL AND embedding IS NOT NULL ORDER BY quality DESC LIMIT ?", [limit], Self.face) }
    }

    public func unrecognizableFaceCount() throws -> Int {
        Int(try db.read { try $0.scalar("SELECT COUNT(*) FROM faces WHERE embedding IS NULL") })
    }

    public func createPerson(name: String?) throws -> Int64 {
        try db.write { try $0.run("INSERT INTO people(name, created_at) VALUES(?, ?)", name.flatMap(Self.cleanName), Date()) }
    }

    static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public func person(named name: String) throws -> Int64? {
        try db.read { try $0.query("SELECT id FROM people WHERE name = ? COLLATE NOCASE", [name]) { $0.int(0) }.first }
    }

    /// Name a group. Naming confirms every certain face in it. If another person already has this name,
    /// the group is merged into them (the caller asks the user first).
    @discardableResult
    public func name(personID: Int64, as rawName: String) throws -> Int64 {
        guard let name = Self.cleanName(rawName) else {
            try db.write { try $0.run("UPDATE people SET name = NULL WHERE id = ?", personID) }
            return personID
        }
        if let other = try person(named: name), other != personID {
            try merge(personID, into: other)
            try db.write { try $0.run("UPDATE faces SET state = 3 WHERE person_id = ? AND state = 2", other) }
            return other
        }
        try db.write { c in
            try c.run("UPDATE people SET name = ? WHERE id = ?", name, personID)
            try c.run("UPDATE faces SET state = 3 WHERE person_id = ? AND state = 2", personID)
        }
        return personID
    }

    public func merge(_ source: Int64, into target: Int64) throws {
        guard source != target else { return }
        try db.write { c in
            try c.run("UPDATE OR IGNORE rejections SET person_id = ? WHERE person_id = ?", target, source)
            try c.run("UPDATE faces SET person_id = ? WHERE person_id = ?", target, source)
            try c.run("DELETE FROM people WHERE id = ?", source)
        }
    }

    /// Delete a person and every face template linked to them. Photos stay in the library.
    public func forget(personID: Int64) throws {
        try db.write { c in
            try c.run("DELETE FROM faces WHERE person_id = ?", personID)
            try c.run("DELETE FROM people WHERE id = ?", personID)
        }
    }

    public func setCover(personID: Int64, faceID: Int64) throws {
        try db.write { try $0.run("UPDATE people SET cover_face_id = ? WHERE id = ?", faceID, personID) }
    }

    // MARK: Corrections

    public func confirm(faceIDs: [Int64]) throws {
        try db.write { c in for id in faceIDs { try c.run("UPDATE faces SET state = 3 WHERE id = ? AND person_id IS NOT NULL", id) } }
    }

    /// "Not this person": unlink the face and remember never to suggest that person for it again.
    public func reject(faceIDs: [Int64]) throws {
        try db.write { c in
            for id in faceIDs {
                try c.run("INSERT OR IGNORE INTO rejections(face_id, person_id) SELECT id, person_id FROM faces WHERE id = ? AND person_id IS NOT NULL", id)
                try c.run("UPDATE faces SET person_id = NULL, state = 0, score = NULL WHERE id = ?", id)
                try c.run("UPDATE people SET cover_face_id = NULL WHERE cover_face_id = ?", id)
            }
            try c.run("DELETE FROM people WHERE name IS NULL AND is_private = 0 AND id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
        }
    }

    public func assign(faceIDs: [Int64], to personID: Int64) throws {
        try db.write { c in
            for id in faceIDs {
                try c.run("DELETE FROM rejections WHERE face_id = ? AND person_id = ?", id, personID)
                try c.run("UPDATE faces SET person_id = ?, state = 3, score = NULL WHERE id = ?", personID, id)
            }
            try c.run("DELETE FROM people WHERE name IS NULL AND is_private = 0 AND id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
        }
    }

    /// Split: move faces out of a group into a brand-new person.
    @discardableResult
    public func moveToNewPerson(faceIDs: [Int64], name: String?) throws -> Int64 {
        let id = try createPerson(name: name)
        try assign(faceIDs: faceIDs, to: id)
        return id
    }

    /// Mark faces as "not a person I care about" (strangers in the background): removes them from review.
    public func ignore(faceIDs: [Int64]) throws {
        try db.write { c in for id in faceIDs { try c.run("UPDATE faces SET embedding = NULL, state = 0, person_id = NULL WHERE id = ?", id) } }
    }

    // MARK: Matching

    /// Match every face that is not yet certain against known people, then group what is left.
    /// Only faces produced by `embedderID` take part.
    /// `extraReferences`: face templates of private people (from PrivateVault), so their new matches are found.
    public func runMatching(embedderID: String, thresholds: MatchThresholds, extraReferences: [Matcher.Reference] = []) throws {
        // A person you've confirmed is matched only against the faces you confirmed, so a wrong automatic
        // match can't become a reference and snowball. Unnamed groups use their automatic faces.
        let refRows = try db.read {
            try $0.query("""
            SELECT person_id, embedding FROM (
              SELECT person_id, embedding, ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY state DESC, quality DESC) AS rn
              FROM faces WHERE person_id IS NOT NULL AND embedding IS NOT NULL AND embedder = ?
                AND (state = 3 OR (state = 2 AND person_id NOT IN (SELECT person_id FROM faces WHERE state = 3 AND person_id IS NOT NULL))))
            WHERE rn <= 80
            """, [embedderID]) { Matcher.Reference(personID: $0.int(0), embedding: Vector.floats($0.blob(1)!)) }
        }
        let refRowsAll = refRows + extraReferences
        let rejections = try db.read { try $0.query("SELECT face_id, person_id FROM rejections") { ($0.int(0), $0.int(1)) } }
        let rejectedBy = Dictionary(grouping: rejections, by: \.0).mapValues { Set($0.map(\.1)) }
        let candidates = try db.read {
            try $0.query("SELECT id, photo_id, embedding, quality FROM faces WHERE state <= 1 AND embedding IS NOT NULL AND embedder = ?", [embedderID]) {
                Matcher.Candidate(id: $0.int(0), photoID: $0.int(1), embedding: Vector.floats($0.blob(2)!), rejected: rejectedBy[$0.int(0)] ?? [], quality: $0.optDouble(3))
            }
        }
        guard !candidates.isEmpty else { return }
        let matcher = Matcher(thresholds: thresholds)
        let assignments = matcher.assign(candidates, references: refRowsAll)
        try db.write { c in
            for a in assignments {
                try c.run("UPDATE faces SET person_id = ?, state = ?, score = ? WHERE id = ?", a.personID, a.state.rawValue, a.score.map { Double($0) }, a.faceID)
            }
        }
        let leftover = Set(assignments.filter { $0.personID == nil }.map(\.faceID))
        let groups = matcher.cluster(candidates.filter { leftover.contains($0.id) })
        try db.write { c in
            for g in groups {
                let pid = try c.run("INSERT INTO people(name, created_at) VALUES(NULL, ?)", Date())
                for fid in g { try c.run("UPDATE faces SET person_id = ?, state = 2, score = NULL WHERE id = ?", pid, fid) }
            }
            try c.run("DELETE FROM people WHERE name IS NULL AND is_private = 0 AND id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
        }
    }

    // MARK: Search

    /// Photos containing all, any, or only the given people. Certain matches only, unless `includeUncertain`.
    /// The same photo imported from two places (same fingerprint) is returned once. Each result carries shot
    /// quality signals (eyes closed, soft focus, burst) so the UI can mark weaker frames instead of hiding them.
    public func search(people ids: [Int64], mode: MatchMode, includeUncertain: Bool, filter: PhotoFilter = PhotoFilter()) throws -> [SearchResult] {
        guard !ids.isEmpty else { return [] }
        let q = ids.map { _ in "?" }.joined(separator: ",")
        let minState = includeUncertain ? FaceState.suggested : .auto
        struct Hit { let match: PersonMatch; let quality: Double; let sharpness: Double?; let eyeRatio: Double?; let pixelSize: Double }
        let rows = try db.read {
            try $0.query("SELECT photo_id, person_id, id, state, score, quality, sharpness, eye_ratio, pixel_size FROM faces WHERE person_id IN (\(q)) AND state >= ?", ids + [minState.rawValue]) {
                ($0.int(0), Hit(match: PersonMatch(personID: $0.int(1), faceID: $0.int(2), state: FaceState(rawValue: Int($0.int(3))) ?? .unassigned, score: $0.optDouble(4)),
                                quality: $0.optDouble(5) ?? 0.7, sharpness: $0.optDouble(6), eyeRatio: $0.optDouble(7), pixelSize: $0.double(8)))
            }
        }
        var byPhoto: [Int64: [Int64: Hit]] = [:]
        for (photo, h) in rows {
            if let cur = byPhoto[photo]?[h.match.personID], cur.match.state >= h.match.state { continue }
            byPhoto[photo, default: [:]][h.match.personID] = h
        }
        let wanted = Set(ids)
        var matching = byPhoto.filter { mode == .any ? true : wanted.isSubset(of: Set($0.value.keys)) }

        if mode == .only, !matching.isEmpty {
            // Drop photos where anyone else (named, unknown, or too-small-to-recognise) appears at a similar size.
            let pids = Array(matching.keys)
            var others: [Int64: [(person: Int64?, size: Double)]] = [:]
            try db.read { c in
                for chunk in stride(from: 0, to: pids.count, by: 500).map({ Array(pids[$0..<min($0 + 500, pids.count)]) }) {
                    let pq = chunk.map { _ in "?" }.joined(separator: ",")
                    for (photo, person, size) in try c.query("SELECT photo_id, person_id, pixel_size FROM faces WHERE photo_id IN (\(pq))", chunk, { ($0.int(0), $0.optInt(1), $0.double(2)) }) {
                        others[photo, default: []].append((person, size))
                    }
                }
            }
            matching = matching.filter { photo, hits in
                let minSelected = hits.values.map(\.pixelSize).min() ?? 0
                return !(others[photo] ?? []).contains { f in
                    !(f.person.map(wanted.contains) ?? false) && f.size >= 0.4 * minSelected
                }
            }
        }

        // Typical sharpness per person, so "soft" means soft for them (not just a small face).
        var medianSharp: [Int64: Double] = [:]
        for pid in ids {
            let v = rows.compactMap { $0.1.match.personID == pid ? $0.1.sharpness : nil }.sorted()
            if !v.isEmpty { medianSharp[pid] = v[v.count / 2] }
        }

        let (w, args) = filter.sql()
        let photoIDs = Array(matching.keys)
        var photos: [(Photo, Int64?)] = []
        try db.read { c in
            for chunk in stride(from: 0, to: photoIDs.count, by: 500).map({ Array(photoIDs[$0..<min($0 + 500, photoIDs.count)]) }) {
                let pq = chunk.map { _ in "?" }.joined(separator: ",")
                photos += try c.query("SELECT \(Self.photoColumns), ph.burst_id FROM photos ph WHERE ph.id IN (\(pq)) AND \(w)", chunk + args) { (Self.photo($0), $0.optInt(16)) }
            }
        }
        var seen = Set<String>()
        var results: [SearchResult] = []
        for (p, burst) in photos.sorted(by: { Self.chronological($0.0, $1.0) }) {
            if let fp = p.fingerprint { if seen.contains(fp) { continue }; seen.insert(fp) }
            let hits = ids.compactMap { matching[p.id]?[$0] }
            var score = 1.0, closed = false, soft = false
            for h in hits {
                let sharpNorm = h.sharpness.flatMap { s in medianSharp[h.match.personID].map { min(1.2, s / max($0, 1e-6)) } } ?? 0.8
                let eyesShut = h.eyeRatio.map { $0 < Enrichment.eyesClosedRatio } ?? false
                closed = closed || eyesShut
                soft = soft || sharpNorm < Enrichment.softFraction
                score *= max(0.05, h.quality) * min(1, sharpNorm) * (eyesShut ? 0.3 : 1) * min(1, h.pixelSize / 300 + 0.4)
            }
            results.append(SearchResult(photo: p, matches: hits.map(\.match), score: pow(score, 1 / Double(max(hits.count, 1))),
                                        eyesClosed: closed, soft: soft, burstID: burst))
        }
        return results
    }

    static func chronological(_ a: Photo, _ b: Photo) -> Bool {
        switch (a.takenAt, b.takenAt) {
        case let (x?, y?): return x == y ? a.filename < b.filename : x > y
        case (nil, nil): return a.filename < b.filename
        case (_?, nil): return true
        case (nil, _?): return false
        }
    }

    // MARK: Privacy & housekeeping

    public func stats(currentEmbedder: String) throws -> LibraryStats {
        var s = LibraryStats()
        try db.read { c in
            s.photos = Int(try c.scalar("SELECT COUNT(*) FROM photos"))
            s.scanned = Int(try c.scalar("SELECT COUNT(*) FROM photos WHERE scan_state = 1"))
            s.failed = Int(try c.scalar("SELECT COUNT(*) FROM photos WHERE scan_state = 2"))
            s.faces = Int(try c.scalar("SELECT COUNT(*) FROM faces"))
            s.recognizableFaces = Int(try c.scalar("SELECT COUNT(*) FROM faces WHERE embedding IS NOT NULL"))
            s.people = Int(try c.scalar("SELECT COUNT(*) FROM people WHERE is_private = 0"))
            s.namedPeople = Int(try c.scalar("SELECT COUNT(*) FROM people WHERE name IS NOT NULL AND is_private = 0"))
            s.reviewItems = Int(try c.scalar("SELECT COUNT(*) FROM faces WHERE state = 1"))
                + Int(try c.scalar("SELECT COUNT(*) FROM people WHERE name IS NULL AND is_private = 0"))
            s.facesFromOtherEmbedder = Int(try c.scalar("SELECT COUNT(*) FROM faces WHERE embedding IS NOT NULL AND embedder != ?", [currentEmbedder]))
        }
        let fm = FileManager.default
        for suffix in ["", "-wal"] {
            s.databaseBytes += ((try? fm.attributesOfItem(atPath: db.url.path + suffix))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        if let e = fm.enumerator(at: AppPaths.thumbnails, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { s.thumbnailBytes += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return s
    }

    /// Delete every face template, face thumbnail, person and correction. Photos stay indexed and are
    /// marked for re-scan so faces can be found again if the user wants.
    public func clearFaceData() throws {
        try db.write { c in
            try c.run("DELETE FROM rejections")
            try c.run("DELETE FROM faces")
            try c.run("DELETE FROM people")
            try c.run("UPDATE photos SET scan_state = 0, embedder = NULL")
        }
        try db.read { try $0.exec("VACUUM") }
    }

    /// Delete everything Pixora stores: library, people, faces, sources, import history and thumbnails.
    public func eraseAll() throws {
        try db.write { c in
            for t in ["rejections", "faces", "private_refs", "private_items", "people", "photos", "imports", "sources"] { try c.run("DELETE FROM \(t)") }
        }
        try db.read { try $0.exec("VACUUM") }
        try? FileManager.default.removeItem(at: AppPaths.thumbnails)
    }
}
