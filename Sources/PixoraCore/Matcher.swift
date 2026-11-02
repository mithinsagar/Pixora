import Foundation

/// Threshold values per embedder. These are measured, not guessed: see README "Accuracy" and
/// `pixora-eval`. Re-run the harness if you change the model or the alignment code.
public enum Calibration {
    public static var faceNet = MatchThresholds(certain: 0.66, suggest: 0.50, group: 0.72)
    public static var arcFace = MatchThresholds(certain: 0.45, suggest: 0.25, group: 0.47)
    /// Basic mode is not usable for identity (LFW: 81% best balanced verification accuracy, ~60% of its
    /// suggestions name the wrong person). These values keep it from ever claiming certainty.
    public static var visionFeaturePrint = MatchThresholds(certain: 0.93, suggest: 0.82, group: 0.92)
    /// A user-installed model we have not calibrated: conservative, everything goes through review.
    public static var unknownModel = MatchThresholds(certain: 0.75, suggest: 0.5, group: 0.75)
}

/// Assigns faces to people and groups the rest. Pure in-memory algorithm, so it can be tested and evaluated.
public struct Matcher {
    public struct Candidate {
        public let id: Int64
        public let photoID: Int64
        public let embedding: [Float]
        public let rejected: Set<Int64>
        /// 0…1 (see DetectedFace.quality). nil = unknown, treated as good.
        public let quality: Double?
        public init(id: Int64, photoID: Int64, embedding: [Float], rejected: Set<Int64> = [], quality: Double? = nil) {
            self.id = id; self.photoID = photoID; self.embedding = embedding; self.rejected = rejected; self.quality = quality
        }
        var isGoodQuality: Bool { (quality ?? 1) >= Matcher.minAutoQuality }
    }

    public struct Reference {
        public let personID: Int64
        public let embedding: [Float]
        public init(personID: Int64, embedding: [Float]) { self.personID = personID; self.embedding = embedding }
    }

    public struct Assignment: Equatable {
        public let faceID: Int64
        public let personID: Int64?
        public let state: FaceState
        public let score: Float?
    }

    public let thresholds: MatchThresholds
    /// How far ahead the best person must be of the runner-up to be called certain.
    public var margin: Float = 0.06
    /// Faces below this quality (side-on, blurry, tiny, low confidence) are never matched or grouped
    /// automatically; at best they are suggested for review.
    public static let minAutoQuality = 0.35

    public init(thresholds: MatchThresholds) { self.thresholds = thresholds }

