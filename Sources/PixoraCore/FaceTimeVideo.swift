import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo

/// Writes a Through Time reel to a movie: each frame dissolves into the next, with its date in the corner.
public enum FaceTimeVideo {
    public struct Frame: @unchecked Sendable {
        public let image: CGImage
        public let caption: String
        public init(image: CGImage, caption: String) { self.image = image; self.caption = caption }
    }
    public enum Failure: Error, LocalizedError {
        case cannotWrite, nothingToWrite
        public var errorDescription: String? {
            switch self {
            case .cannotWrite: "The video could not be written."
            case .nothingToWrite: "There are no frames to write."
            }
        }
    }

    public static func write(_ frames: [Frame], title: String, to url: URL, side: Int = 1080, secondsPerFrame: Double = 0.42,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !frames.isEmpty else { throw Failure.nothingToWrite }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let fps = 30, perFrame = max(2, Int(secondsPerFrame * Double(fps)))
        let total = frames.count * perFrame + fps   // the last frame holds for a second
        for i in 0..<total {
            try Task.checkCancellation()
            let position = min(Double(frames.count - 1), Double(i) / Double(perFrame))
            let a = Int(position), mix = position - Double(a)
            // Hold on each face, then dissolve in the last part of its time.
            let blend = max(0, (mix - 0.45) / 0.55)
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw writer.error ?? Failure.cannotWrite }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? Failure.cannotWrite }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.cannotWrite }
            draw(frames[a], next: a + 1 < frames.count ? frames[a + 1] : nil, blend: blend, title: title, side: side, into: buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))) else { throw writer.error ?? Failure.cannotWrite }
            if i % 15 == 0 { progress(Double(i) / Double(total)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.cannotWrite }
        progress(1)
    }

    private static func draw(_ frame: Frame, next: Frame?, blend: Double, title: String, side: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let all = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.interpolationQuality = .high
        ctx.draw(frame.image, in: all)
        if let next, blend > 0 {
            ctx.setAlpha(blend)
            ctx.draw(next.image, in: all)
            ctx.setAlpha(1)
        }
        // A dark edge at the bottom keeps the caption readable on any photo.
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.62)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(side) * 0.28), end: .zero, options: [])
        }
        let s = Double(side) / 1080
        text(title, size: 44 * s, weight: "Georgia-Bold", at: CGPoint(x: 52 * s, y: 96 * s), in: ctx)
        text((blend > 0.5 ? next : frame)?.caption ?? frame.caption, size: 30 * s, weight: "Georgia", at: CGPoint(x: 52 * s, y: 52 * s), in: ctx)
    }

    private static func text(_ string: String, size: Double, weight: String, at point: CGPoint, in ctx: CGContext) {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 0.95)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
