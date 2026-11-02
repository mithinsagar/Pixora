import Foundation
import ImageIO
import CoreGraphics

public struct ExportOptions: Sendable, Equatable {
    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        /// The file that was scanned (JPEG of a RAW+JPEG pair, or the RAW if there is no JPEG). Byte-for-byte copy.
        case originals
        /// The scanned file plus its RAW/sidecar siblings. Byte-for-byte copies.
        case originalsWithRAW
        /// Always JPEG: JPEGs are copied as-is; other formats (HEIC, RAW, PNG…) are converted at full size.
        case jpegOnly
        /// JPEG resized to `shareLongEdge` pixels on the long edge, metadata kept. Good for messaging apps.
        case resizedForSharing
        public var id: String { rawValue }
    }

    public enum Organization: String, CaseIterable, Sendable, Identifiable {
        case flat, byPerson, byDate, byEvent
        public var id: String { rawValue }
    }

    public var destination: URL
    public var preset: Preset = .originals
    public var organization: Organization = .flat
    public var shareLongEdge = 2048
    /// A new event starts after this many hours without photos.
    public var eventGapHours: Double = 3
    /// Re-read every copy and compare its SHA-256 with the source.
    public var verifyCopies = true
    /// Write the people in each photo into the exported copy (XMP "Person Shown" + keywords), so Lightroom,
    /// Apple Photos and Google Photos see the names. JPEG/HEIC/PNG/TIFF get it embedded without re-compressing
    /// the pixels; RAW files get a .xmp sidecar. Originals are never touched.
    public var writePeopleNames = true
    /// After copying, also make a .zip of each top-level folder (e.g. one per person) for easy sending.
    public var zipFolders = false

    public init(destination: URL) { self.destination = destination }
}

public struct ExportItem: Sendable {
    public let photo: Photo
    public let sourceRoot: URL
    /// Names of the people in this photo (by-person folders, and the names written into the copy).
    public let people: [String]
    /// Explicit sub-folder(s), overriding the organisation option (used by "Export Everyone").
    public let folders: [String]?
    /// For by-person organisation: whose folders this photo goes in (defaults to `people`).
    public let byPersonFolders: [String]?
    public init(photo: Photo, sourceRoot: URL, people: [String], folders: [String]? = nil, byPersonFolders: [String]? = nil) {
        self.photo = photo; self.sourceRoot = sourceRoot; self.people = people; self.folders = folders; self.byPersonFolders = byPersonFolders
    }
}

public struct ExportReport: Sendable {
    public var copied: [URL] = []
    public var bytesWritten: Int64 = 0
    public var duplicatesSkipped: [String] = []
    public var errors: [(file: String, message: String)] = []
    public var zips: [URL] = []
    public var destination: URL
}