    /// Compare each candidate with every person's reference faces (score = mean of the best 3 similarities).
    public func assign(_ candidates: [Candidate], references: [Reference]) -> [Assignment] {
        guard let dim = candidates.first?.embedding.count else { return [] }
        let people = Array(Set(references.map(\.personID))).sorted()
        guard !people.isEmpty else {
            return candidates.map { Assignment(faceID: $0.id, personID: nil, state: .unassigned, score: nil) }
        }
        let refs = references.filter { $0.embedding.count == dim }
        let refMatrix = refs.flatMap(\.embedding)
        var results: [Assignment] = []
        let batch = 512
        for start in stride(from: 0, to: candidates.count, by: batch) {
            let chunk = Array(candidates[start..<min(start + batch, candidates.count)])
            let sims = Vector.similarity(chunk.flatMap(\.embedding), rows: chunk.count, refMatrix, rows: refs.count, dim: dim)
            for (row, cand) in chunk.enumerated() {
                var perPerson: [Int64: [Float]] = [:]
                for (j, ref) in refs.enumerated() where !cand.rejected.contains(ref.personID) {
                    perPerson[ref.personID, default: []].append(sims[row * refs.count + j])
                }
                let scored = perPerson.map { pid, s -> (Int64, Float) in
                    let top = s.sorted(by: >).prefix(3)
                    return (pid, top.reduce(0, +) / Float(top.count))
                }.sorted { $0.1 > $1.1 }
                guard let best = scored.first else {
                    results.append(Assignment(faceID: cand.id, personID: nil, state: .unassigned, score: nil)); continue
                }
                let runnerUp = scored.dropFirst().first?.1 ?? -1
                if best.1 >= thresholds.certain && best.1 - runnerUp >= margin && cand.isGoodQuality {
                    results.append(Assignment(faceID: cand.id, personID: best.0, state: .auto, score: best.1))
                } else if best.1 >= thresholds.suggest {
                    results.append(Assignment(faceID: cand.id, personID: best.0, state: .suggested, score: best.1))
                } else {
                    results.append(Assignment(faceID: cand.id, personID: nil, state: .unassigned, score: best.1))
                }
            }
        }
        // One person appears at most once per photo: keep the strongest face, demote the others to review.
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.photoID) })
        var bestInPhoto: [String: (Int64, Float)] = [:]
        for a in results where a.state == .auto {
            let key = "\(byID[a.faceID]!)-\(a.personID!)"
            if let cur = bestInPhoto[key], cur.1 >= (a.score ?? 0) { continue }
            bestInPhoto[key] = (a.faceID, a.score ?? 0)
        }
        return results.map { a in
            guard a.state == .auto, let pid = a.personID else { return a }
            let key = "\(byID[a.faceID]!)-\(pid)"
            return bestInPhoto[key]?.0 == a.faceID ? a : Assignment(faceID: a.faceID, personID: pid, state: .suggested, score: a.score)
        }
    }

    /// Group faces that matched nobody. Returns groups of 2+ face IDs; singletons stay unassigned.
    /// Faces at or above `group` similarity are linked. Linking alone chains look-alikes into one big mixed
    /// group, so every group must also be tight around its own centre; a group that isn't is split again at a
    /// stricter threshold. Finally no group may hold two faces from the same photo.
    public func cluster(_ allFaces: [Candidate]) -> [[Int64]] {
        let faces = allFaces.filter(\.isGoodQuality)
        let n = faces.count
        guard n > 1, let dim = faces.first?.embedding.count else { return [] }
        let all = faces.flatMap(\.embedding)
        // First pass over everything, in blocks (memory stays O(block × n)).
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        let block = 512
        for start in stride(from: 0, to: n, by: block) {
            let m = min(block, n - start)
            let sims = Vector.similarity(Array(all[(start * dim)..<((start + m) * dim)]), rows: m, all, rows: n, dim: dim)
            for i in 0..<m {
                let gi = start + i
                for j in (gi + 1)..<n where sims[i * n + j] >= thresholds.group && faces[gi].photoID != faces[j].photoID {
                    let a = find(gi), b = find(j)
                    if a != b { parent[a] = b }
                }
            }
        }
        var components: [Int: [Int]] = [:]
        for i in 0..<n { components[find(i), default: []].append(i) }

        var groups: [[Int64]] = []
        for (_, members) in components where members.count > 1 {
            for g in refine(members, threshold: thresholds.group, faces: faces, dim: dim) {
                let kept = onePerPhoto(g, faces: faces, dim: dim)
                if kept.count > 1 { groups.append(kept.map { faces[$0].id }) }
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    /// Minimum similarity of every member to its group's centre.
    var tightness: Float { thresholds.group - 0.05 }

    private func centroid(_ members: [Int], faces: [Candidate], dim: Int) -> [Float] {
        var c = [Float](repeating: 0, count: dim)
        for m in members { for d in 0..<dim { c[d] += faces[m].embedding[d] } }
        return Vector.normalized(c)
    }

    private func refine(_ members: [Int], threshold: Float, faces: [Candidate], dim: Int) -> [[Int]] {
        guard members.count > 1 else { return [] }
        let c = centroid(members, faces: faces, dim: dim)
        if members.allSatisfy({ Vector.dot(faces[$0].embedding, c) >= tightness }) { return [members] }
        let next = threshold + 0.03
        guard next < 0.95 else { return [] }
        let k = members.count
        let sub = members.flatMap { faces[$0].embedding }
        let sims = Vector.similarity(sub, rows: k, sub, rows: k, dim: dim)
        var parent = Array(0..<k)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for i in 0..<k { for j in (i + 1)..<k where sims[i * k + j] >= next && faces[members[i]].photoID != faces[members[j]].photoID {
            let a = find(i), b = find(j); if a != b { parent[a] = b }
        } }
        var parts: [Int: [Int]] = [:]
        for i in 0..<k { parts[find(i), default: []].append(members[i]) }
        return parts.values.flatMap { refine($0, threshold: next, faces: faces, dim: dim) }
    }

    private func onePerPhoto(_ members: [Int], faces: [Candidate], dim: Int) -> [Int] {
        let c = centroid(members, faces: faces, dim: dim)
        var best: [Int64: (Int, Float)] = [:]
        for m in members {
            let s = Vector.dot(faces[m].embedding, c)
            if let cur = best[faces[m].photoID], cur.1 >= s { continue }
            best[faces[m].photoID] = (m, s)
        }
        return best.values.map(\.0)
    }
}
