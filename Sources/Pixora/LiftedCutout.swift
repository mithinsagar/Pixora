import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// PNG files for lifted subjects. A drag has to hand over a real file, so one is written to a temporary folder the
/// moment a drag starts, and that folder is emptied before the next. Originals are never involved.
enum CutoutFile {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func temporary(_ image: CGImage, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PixoraCutouts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name) cutout.png")
        guard let data = png(image), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

/// Lies over the lifted subject: dragging from it carries the cutout out to Finder, Messages, Keynote or anywhere.
struct CutoutDragSource: NSViewRepresentable {
    let cutout: CGImage
    let name: String
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.cutout = cutout; view.name = name }

    final class DragView: NSView, NSDraggingSource {
        var cutout: CGImage?
        var name = "Subject"
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDragged(with event: NSEvent) {
            guard let cutout, let url = CutoutFile.temporary(cutout, name: name) else { return }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let scale = min(1, 320 / CGFloat(max(cutout.width, cutout.height)))
            let size = NSSize(width: CGFloat(cutout.width) * scale, height: CGFloat(cutout.height) * scale)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                                  contents: NSImage(cgImage: cutout, size: size))
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