public enum Exporter {
    /// Copy photos into the destination. Never overwrites, never touches the originals.
    /// Writes go to a hidden temporary file that is renamed only after it is complete (and verified).
    public static func export(_ items: [ExportItem], options: ExportOptions,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in },
                              isCancelled: () -> Bool = { false }) -> ExportReport {
        var report = ExportReport(destination: options.destination)
        let fm = FileManager.default
        let folders = folderPlan(items, options: options)
        var done = 0
        let jobs = items.enumerated().flatMap { idx, item in (folders[idx] ?? [""]).map { (item, $0) } }
        for (item, folder) in jobs {
            if isCancelled() { break }
            defer { done += 1; progress(done, jobs.count) }
            let dir = folder.isEmpty ? options.destination : options.destination.appendingPathComponent(folder, isDirectory: true)
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { report.errors.append((item.photo.filename, "Could not create folder \(folder): \(error.localizedDescription)")); continue }

            let primary = item.sourceRoot.appendingPathComponent(item.photo.relPath)
            guard fm.fileExists(atPath: primary.path) else {
                report.errors.append((item.photo.filename, "Original not found — is the card or drive connected?")); continue
            }
            let names = options.writePeopleNames ? item.people : []
            switch options.preset {
            case .originals:
                copy(primary, into: dir, report: &report, verify: options.verifyCopies, names: names)
            case .originalsWithRAW:
                copy(primary, into: dir, report: &report, verify: options.verifyCopies, names: names)
                for s in item.photo.siblings {
                    copy(item.sourceRoot.appendingPathComponent(s), into: dir, report: &report, verify: options.verifyCopies, names: names)
                }
            case .jpegOnly:
                if FileTypes.isJPEG(ext: item.photo.ext) {
                    copy(primary, into: dir, report: &report, verify: options.verifyCopies, names: names)
                } else {
                    writeJPEG(from: primary, maxPixel: nil, into: dir, report: &report, names: names)
                }
            case .resizedForSharing:
                writeJPEG(from: primary, maxPixel: options.shareLongEdge, into: dir, report: &report, names: names)
            }
        }
        if options.zipFolders, !isCancelled() {
            let tops = Set(report.copied.compactMap { url -> URL? in
                let rel = url.path.dropFirst(options.destination.path.count + 1)
                guard let first = rel.split(separator: "/").first, rel.contains("/") else { return nil }
                return options.destination.appendingPathComponent(String(first), isDirectory: true)
            })
            for folder in tops.sorted(by: { $0.path < $1.path }) {
                let zip = folder.appendingPathExtension("zip")
                guard !FileManager.default.fileExists(atPath: zip.path) else { report.duplicatesSkipped.append(zip.lastPathComponent); continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
                do { try p.run(); p.waitUntilExit() } catch { report.errors.append((zip.lastPathComponent, error.localizedDescription)) }
                if p.terminationStatus == 0 { report.zips.append(zip) } else { report.errors.append((zip.lastPathComponent, "Could not create zip.")) }
            }
        }
        return report
    }

    /// Which sub-folder(s) each item goes into. By-person puts a photo in every selected person's folder.
    static func folderPlan(_ items: [ExportItem], options: ExportOptions) -> [Int: [String]] {
        var plan: [Int: [String]] = [:]
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let year = DateFormatter(); year.locale = Locale(identifier: "en_US_POSIX"); year.dateFormat = "yyyy"
        switch options.organization {
        case .flat:
            for i in items.indices { plan[i] = [""] }
        case .byPerson:
            for (i, item) in items.enumerated() {
                let who = item.byPersonFolders ?? item.people
                plan[i] = who.isEmpty ? ["Unknown"] : who.map(safeName)
            }
        case .byDate:
            for (i, item) in items.enumerated() {
                if let d = item.photo.takenAt { plan[i] = ["\(year.string(from: d))/\(day.string(from: d))"] } else { plan[i] = ["Undated"] }
            }
        case .byEvent:
            let dated = items.enumerated().filter { $0.element.photo.takenAt != nil }.sorted { $0.element.photo.takenAt! < $1.element.photo.takenAt! }
            var last: Date?
            var eventName = ""
            var perDay: [String: Int] = [:]
            for (i, item) in dated {
                let t = item.photo.takenAt!
                if last == nil || t.timeIntervalSince(last!) > options.eventGapHours * 3600 {
                    let d = day.string(from: t)
                    perDay[d, default: 0] += 1
                    eventName = perDay[d]! == 1 ? "\(d) Event" : "\(d) Event \(perDay[d]!)"
                }
                last = t
                plan[i] = [eventName]
            }
            for (i, item) in items.enumerated() where item.photo.takenAt == nil { plan[i] = ["Undated"] }
        }
        for (i, item) in items.enumerated() { if let f = item.folders { plan[i] = f.map(safeName) } }   // explicit folders win
        return plan
    }

    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Person" : cleaned
    }

    /// Byte-for-byte copy (or, with `names`, a lossless re-wrap that only adds metadata). If a file with the same
    /// name exists: identical content → skipped as duplicate; different content → saved as "name 2.ext".
    /// Nothing is ever overwritten.
    static func copy(_ src: URL, into dir: URL, report: inout ExportReport, verify: Bool, names: [String] = []) {
        let fm = FileManager.default
        let name = src.lastPathComponent
        guard fm.fileExists(atPath: src.path) else { report.errors.append((name, "Original not found.")); return }

        // Embedded names for formats ImageIO can re-wrap without touching pixels.
        if !names.isEmpty, !FileTypes.isRAW(ext: src.pathExtension) {
            if let data = PeopleMetadata.taggedCopy(of: src, names: names) {
                write(data, named: name, into: dir, report: &report)
                return
            }
        }

        let srcSize = ((try? fm.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.int64Value ?? -1
        var srcHash: String?
        func sourceHash() -> String? { if srcHash == nil { srcHash = Fingerprint.full(url: src) }; return srcHash }

        guard let target = destinationName(for: name, in: dir, isDuplicate: { existing in
            let size = ((try? fm.attributesOfItem(atPath: existing.path))?[.size] as? NSNumber)?.int64Value
            return size == srcSize && Fingerprint.full(url: existing) == sourceHash()
        }) else { report.duplicatesSkipped.append(name); return }

        let temp = dir.appendingPathComponent(".pixora-partial-\(UUID().uuidString)-\(name)")
        do {
            try fm.copyItem(at: src, to: temp)
            if verify, Fingerprint.full(url: temp) != sourceHash() {
                try? fm.removeItem(at: temp)
                report.errors.append((name, "Copy did not match the original after writing; nothing was kept.")); return
            }
            try fm.moveItem(at: temp, to: target)  // fails rather than overwrite if the name appeared meanwhile
            report.copied.append(target)
            report.bytesWritten += srcSize
            // RAW: names go in a sidecar next to the copy (Lightroom/Capture One read basename.xmp).
            if !names.isEmpty, FileTypes.isRAW(ext: src.pathExtension), let xmp = PeopleMetadata.sidecar(names: names) {
                let side = target.deletingPathExtension().appendingPathExtension("xmp")
                if !fm.fileExists(atPath: side.path) { try? xmp.write(to: side, options: .withoutOverwriting) }
            }
        } catch {
            try? fm.removeItem(at: temp)
            report.errors.append((name, error.localizedDescription))
        }
    }

    /// Write prepared bytes with the same duplicate / no-overwrite rules as `copy`.
    static func write(_ data: Data, named name: String, into dir: URL, report: inout ExportReport) {
        let hash = Fingerprint.full(data: data)
        guard let target = destinationName(for: name, in: dir, isDuplicate: { Fingerprint.full(url: $0) == hash }) else {
            report.duplicatesSkipped.append(name); return
        }
        let temp = dir.appendingPathComponent(".pixora-partial-\(UUID().uuidString)-\(name)")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            try FileManager.default.moveItem(at: temp, to: target)
            report.copied.append(target)
            report.bytesWritten += Int64(data.count)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            report.errors.append((name, error.localizedDescription))
        }
    }

    static func writeJPEG(from src: URL, maxPixel: Int?, into dir: URL, report: inout ExportReport, names: [String] = []) {
        let name = src.deletingPathExtension().lastPathComponent + ".jpg"
        guard let data = ImageLoader.exportJPEG(from: src, maxPixel: maxPixel, names: names) else {
            report.errors.append((src.lastPathComponent, "macOS could not convert this file to JPEG.")); return
        }
        write(data, named: name, into: dir, report: &report)
    }

    /// A free file name in `dir`, or nil if an identical file is already there.
    static func destinationName(for name: String, in dir: URL, isDuplicate: (URL) -> Bool) -> URL? {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent(n == 1 ? name : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            if isDuplicate(candidate) { return nil }
            n += 1
        }
    }
}

