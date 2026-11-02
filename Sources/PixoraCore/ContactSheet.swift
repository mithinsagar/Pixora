import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Printable proof sheet: a grid of frames with frame numbers, filenames and the people in each, A4 pages.
public enum ContactSheet {
    public struct Frame {
        public let photo: Photo
        public let caption: String
        public init(photo: Photo, caption: String) { self.photo = photo; self.caption = caption }
    }

    /// Renders from Pixora's cached thumbnails, so it works with the card ejected.
    /// `original` supplies an image when no preview is stored (previews switched off): typically the original file.
    public static func render(_ frames: [Frame], title: String, subtitle: String, watermark: String?, to url: URL,
                              columns: Int = 4, rows: Int = 5, original: ((Photo) -> CGImage?)? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)   // A4 in points
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Pixora"] as CFDictionary) else {
            throw DatabaseError(message: "Could not create the PDF file.")
        }
        let margin: CGFloat = 36, header: CGFloat = 64, gap: CGFloat = 10, captionH: CGFloat = 28
        let perPage = columns * rows
        let pages = max(1, Int(ceil(Double(frames.count) / Double(perPage))))
        let cellW = (box.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (box.height - margin * 2 - header - gap * CGFloat(rows - 1)) / CGFloat(rows)

        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
            draw(title, font: serif(20), at: CGPoint(x: margin, y: box.height - margin - 22), in: ctx)
            draw("\(subtitle)  ·  page \(page + 1) of \(pages)", font: mono(8), color: CGColor(gray: 0.4, alpha: 1),
                 at: CGPoint(x: margin, y: box.height - margin - 40), in: ctx)
            for slot in 0..<perPage {
                let i = page * perPage + slot
                guard i < frames.count else { break }
                let col = slot % columns, row = slot / columns
                let x = margin + CGFloat(col) * (cellW + gap)
                let yTop = box.height - margin - header - CGFloat(row) * (cellH + gap)
                let imageRect = CGRect(x: x, y: yTop - (cellH - captionH), width: cellW, height: cellH - captionH)
                ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(imageRect)
                let stored = CGImageSourceCreateWithURL(AppPaths.thumbnail(photoID: frames[i].photo.id) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                if let img = stored ?? original?(frames[i].photo) {
                    let s = min(imageRect.width / CGFloat(img.width), imageRect.height / CGFloat(img.height))
                    let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
                    ctx.draw(img, in: CGRect(x: imageRect.midX - w / 2, y: imageRect.midY - h / 2, width: w, height: h))
                }
                draw(String(format: "▸%04d  %@", i + 1, frames[i].photo.filename), font: mono(6.5), color: CGColor(red: 0.7, green: 0.28, blue: 0.1, alpha: 1),
                     at: CGPoint(x: x, y: imageRect.minY - 10), in: ctx, maxWidth: cellW)
                draw(frames[i].caption, font: sans(6.5), color: CGColor(gray: 0.25, alpha: 1), at: CGPoint(x: x, y: imageRect.minY - 20), in: ctx, maxWidth: cellW)
            }
            if let watermark, !watermark.isEmpty {
                ctx.saveGState()
                ctx.translateBy(x: box.midX, y: box.midY); ctx.rotate(by: .pi / 5)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: watermark, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: serif(64),
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 0.08)]))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: -w / 2, y: -20)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func serif(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Georgia-Bold" as CFString, size, nil) }
    private static func sans(_ size: CGFloat) -> CTFont { CTFontCreateUIFontForLanguage(.system, size, nil)! }
    private static func mono(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Menlo" as CFString, size, nil) }

    private static func draw(_ text: String, font: CTFont, color: CGColor = CGColor(gray: 0.1, alpha: 1), at p: CGPoint, in ctx: CGContext, maxWidth: CGFloat? = nil) {
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color]))
        if let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth),
           let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end,
                CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))) {
            line = truncated
        }
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
