import Foundation

/// Settings the scanning engine needs (stored in UserDefaults, edited in Settings).
public enum AppSettings {
    private static var d: UserDefaults { .standard }

    /// Keep a small (≤640 px) preview of each photo in Pixora's library so it can be browsed with the card
    /// ejected. Off: nothing is copied; photos are only visible while their card or drive is connected.
    public static var keepPreviews: Bool {
        get { d.object(forKey: "keepPreviews") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepPreviews") }
    }

    /// Long edge photos are analysed at: 2400 (fast), 3200 (standard), 4800 (detailed — very large groups).
    public static var analysisLongEdge: Int {
        get { let v = d.integer(forKey: "analysisLongEdge"); return v == 0 ? 3200 : v }
        set { d.set(newValue, forKey: "analysisLongEdge") }
    }

    /// Also look for faces in four overlapping tiles of each large photo (finds small faces in group shots).
    public static var tiledDetection: Bool {
        get { d.object(forKey: "tiledDetection") as? Bool ?? true }
        set { d.set(newValue, forKey: "tiledDetection") }
    }

    /// Photos analysed in parallel.
    public static var scanWorkers: Int {
        get { let v = d.integer(forKey: "scanWorkers"); return v == 0 ? 3 : min(6, max(1, v)) }
        set { d.set(newValue, forKey: "scanWorkers") }
    }

    /// Show a banner when a camera card is inserted.
    public static var cardPrompt: Bool {
        get { d.object(forKey: "cardPrompt") as? Bool ?? true }
        set { d.set(newValue, forKey: "cardPrompt") }
    }
}

public enum StorageInfo {
    public static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return total
    }

    /// Delete every stored photo preview. The library, people and faces are untouched.
    public static func deletePreviews() {
        try? FileManager.default.removeItem(at: AppPaths.thumbnails)
    }

    /// Delete the sharp face crops made for covers (they are re-made from originals when the card is connected).
    public static func deleteFaceCrops() {
        try? FileManager.default.removeItem(at: AppPaths.faceCrops)
    }
}