/// XMP people metadata: Iptc4xmpExt:PersonInImage (IPTC "Person Shown") plus dc:subject keywords.
public enum PeopleMetadata {
    static let iptcExtNS = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString

    /// Start from the file's own metadata (if any) and add the names, keeping existing keywords.
    static func metadata(names: [String], base: CGImageMetadata?) -> CGMutableImageMetadata {
        let m = base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(m, iptcExtNS, "Iptc4xmpExt" as CFString, nil)
        var keywords: [String] = []
        if let base, let tag = CGImageMetadataCopyTagWithPath(base, nil, "dc:subject" as CFString),
           let existing = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            keywords = existing.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        for n in names where !keywords.contains(n) { keywords.append(n) }
        if let t = CGImageMetadataTagCreate(iptcExtNS, "Iptc4xmpExt" as CFString, "PersonInImage" as CFString, .arrayUnordered, names as CFArray) {
            CGImageMetadataSetTagWithPath(m, nil, "Iptc4xmpExt:PersonInImage" as CFString, t)
        }
        if let t = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "subject" as CFString, .arrayUnordered, keywords as CFArray) {
            CGImageMetadataSetTagWithPath(m, nil, "dc:subject" as CFString, t)
        }
        return m
    }

    /// The same file with names added, without re-encoding the image data. nil if the format can't be re-wrapped.
    public static func taggedCopy(of url: URL, names: [String]) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return nil }
        let meta = metadata(names: names, base: CGImageSourceCopyMetadataAtIndex(src, 0, nil))
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, nil) else { return nil }
        // Sanity check: the result decodes to the same pixel size.
        guard let check = CGImageSourceCreateWithData(data, nil),
              let a = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let b = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              a[kCGImagePropertyPixelWidth] as? Int == b[kCGImagePropertyPixelWidth] as? Int,
              a[kCGImagePropertyPixelHeight] as? Int == b[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return data as Data
    }

    public static func sidecar(names: [String]) -> Data? {
        CGImageMetadataCreateXMPData(metadata(names: names, base: nil), nil) as Data?
    }

    /// Names stored in a file's metadata (used by tests and the inspector).
    public static func names(in url: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(meta, nil, "Iptc4xmpExt:PersonInImage" as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }
}
