import Foundation
import CoreGraphics

/// The soft glow behind a photo: its own colours, blurred far past recognition, richer and darker so it sits behind
/// the picture instead of competing with it. Small enough to make in a millisecond and stretched by the GPU.
public enum AmbientBackdrop {
    static let side = 40
    /// No part of the glow is brighter than this, however white the photo.
    static let ceiling = 0.34

    public static func make(from image: CGImage) -> CGImage? {
        let n = side
        guard var px = pixels(of: image, side: n) else { return nil }
        for i in 0..<(n * n) {
            var (r, g, b) = (px[i * 3], px[i * 3 + 1], px[i * 3 + 2])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let rich = 1.7   // saturation
            r = luma + (r - luma) * rich; g = luma + (g - luma) * rich; b = luma + (b - luma) * rich
            let dim = 0.18 + 0.62 * min(1, luma)
            px[i * 3] = clamp(r * dim); px[i * 3 + 1] = clamp(g * dim); px[i * 3 + 2] = clamp(b * dim)
        }
        for _ in 0..<3 { blur(&px, side: n, radius: 5) }
        let peak = stride(from: 0, to: px.count, by: 3).map { 0.2126 * px[$0] + 0.7152 * px[$0 + 1] + 0.0722 * px[$0 + 2] }.max() ?? 0
        let scale = peak > ceiling ? ceiling / peak : 1
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, px[i * 3 + c] * scale * 255))) }
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    public static func averageColor(of image: CGImage) -> CGColor {
        guard let px = pixels(of: image, side: 1) else { return CGColor(gray: 0, alpha: 1) }
        return CGColor(srgbRed: px[0], green: px[1], blue: px[2], alpha: 1)
    }

    private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    private static func pixels(of image: CGImage, side n: Int) -> [Double]? {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var out = [Double](repeating: 0, count: n * n * 3)
        for i in 0..<(n * n) { for c in 0..<3 { out[i * 3 + c] = Double(bytes[i * 4 + c]) / 255 } }
        return out
    }

    /// One box blur, across then down. Run a few times it's as smooth as a Gaussian.
    private static func blur(_ px: inout [Double], side n: Int, radius: Int) {
        for vertical in [false, true] {
            var out = px
            for line in 0..<n {
                for i in 0..<n {
                    var sum = (0.0, 0.0, 0.0)
                    for k in -radius...radius {
                        let j = max(0, min(n - 1, i + k))
                        let p = (vertical ? j * n + line : line * n + j) * 3
                        sum.0 += px[p]; sum.1 += px[p + 1]; sum.2 += px[p + 2]
                    }
                    let d = Double(radius * 2 + 1), p = (vertical ? i * n + line : line * n + i) * 3
                    out[p] = sum.0 / d; out[p + 1] = sum.1 / d; out[p + 2] = sum.2 / d
                }
            }
            px = out
        }
    }
}
