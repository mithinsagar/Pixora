import SwiftUI
import AppKit
import PixoraCore

/// Drags photos out of any grid into Finder, Messages, Mail and so on: one photo, or everything selected when the drag
/// starts on a selected photo. Run by AppKit rather than SwiftUI's `onDrag` because a drag has to offer copying only:
/// an original must never be moved, or sent to the Trash, from here. With its card or drive disconnected, a photo's
/// small preview goes instead, and the app says so afterwards.
@MainActor
final class TileDragger: NSObject, NSDraggingSource {
    static let shared = TileDragger()
    private weak var model: AppModel?
    private var monitor: Any?
    private var press: (photo: Photo, view: NSView, at: NSPoint)?
    private var carried: [AppModel.DragFile] = []
    /// How many photos in a group are drawn under the pointer. The rest still go, and macOS shows the count.
    private static let drawn = 6
    /// How far the pointer travels before a press on a tile counts as a drag rather than a click.
    private static let threshold: CGFloat = 6

    func start(model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            nonisolated(unsafe) let event = event   // monitors run on the main thread
            let becameDrag = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return becameDrag ? nil : event
        }
    }

    /// True when the event has become a drag and shouldn't carry on to the tile.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            press = nil
            guard let model, !model.isImmersive, model.slideshow == nil, !model.showCommandBar,
                  !event.modifierFlags.contains(.control), let tile = model.tile(at: event) else { break }
            press = (tile.photo, tile.view, event.locationInWindow)
        case .leftMouseDragged:
            guard let p = press else { break }
            let moved = hypot(event.locationInWindow.x - p.at.x, event.locationInWindow.y - p.at.y)
            guard moved >= Self.threshold else { break }
            press = nil
            return begin(p.photo, from: p.view, event: event)
        default:
            press = nil
        }
        return false
    }

    private func begin(_ photo: Photo, from view: NSView, event: NSEvent) -> Bool {
        guard let model else { return false }
        let group = model.dragSelection.contains(photo) ? [photo] + model.dragSelection.filter { $0 != photo } : [photo]
        let files = model.dragFiles(for: group)
        guard !files.isEmpty else { NSSound.beep(); return false }
        carried = files
        let items = files.enumerated().map { i, file -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let shown = i < Self.drawn
            let picture = shown ? (ImageCache.shared.cached(file.photoID) ?? NSWorkspace.shared.icon(forFile: file.url.path)) : nil
            item.setDraggingFrame(view.bounds.offsetBy(dx: CGFloat(min(i, Self.drawn)) * 5, dy: CGFloat(min(i, Self.drawn)) * -5), contents: picture)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = files.count > 1 ? .pile : .none
        #if PIXORA_UI_TESTING
        let offered = (session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let real = offered.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        fputs("REHEARSAL dragging \(offered.count) of \(model.dragSelection.count) selected, \(real) files exist, \(Set(offered.map(\.lastPathComponent)).count) distinct names, \(files.filter(\.isPreview).count) previews, first \(offered.first?.lastPathComponent ?? "nothing"), outside mask \(draggingSession(session, sourceOperationMaskFor: .outsideApplication).rawValue)\n", stderr)
        #endif
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { carried = [] }
        guard operation != [], let first = carried.first else { return }
        let previews = carried.filter(\.isPreview).count
        let text: String
        switch (carried.count, previews) {
        case (1, 0): text = "Copied \(first.url.lastPathComponent)"
        case (1, _): text = "Card not connected, so a small preview was copied"
        case (let n, 0): text = "Copied \(n) photos"
        case (let n, let p) where p == n: text = "Card not connected, so small previews of \(n) photos were copied"
        case (let n, let p): text = "Copied \(n) photos. \(p) are small previews because their card isn't connected"
        }
        model?.toast = Toast(text: text, offersUndo: false)
    }
}

extension AppModel {
    struct DragFile {
        let photoID: Int64
        let url: URL
        let isPreview: Bool
    }

    /// What dragged photos hand over: each original that can be reached, otherwise a copy of its kept preview, named so
    /// nobody mistakes it for the full photo. Private photos have no preview on disk and none is written for them.
    func dragFiles(for photos: [Photo]) -> [DragFile] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("PixoraDrags", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var usedNames = Set<String>()
        return photos.compactMap { photo in
            if let source = source(photo.sourceID), source.isOnline {
                let url = source.url.appendingPathComponent(photo.relPath)
                if fm.fileExists(atPath: url.path) { return DragFile(photoID: photo.id, url: url, isPreview: false) }
            }
            let preview = AppPaths.thumbnail(photoID: photo.id)
            guard photo.id > 0, fm.fileExists(atPath: preview.path) else { return nil }
            // Two photos can share a filename when they came from different folders.
            let base = (photo.filename as NSString).deletingPathExtension
            var name = "\(base) preview.jpg", n = 2
            while !usedNames.insert(name).inserted { name = "\(base) preview \(n).jpg"; n += 1 }
            let url = dir.appendingPathComponent(name)
            // A hard link is instant, which matters for hundreds of photos; the receiver still gets its own copy.
            guard (try? fm.linkItem(at: preview, to: url)) != nil || (try? fm.copyItem(at: preview, to: url)) != nil else { return nil }
            return DragFile(photoID: photo.id, url: url, isPreview: true)
        }
    }
}
