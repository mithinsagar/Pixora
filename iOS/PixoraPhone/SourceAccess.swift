import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

/// Where the iPhone app's photos come from, and keeping access to them.
///
/// iOS only lets an app read a folder the person picked in Files (a card reader, USB drive, iCloud Drive or
/// "On My iPhone" folder) while it holds that folder's security-scoped access. Pixora saves a bookmark when the
/// folder is added, and on every launch resolves it and starts access again. If the drive is unplugged, the
/// folder stays in the library as "not connected": previews keep working and the person can reconnect it.
///
/// Photos picked from the Photos library and single files picked in Files are copied into Pixora's own
/// "Imported" folder, because iOS gives an app those photos as one-off copies rather than a folder it can
/// re-read. The originals in Photos or Files are never changed.
@MainActor
final class SourceAccess {
    private var accessing: [Int64: URL] = [:]

    /// Pixora's own copies of photos picked from Photos or as single files. Inside the app's private storage.
    static var importedRoot: URL { AppPaths.root.appendingPathComponent("Imported", isDirectory: true) }
    static var fromPhotos: URL { folder("From Photos") }
    static var fromFiles: URL { folder("From Files") }
    private static func folder(_ name: String) -> URL {
        let url = importedRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A source made of Pixora's own copies (not a folder the person picked).
    static func isManaged(_ source: Source) -> Bool { source.path.contains("/Imported/From ") }

    /// Re-open every source: managed folders follow the app container (its path changes between installs), and
    /// picked folders are resolved from their bookmarks with security-scoped access started again.
    func reconnectAll(store: LibraryStore) {
        guard let sources = try? store.sources() else { return }
        for s in sources {
            if Self.isManaged(s) {
                let name = URL(fileURLWithPath: s.path).lastPathComponent
                let now = Self.importedRoot.appendingPathComponent(name, isDirectory: true)
                if now.path != s.path { try? store.relocate(sourceID: s.id, to: now) }
                continue
            }
            guard accessing[s.id] == nil, let bookmark = s.bookmark else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { url.stopAccessingSecurityScopedResource(); continue }
            accessing[s.id] = url
            if stale || url.path != s.path { try? store.relocate(sourceID: s.id, to: url) }
        }
    }

    /// Register a folder the person just picked. Access stays open while the app runs.
    func addPickedFolder(_ url: URL, store: LibraryStore) throws -> Source {
        _ = url.startAccessingSecurityScopedResource()
        let source = try store.addSource(url: url)
        if let old = accessing[source.id], old != url { old.stopAccessingSecurityScopedResource() }
        accessing[source.id] = url
        return source
    }

    /// Point an existing source at the folder the person picked to reconnect it.
    func reconnect(_ source: Source, to url: URL, store: LibraryStore) throws {
        _ = url.startAccessingSecurityScopedResource()
        try store.relocate(sourceID: source.id, to: url)
        if let old = accessing[source.id], old != url { old.stopAccessingSecurityScopedResource() }
        accessing[source.id] = url
    }

    func forget(_ source: Source) {
        accessing.removeValue(forKey: source.id)?.stopAccessingSecurityScopedResource()
    }

    // MARK: Copies from Photos and Files

    /// Copy photos picked in the Photos picker into Pixora's folder. Each is fetched in its original format
    /// (HEIC, JPEG, ProRAW…). Photos already copied before are skipped. Returns how many were new.
    static func copyFromPhotos(_ items: [PhotosPickerItem], progress: @escaping @MainActor (Int) -> Void) async -> (added: Int, failed: Int) {
        let dest = fromPhotos
        var added = 0, failed = 0, done = 0
        for item in items {
            defer { done += 1; progress(done) }
            let tag = item.itemIdentifier.map { stableTag($0) }
            if let tag, (try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.contains(where: { $0.hasPrefix(tag + "_") }) == true { continue }
            do {
                guard let file = try await item.loadTransferable(type: PickedPhotoFile.self) else { failed += 1; continue }
                let name = (tag.map { $0 + "_" } ?? "") + file.url.lastPathComponent
                let target = uniqueURL(dest.appendingPathComponent(name))
                try FileManager.default.moveItem(at: file.url, to: target)
                added += 1
            } catch { failed += 1 }
        }
        return (added, failed)
    }

    /// Copy single photo files picked in Files. The picked files are only read.
    static func copyFiles(_ urls: [URL]) -> (added: Int, failed: Int) {
        let dest = fromFiles
        var added = 0, failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target = dest.appendingPathComponent(url.lastPathComponent)
            if let a = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               let b = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber, a == b { continue }
            do { try FileManager.default.copyItem(at: url, to: uniqueURL(target)); added += 1 } catch { failed += 1 }
        }
        return (added, failed)
    }

    private static func stableTag(_ identifier: String) -> String {
        String(identifier.split(separator: "/").first ?? Substring(identifier)).replacingOccurrences(of: "-", with: "").prefix(12).description
    }

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2... {
            let next = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return url
    }
}

/// A photo from the Photos picker as a file in its original format. The system hands over a temporary file,
/// which is moved somewhere Pixora keeps it before the picker's copy goes away.
struct PickedPhotoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let copy = temp.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedPhotoFile(url: copy)
        }
    }
}
