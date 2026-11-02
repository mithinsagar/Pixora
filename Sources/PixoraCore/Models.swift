import Foundation
import CoreGraphics

/// How sure the app is that a face belongs to its person. Stored as an integer in `faces.state`.
public enum FaceState: Int, Sendable, Comparable {
    /// No person yet (a singleton, or rejected from a person).
    case unassigned = 0
    /// Borderline similarity: shown in the Review inbox, excluded from results unless the user asks.
    case suggested = 1
    /// Grouped automatically with high similarity; counted as a match.
    case auto = 2
    /// Confirmed by the user (named group, "Yes" in review, or assigned by hand).
    case confirmed = 3

    public static func < (a: FaceState, b: FaceState) -> Bool { a.rawValue < b.rawValue }
    public var isCertain: Bool { self >= .auto }
}

public struct Source: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var volumeUUID: String?
    public var volumeName: String?
    public var isRemovable: Bool
    public var addedAt: Date
    public var lastScanAt: Date?

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var isOnline: Bool { FileManager.default.fileExists(atPath: path) }
}

public struct ImportRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sourceID: Int64
    public let sourceName: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: String
    public let filesTotal: Int
    public let filesNew: Int
    public let filesSkipped: Int
    public let facesFound: Int
    public let errors: Int
}

public struct Photo: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sourceID: Int64
    public let relPath: String
    public let filename: String
    public let ext: String
    /// Other files shot together with this one (e.g. the RAW of a RAW+JPEG pair), relative paths.
    public let siblings: [String]
    public let fileSize: Int64
    public let fingerprint: String?
    public let width: Int?
    public let height: Int?
    public let takenAt: Date?
    public let camera: String?
    public let lens: String?
    public let rating: Int?
    public let scanState: Int
    public let scanError: String?

    public var isRAW: Bool { FileTypes.isRAW(ext: ext) }
}

public struct Person: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String?
    public var coverFaceID: Int64?
    public var photoCount: Int
    public var faceCount: Int
    public var uncertainCount: Int
    public var lastSeen: Date?
    public var contactID: String?
    /// Phone numbers / emails from the linked contact, for "Send to…".
    public var contactHandles: [String] = []
    public var displayName: String { name ?? "Unnamed" }

    public init(id: Int64, name: String?, coverFaceID: Int64?, photoCount: Int, faceCount: Int, uncertainCount: Int, lastSeen: Date?,
                contactID: String? = nil, contactHandles: [String] = []) {
        self.id = id; self.name = name; self.coverFaceID = coverFaceID; self.photoCount = photoCount; self.faceCount = faceCount
        self.uncertainCount = uncertainCount; self.lastSeen = lastSeen; self.contactID = contactID; self.contactHandles = contactHandles
    }
    public var isNamed: Bool { name != nil }
}

public struct Face: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let photoID: Int64
    /// Normalised rectangle in the upright image, origin top-left.
    public let rect: CGRect
    public let pixelSize: Double
    public let quality: Double?
    public let personID: Int64?
    public let state: FaceState
    public let score: Double?
    public let hasEmbedding: Bool
    public let thumb: Data?
}

public enum MatchMode: String, CaseIterable, Sendable {
    /// Photos containing every selected person.
    case all
    /// Photos containing at least one selected person.
    case any
    /// Photos containing every selected person and nobody else (solo photos when one person is selected).
    /// Tiny background faces — less than 40% the size of the selected faces — don't count as "somebody else".
    case only
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: Int64 { photo.id }
    public let photo: Photo
    /// Selected people found in this photo, with whether the match is certain.
    public let matches: [PersonMatch]
    /// 0…1 shot quality for the selected people: face quality, sharpness, eyes open, face size.
    public var score: Double = 0
    /// A selected person may have their eyes closed.
    public var eyesClosed = false
    /// A selected person's face is much softer than usual for them (missed focus / motion blur).
    public var soft = false
    /// Photos taken within 2 s of each other that look alike share a burst id.
    public var burstID: Int64?

    public init(photo: Photo, matches: [PersonMatch], score: Double = 0, eyesClosed: Bool = false, soft: Bool = false, burstID: Int64? = nil) {
        self.photo = photo; self.matches = matches; self.score = score
        self.eyesClosed = eyesClosed; self.soft = soft; self.burstID = burstID
    }
}

public struct PersonMatch: Hashable, Sendable {
    public let personID: Int64
    public let faceID: Int64
    public let state: FaceState
    public let score: Double?
    public init(personID: Int64, faceID: Int64, state: FaceState, score: Double?) {
        self.personID = personID; self.faceID = faceID; self.state = state; self.score = score
    }
}

public enum FileTypes {
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "dng",
        "srw", "x3f", "3fr", "fff", "iiq", "mos", "mrw", "rwl", "erf", "kdc", "dcr", "gpr",
    ]
    /// Formats preferred as the "primary" file of a RAW+JPEG pair (fast to decode).
    public static let processedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "avif"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "3gp", "insv", "lrv", "thm"]

    public static func isRAW(ext: String) -> Bool { rawExtensions.contains(ext.lowercased()) }
    public static func isJPEG(ext: String) -> Bool { ["jpg", "jpeg"].contains(ext.lowercased()) }
}
