import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Lifts the subject out of a photo, on this Mac, using the same system feature as Photos. The source file isn't
/// touched: the result only exists in memory until someone drags, copies or saves it.
public enum SubjectLift {
    public struct Result: @unchecked Sendable {
        /// The photo's size, transparent everywhere but the subject: lies exactly on top of the original.
        public let overlay: CGImage
        /// The same subject trimmed to its edges, for dragging, copying and saving.
        public let cutout: CGImage
    }

    /// `point` is normalised, origin top-left. When it lands on someone, only they are lifted; otherwise everything
    /// the system counts as a subject is.
    public static func lift(_ image: CGImage, at point: CGPoint? = nil) throws -> Result? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        var chosen = observation.allInstances
        if let point, let hit = instance(at: point, in: observation.instanceMask) { chosen = IndexSet(integer: hit) }

        let buffer = try observation.generateMaskedImage(ofInstances: chosen, from: handler, croppedToInstancesExtent: false)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let overlay = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        guard let bounds = opaqueBounds(of: overlay), let cutout = overlay.cropping(to: bounds) else { return nil }
        return Result(overlay: overlay, cutout: cutout)
    }

    /// Which subject covers a point. The mask holds 0 for background and the subject's number elsewhere.
    private static func instance(at point: CGPoint, in mask: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        let x = min(w - 1, max(0, Int(point.x * CGFloat(w)))), y = min(h - 1, max(0, Int(point.y * CGFloat(h))))
        let label = base.assumingMemoryBound(to: UInt8.self)[y * row + x]
        return label == 0 ? nil : Int(label)
    }

    /// The smallest rectangle holding everything visible.
    static func opaqueBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drawn = alpha.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where alpha[y * w + x] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
