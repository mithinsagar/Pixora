import Foundation
import CoreGraphics
import PixoraCore

/// End-to-end check of the real pipeline on a labelled test card (see tools/make_test_card.py).
/// Run with PIXORA_HOME set to an empty folder so the user's own library is never touched.
func runE2E(card: URL, manifestURL: URL) async throws {
    guard let home = ProcessInfo.processInfo.environment["PIXORA_HOME"] else { print("Set PIXORA_HOME to a scratch folder."); exit(2) }
    print("library: \(home)")
    struct Manifest: Decodable { let cast: [String: String]; let truth: [String: [String]]; let raw_pairs: [String]; let corrupt: [String] }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let store = try LibraryStore.openDefault()
    let embedder = Embedders.makeDefault()
    print("embedder: \(embedder.displayName)")

    // Hash originals so we can prove they were not modified.
    let originals = try FileManager.default.subpathsOfDirectory(atPath: card.path).filter { !$0.hasPrefix(".") }
    let before = Dictionary(uniqueKeysWithValues: originals.compactMap { p in Fingerprint.full(url: card.appendingPathComponent(p)).map { (p, $0) } })

    // 1. Import + preview + scan
    let source = try store.addSource(url: card)
    let preview = FileScanner.preview(root: card)
    print("preview: \(preview.files.count) photos, \(preview.rawPairs) RAW+JPEG pairs, formats \(preview.formats)")
    let engine = ScanEngine(store: store, embedder: embedder, thresholds: embedder.thresholds)
    let t0 = Date()
    let result = await engine.run(source: source, files: preview.files) { _ in }
    print(String(format: "scan: %d analysed, %d faces, %d problems in %.1fs", result.newPhotos, result.facesFound, result.errors.count, Date().timeIntervalSince(t0)))
    for e in result.errors { print("   problem: \(e.file) — \(e.message)") }

    // Ground truth for a face: which tile of the side-by-side composite its centre falls in.
    func truth(of face: Face, photo: Photo) -> String? {
        guard let people = manifest.truth[photo.filename] else { return nil }
        let i = min(people.count - 1, Int(face.rect.midX * CGFloat(people.count)))
        return people[i]
    }
    let photosByID = Dictionary(uniqueKeysWithValues: try store.photos().map { ($0.id, $0) })

    // 2. Groups found automatically
    print("\nautomatic groups:")
    var groupLabel: [Int64: String] = [:]
    for p in try store.people() {
        let faces = try store.faces(personID: p.id)
        let labels = faces.compactMap { f in photosByID[f.photoID].flatMap { truth(of: f, photo: $0) } }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }
        print("  group \(p.id): \(faces.count) faces → \(counts.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
        if let top = counts.first { groupLabel[p.id] = top.key }
    }
    let unsorted = try store.unsortedFaces().count
    print("  unsorted faces: \(unsorted)   uncertain: \(try store.uncertainFaces().count)")

    if ProcessInfo.processInfo.environment["PIXORA_SCAN_ONLY"] != nil { return }

    // 3. Simulate the user naming each group by its majority identity (same name twice = merge).
    for (pid, label) in groupLabel { try store.name(personID: pid, as: label) }
    try store.runMatching(embedderID: embedder.id, thresholds: embedder.thresholds)

    // 4. The core workflow: "me and a friend together"
    guard let me = try store.person(named: manifest.cast["A"]!), let friend = try store.person(named: manifest.cast["B"]!) else {
        print("FAIL: A or B was never grouped"); return
    }
    let expectedAll = Set(manifest.truth.filter { $0.value.contains(manifest.cast["A"]!) && $0.value.contains(manifest.cast["B"]!) }.keys)
    let expectedAny = Set(manifest.truth.filter { $0.value.contains(manifest.cast["A"]!) || $0.value.contains(manifest.cast["B"]!) }.keys)
    for (label, mode, expected) in [("ALL (both together)", MatchMode.all, expectedAll), ("ANY (either)", MatchMode.any, expectedAny)] {
        for uncertain in [false, true] {
            let got = Set(try store.search(people: [me, friend], mode: mode, includeUncertain: uncertain).map(\.photo.filename))
            let tp = got.intersection(expected).count
            print("search \(label)\(uncertain ? " + uncertain" : ""): \(got.count) found, \(tp)/\(expected.count) correct, \(got.count - tp) wrong"
                  + (got.subtracting(expected).isEmpty ? "" : "  wrong: \(got.subtracting(expected).sorted())")
                  + (expected.subtracting(got).isEmpty ? "" : "  missed: \(expected.subtracting(got).sorted())"))
        }
    }

    // 5. Export the "both together" results
    let dest = URL(fileURLWithPath: home).appendingPathComponent("export", isDirectory: true)
    var options = ExportOptions(destination: dest)
    options.preset = .originalsWithRAW
    options.organization = .byDate
    let results = try store.search(people: [me, friend], mode: .all, includeUncertain: false)
    let items = results.map { ExportItem(photo: $0.photo, sourceRoot: card, people: ["A", "B"]) }
    let report = Exporter.export(items, options: options)
    print("\nexport: \(report.copied.count) files copied (\(report.copied.filter { $0.pathExtension == "CR3" }.count) RAW), \(report.duplicatesSkipped.count) duplicates, \(report.errors.count) errors")
    print("  folders: \(Set(report.copied.map { $0.deletingLastPathComponent().path.replacingOccurrences(of: dest.path + "/", with: "") }).sorted())")
    let again = Exporter.export(items, options: options)
    print("export again: \(again.copied.count) copied, \(again.duplicatesSkipped.count) skipped as duplicates")

    // 6. Re-scan: nothing new, no duplicate records
    let photosBefore = try store.photos().count
    let rescan = await engine.run(source: source, files: FileScanner.preview(root: card).files) { _ in }
    print("rescan: \(rescan.newPhotos) analysed, \(rescan.skippedUnchanged) unchanged skipped; photos in library \(photosBefore) → \(try store.photos().count)")

    // 7. Originals untouched
    let changed = before.filter { Fingerprint.full(url: card.appendingPathComponent($0.key)) != $0.value }
    let after = try FileManager.default.subpathsOfDirectory(atPath: card.path).filter { !$0.hasPrefix(".") }
    print("originals: \(changed.isEmpty ? "all \(before.count) unchanged" : "CHANGED: \(changed.keys)"), files on card \(originals.count) → \(after.count)")
}
