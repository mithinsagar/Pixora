import Foundation
import ImageIO

/// Where a photo was taken, from its own GPS tags.
public struct PlacedPhoto: Identifiable, Hashable, Sendable {
    public var id: Int64 { photo.id }
    public let photo: Photo
    public let latitude: Double
    public let longitude: Double
    public init(photo: Photo, latitude: Double, longitude: Double) { self.photo = photo; self.latitude = latitude; self.longitude = longitude }
}

/// Photos near each other at the current map zoom.
public struct PlaceCluster: Identifiable, Hashable, Sendable {
    public var id: Int64 { photos[0].id }
    public let photos: [PlacedPhoto]
    public let latitude: Double
    public let longitude: Double
    public var latitudeSpan: Double { (photos.map(\.latitude).max() ?? 0) - (photos.map(\.latitude).min() ?? 0) }
    public var longitudeSpan: Double { (photos.map(\.longitude).max() ?? 0) - (photos.map(\.longitude).min() ?? 0) }
}

public enum Places {
    /// Groups photos on a grid about `cell` degrees wide. Cells are anchored to the globe, not the first photo, so
    /// pins don't shuffle around as the map moves.
    public static func cluster(_ photos: [PlacedPhoto], cell: Double) -> [PlaceCluster] {
        guard cell > 0 else { return photos.map { PlaceCluster(photos: [$0], latitude: $0.latitude, longitude: $0.longitude) } }
        var cells: [String: [PlacedPhoto]] = [:]
        for p in photos { cells["\(Int((p.latitude / cell).rounded(.down))):\(Int((p.longitude / cell).rounded(.down)))", default: []].append(p) }
        return cells.values.map { list in
            let sorted = list.sorted { ($0.photo.takenAt ?? .distantPast) > ($1.photo.takenAt ?? .distantPast) }
            let n = Double(list.count)
            return PlaceCluster(photos: sorted, latitude: list.map(\.latitude).reduce(0, +) / n, longitude: list.map(\.longitude).reduce(0, +) / n)
        }
        .sorted { $0.photos.count > $1.photos.count }
    }

    /// Reads GPS tags from photos scanned before Pixora kept them, for any whose card or drive is connected. Each
    /// photo is read once: a row with no position means it has no GPS tag.
    public static func backfill(store: LibraryStore, roots: [Int64: URL], isCancelled: () -> Bool = { false }) throws {
        for (photoID, sourceID, relPath) in try store.photosWithoutPlaceCheck() {
            if isCancelled() { return }
            guard let root = roots[sourceID] else { continue }
            let url = root.appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let meta = ImageLoader.metadata(at: url)
            try store.setPlace(photoID: photoID, latitude: meta.latitude, longitude: meta.longitude)
        }
    }
}

extension LibraryStore {
    public func placedPhotos() throws -> [PlacedPhoto] {
        try db.read {
            try $0.query("""
            SELECT \(Self.photoColumns), pl.lat, pl.lon FROM photos ph JOIN photo_places pl ON pl.photo_id = ph.id
            WHERE pl.lat IS NOT NULL AND pl.lon IS NOT NULL AND ph.scan_state = 1
            """) { PlacedPhoto(photo: Self.photo($0), latitude: $0.double(16), longitude: $0.double(17)) }
        }
    }

    func photosWithoutPlaceCheck() throws -> [(Int64, Int64, String)] {
        try db.read {
            try $0.query("SELECT ph.id, ph.source_id, ph.rel_path FROM photos ph LEFT JOIN photo_places pl ON pl.photo_id = ph.id WHERE pl.photo_id IS NULL AND ph.scan_state = 1") {
                ($0.int(0), $0.int(1), $0.text(2))
            }
        }
    }

    /// Photos that couldn't be checked for a location because their card or drive isn't connected.
    public func uncheckedPlaceCount() throws -> Int { try photosWithoutPlaceCheck().count }

    public func setPlace(photoID: Int64, latitude: Double?, longitude: Double?) throws {
        try db.write { try $0.run("INSERT OR REPLACE INTO photo_places(photo_id, lat, lon) VALUES(?,?,?)", photoID, latitude, longitude) }
    }
}
