import Foundation

/// A before-image of the people side of the library, taken just before a correction, so it can be undone
/// exactly — including face templates that a "Forget" or "Ignore" deleted. Photos and sources are never part
/// of it (corrections don't touch them).
public struct UndoSnapshot: Sendable {
    struct FaceState: Sendable { let id: Int64; let personID: Int64?; let state: Int; let score: Double? }
    struct PersonRow: Sendable { let id: Int64; let name: String?; let cover: Int64?; let created: Double; let contactID: String?; let handles: String? }
    struct FullFace: Sendable { let values: [SendableValue] }
    let faces: [FaceState]
    let people: [PersonRow]
    let rejections: [(Int64, Int64)]
    /// Complete rows of faces the action may delete or strip (all columns).
    let saved: [FullFace]
    public let label: String
}

/// A column value that can be re-bound to SQLite.
public enum SendableValue: Sendable {
    case null, int(Int64), double(Double), text(String), blob(Data)
    var any: Any? {
        switch self { case .null: nil; case let .int(v): v; case let .double(v): v; case let .text(v): v; case let .blob(v): v }
    }
}

extension LibraryStore {
    static let faceAllColumns = ["id", "photo_id", "x", "y", "w", "h", "pixel_size", "quality", "embedding", "embedder", "person_id",
                                 "state", "score", "thumb", "created_at", "sharpness", "eye_ratio", "enriched"]

    /// Capture the current people state. `fragileFaceIDs` are faces the coming action may delete or modify
    /// beyond person/state (Forget, Ignore); their full rows are kept.
    public func captureUndo(_ label: String, fragileFaceIDs: [Int64] = []) throws -> UndoSnapshot {
        try db.read { c in
            let faces = try c.query("SELECT id, person_id, state, score FROM faces") {
                UndoSnapshot.FaceState(id: $0.int(0), personID: $0.optInt(1), state: Int($0.int(2)), score: $0.optDouble(3))
            }
            let people = try c.query("SELECT id, name, cover_face_id, created_at, contact_id, contact_handles FROM people") {
                UndoSnapshot.PersonRow(id: $0.int(0), name: $0.optText(1), cover: $0.optInt(2), created: $0.double(3), contactID: $0.optText(4), handles: $0.optText(5))
            }
            let rejections = try c.query("SELECT face_id, person_id FROM rejections") { ($0.int(0), $0.int(1)) }
            var saved: [UndoSnapshot.FullFace] = []
            let cols = Self.faceAllColumns.joined(separator: ", ")
            for chunk in stride(from: 0, to: fragileFaceIDs.count, by: 500).map({ Array(fragileFaceIDs[$0..<min($0 + 500, fragileFaceIDs.count)]) }) {
                let q = chunk.map { _ in "?" }.joined(separator: ",")
                saved += try c.query("SELECT \(cols) FROM faces WHERE id IN (\(q))", chunk) { r in
                    UndoSnapshot.FullFace(values: (0..<Int32(Self.faceAllColumns.count)).map { i -> SendableValue in
                        if r.isNull(i) { return .null }
                        switch Self.faceAllColumns[Int(i)] {
                        case "embedding", "thumb": return r.blob(i).map { .blob($0) } ?? .null
                        case "embedder": return .text(r.text(i))
                        case "x", "y", "w", "h", "pixel_size", "quality", "score", "created_at", "sharpness", "eye_ratio": return .double(r.double(i))
                        default: return .int(r.int(i))
                        }
                    })
                }
            }
            return UndoSnapshot(faces: faces, people: people, rejections: rejections, saved: saved, label: label)
        }
    }

    /// Put the people side back exactly as it was in `snapshot`. Only rows that differ are written.
    public func restore(_ snapshot: UndoSnapshot) throws {
        try db.write { c in
            // 1. People: re-create missing ones, update changed ones, remove ones that didn't exist.
            let current = Dictionary(uniqueKeysWithValues: try c.query("SELECT id, name, cover_face_id, contact_id, contact_handles FROM people") {
                ($0.int(0), ($0.optText(1), $0.optInt(2), $0.optText(3), $0.optText(4)))
            })
            let wanted = Set(snapshot.people.map(\.id))
            for p in snapshot.people {
                if let cur = current[p.id] {
                    if cur.0 != p.name || cur.1 != p.cover || cur.2 != p.contactID || cur.3 != p.handles {
                        try c.run("UPDATE people SET name = ?, cover_face_id = ?, contact_id = ?, contact_handles = ? WHERE id = ?", p.name, p.cover, p.contactID, p.handles, p.id)
                    }
                } else {
                    try c.run("INSERT INTO people(id, name, cover_face_id, created_at, contact_id, contact_handles) VALUES(?,?,?,?,?,?)",
                              p.id, p.name, p.cover, p.created, p.contactID, p.handles)
                }
            }
            for id in current.keys where !wanted.contains(id) { try c.run("DELETE FROM people WHERE id = ?", id) }

            // 2. Faces that were deleted or stripped: put full rows back.
            let cols = Self.faceAllColumns
            for f in snapshot.saved {
                let placeholders = cols.map { _ in "?" }.joined(separator: ",")
                try c.run("INSERT OR REPLACE INTO faces(\(cols.joined(separator: ","))) VALUES(\(placeholders))", args: f.values.map(\.any))
            }

            // 3. Faces that didn't exist at the snapshot (only possible when redoing a Forget) go again.
            let snapshotIDs = Set(snapshot.faces.map(\.id))
            if !snapshotIDs.isEmpty {
                for id in try c.query("SELECT id FROM faces", [], { $0.int(0) }) where !snapshotIDs.contains(id) {
                    try c.run("DELETE FROM faces WHERE id = ?", id)
                }
            }

            // 4. Face assignments that differ.
            let now = Dictionary(uniqueKeysWithValues: try c.query("SELECT id, person_id, state, score FROM faces") {
                ($0.int(0), ($0.optInt(1), Int($0.int(2)), $0.optDouble(3)))
            })
            for f in snapshot.faces {
                guard let cur = now[f.id] else { continue }
                if cur.0 != f.personID || cur.1 != f.state || cur.2 != f.score {
                    try c.run("UPDATE faces SET person_id = ?, state = ?, score = ? WHERE id = ?", f.personID, f.state, f.score, f.id)
                }
            }

            // 5. Rejections exactly as they were.
            try c.run("DELETE FROM rejections")
            for (face, person) in snapshot.rejections { try c.run("INSERT OR IGNORE INTO rejections(face_id, person_id) VALUES(?, ?)", face, person) }
        }
    }
}
