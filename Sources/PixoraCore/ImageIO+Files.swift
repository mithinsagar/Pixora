import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import CoreImage

/// Where Pixora keeps its own data. Nothing is ever written next to the user's photos.
public enum AppPaths {
    /// `PIXORA_HOME` points the app at a separate library (used for testing and demos).
    /// The app was called Rollcall before; its library folder is moved to the new name on first launch.
    public static var root: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let custom = ProcessInfo.processInfo.environment["PIXORA_HOME"] {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = base.appendingPathComponent("Pixora", isDirectory: true)
        let legacy = base.appendingPathComponent("Rollcall", isDirectory: true)
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: url)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var database: URL { root.appendingPathComponent("library.sqlite") }
    public static var thumbnails: URL { dir("Thumbnails") }
    /// High-resolution face crops for covers and large face views, made from the original on demand.
    public static var faceCrops: URL { dir("FaceCrops") }
    public static var models: URL { dir("Models") }

    private static func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func thumbnail(photoID: Int64) -> URL {
        thumbnails.appendingPathComponent("\(photoID).jpg")
    }
}

public enum Fingerprint {
    /// Fast content fingerprint: SHA-256 over the file size, first 256 KB and last 256 KB.
    /// Two files with the same fingerprint are treated as the same photo (e.g. the same card imported twice
    /// from different folders). Export uses a full byte comparison before skipping anything.
    public static func quick(url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 256 * 1024
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Full SHA-256 of a file, streamed.
    public static func full(url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try? h.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func full(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PhotoMetadata: Sendable {
    public var width: Int?
    public var height: Int?
    public var takenAt: Date?
    public var camera: String?
    public var lens: String?
    public var rating: Int?
    public var latitude: Double?
    public var longitude: Double?
}

public enum ImageLoader {
    /// UTIs that this Mac's ImageIO can decode (includes the RAW formats Apple supports).
    public static let decodableTypes: Set<String> = {
        Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    public static func canDecode(ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return decodableTypes.contains(type.identifier)
    }

    public static func isImageFile(ext: String) -> Bool {
        if FileTypes.isRAW(ext: ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Decode an upright (orientation applied) image whose long edge is at most `maxPixel`.
    /// Works for JPEG, HEIC, PNG, TIFF and the RAW formats macOS supports.
    public static func image(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func metadata(at url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return m }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { m.width = h; m.height = w } else { m.width = w; m.height = h }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        if let dateString { m.takenAt = exifDateFormatter.date(from: dateString) }
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // Many cameras repeat the make in the model ("Canon Canon EOS R6"); avoid that.
            if let make, !model.lowercased().hasPrefix(make.lowercased().components(separatedBy: " ").first ?? "") {
                m.camera = "\(make) \(model)"
            } else { m.camera = model }
        }
        m.lens = (exif?[kCGImagePropertyExifLensModel] as? String) ?? (exifAux?[kCGImagePropertyExifAuxLensModel] as? String)
        if let xmpRating = props["Rating" as CFString] as? Int { m.rating = xmpRating }
        if m.rating == nil, let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           let r = iptc[kCGImagePropertyIPTCStarRating] as? Int { m.rating = r }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 {   // 0,0 is what cameras write before they have a fix
            m.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            m.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        return m
    }

    /// Exif dates carry no time zone; they are interpreted in the Mac's current zone, as Photos does.
    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    public static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Re-encode a photo as JPEG, keeping its metadata (Exif, GPS, IPTC), optionally resized and with names added.
    public static func exportJPEG(from url: URL, maxPixel: Int?, quality: Double = 0.9, names: [String] = []) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 8000, h = props[kCGImagePropertyPixelHeight] as? Int ?? 8000
        guard let image = Self.image(at: url, maxPixel: maxPixel ?? max(w, h)) else { return nil }
        let base = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        let meta: CGMutableImageMetadata = names.isEmpty ? (base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable())
                                                         : PeopleMetadata.metadata(names: names, base: base)
        // Pixels are already upright.
        CGImageMetadataSetValueWithPath(meta, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(dest, image, meta, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

extension ImageLoader {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Mean luminance (0…1) from a tiny downscale.
    public static func meanLuminance(_ image: CGImage) -> Double {
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return 0.5 }
        let p = data.bindMemory(to: UInt8.self, capacity: side * side)
        var sum = 0
        for i in 0..<(side * side) { sum += Int(p[i]) }
        return Double(sum) / Double(side * side * 255)
    }

    /// For dark (under-exposed or low-light) photos, a brightened copy used only for finding and reading faces.
    /// The original file is never changed. Returns the input unchanged when the photo is not dark.
    public static func brightenedIfDark(_ image: CGImage) -> CGImage {
        let mean = meanLuminance(image)
        guard mean < 0.28 else { return image }
        let ev = min(3.0, log2(0.42 / max(mean, 0.02)))
        var ci = CIImage(cgImage: image)
        ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        ci = ci.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.85])
        return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
    }
}

extension ImageLoader {
    /// A sharp square crop around a face, straight from the original photo (orientation applied).
    /// `rect` is the face box, normalised with a top-left origin; `margin` is how much context to keep.
    public static func faceCrop(photoURL: URL, rect: CGRect, side: Int, margin: CGFloat = 1.8) -> CGImage? {
        // Decode just large enough that the crop has `side` real pixels.
        let frac = max(rect.width, rect.height) * margin
        let longEdge = Int(min(7000, max(1200, CGFloat(side) / max(frac, 0.01))))
        guard let img = image(at: photoURL, maxPixel: longEdge) else { return nil }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let cropSide = min(max(rect.width * W, rect.height * H) * margin, min(W, H))
        var x = rect.midX * W - cropSide / 2, y = rect.midY * H - cropSide / 2 - cropSide * 0.05   // a touch more forehead room
        x = min(max(0, x), W - cropSide); y = min(max(0, y), H - cropSide)
        guard let cropped = img.cropping(to: CGRect(x: x, y: y, width: cropSide, height: cropSide).integral) else { return nil }
        let out = min(side, Int(cropSide))
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: out, height: out))
        return ctx.makeImage()
    }
}
