import SwiftUI
import UIKit
import PixoraCore

/// Decodes and caches photo previews and face crops off the main thread.
///
/// Library photos use the small preview Pixora saved while scanning (so they show even when the card or drive is
/// unplugged) and fall back to the original. Private Space images exist only in memory while it is unlocked:
/// they are registered on unlock and purged the moment it locks.
final class PhotoImages: @unchecked Sendable {
    static let shared = PhotoImages()
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var privatePreviews: [Int64: Data] = [:]
    private var privateFaces: [Int64: Data] = [:]

    init() { cache.countLimit = 600 }

    // MARK: Private Space (memory only)

    func registerPrivate(photoID: Int64, jpeg: Data?, faces: [(Int64, Data?)]) {
        lock.withLock {
            privatePreviews[photoID] = jpeg
            for (id, d) in faces { privateFaces[id] = d }
        }
    }

    func purgePrivate() {
        lock.withLock { privatePreviews = [:]; privateFaces = [:] }
        cache.removeAllObjects()   // private images were cached alongside; drop everything to be sure
    }

    func forget(photoIDs: [Int64]) {
        for id in photoIDs { for k in ["t", "f"] { cache.removeObject(forKey: "\(k)\(id)" as NSString) } }
    }

    func invalidateFaces() { cache.removeAllObjects() }

    // MARK: Loading

    /// Grid-sized image: the saved preview, or a downscaled original.
    func thumbnail(_ photo: Photo, sourceRoot: URL?) async -> UIImage? {
        let key = "t\(photo.id)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let priv = photo.id < 0 ? lock.withLock { privatePreviews[photo.id] } : nil
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            if photo.id < 0 { return priv.flatMap { UIImage(data: $0)?.preparingForDisplay() } }
            let preview = AppPaths.thumbnail(photoID: photo.id)
            if let img = UIImage(contentsOfFile: preview.path) { return img.preparingForDisplay() ?? img }
            guard let root = sourceRoot, let cg = ImageLoader.image(at: root.appendingPathComponent(photo.relPath), maxPixel: 640) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Screen-sized image for the viewer and slideshows. `isPreview` is true when the original isn't on this
    /// device (unplugged drive, or a photo that only has a saved preview here).
    func full(_ photo: Photo, sourceRoot: URL?, maxPixel: Int = 2800) async -> (image: UIImage, isPreview: Bool)? {
        let key = "f\(photo.id)" as NSString
        if let hit = cache.object(forKey: key) { return (hit, false) }
        if photo.id < 0 {
            guard let img = await thumbnail(photo, sourceRoot: nil) else { return nil }
            return (img, false)   // Private Space keeps a large encrypted preview; it is the private copy
        }
        let original: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let root = sourceRoot else { return nil }
            let url = root.appendingPathComponent(photo.relPath)
            guard FileManager.default.fileExists(atPath: url.path), let cg = ImageLoader.image(at: url, maxPixel: maxPixel) else { return nil }
            return UIImage(cgImage: cg).preparingForDisplay()
        }.value
        if let original { cache.setObject(original, forKey: key); return (original, false) }
        guard let preview = await thumbnail(photo, sourceRoot: nil) else { return nil }
        return (preview, true)
    }

    func face(_ faceID: Int64, store: LibraryStore) async -> UIImage? {
        let key = "c\(faceID)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let priv = faceID < 0 ? lock.withLock { privateFaces[faceID] } : nil
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            let data = faceID < 0 ? priv : (try? store.faceThumb(id: faceID)) ?? nil
            return data.flatMap { UIImage(data: $0)?.preparingForDisplay() }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

// MARK: - Views

/// One square photo tile. Shows a soft placeholder until the preview is decoded.
struct PhotoTile: View {
    @Environment(PhoneModel.self) private var model
    let photo: Photo
    var selected: Bool? = nil
    var showsOffline = true
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Rectangle().fill(Palette.rule.opacity(0.45))
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Palette.onSafelight : .white, selected ? Palette.safelight : .black.opacity(0.25))
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if model.favorites.contains(photo.id) { Image(systemName: "heart.fill") }
                    if showsOffline && model.isOffline(photo) { Image(systemName: "externaldrive.badge.xmark") }
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .padding(6)
                .accessibilityHidden(true)
            }
            .overlay { if selected == true { Rectangle().strokeBorder(Palette.safelight, lineWidth: 3) } }
            .contentShape(Rectangle())
            .task(id: photo.id) {
                let img = await PhotoImages.shared.thumbnail(photo, sourceRoot: model.source(photo.sourceID)?.url)
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
            .accessibilityElement()
            .accessibilityLabel(model.describe(photo))
            .accessibilityAddTraits(selected == true ? [.isImage, .isSelected] : .isImage)
    }
}

/// A round face crop.
struct FaceImage: View {
    @Environment(PhoneModel.self) private var model
    let faceID: Int64?
    var size: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Palette.rule.opacity(0.6))
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(Palette.ink2.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: faceID) {
            guard let faceID else { image = nil; return }
            let img = await PhotoImages.shared.face(faceID, store: model.store)
            withAnimation(.easeOut(duration: 0.15)) { image = img }
        }
        .accessibilityHidden(true)
    }
}

/// A grid of photos with optional selection. Three columns, hairline gaps, like the Photos app.
struct PhotoGrid: View {
    let photos: [Photo]
    var selection: Binding<Set<Int64>>? = nil
    var columns = 3
    var onOpen: (Photo) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
            ForEach(photos) { p in
                let isOn = selection?.wrappedValue.contains(p.id)
                PhotoTile(photo: p, selected: isOn)
                    .onTapGesture {
                        if let selection {
                            if selection.wrappedValue.contains(p.id) { selection.wrappedValue.remove(p.id) } else { selection.wrappedValue.insert(p.id) }
                        } else { onOpen(p) }
                    }
                    .accessibilityAction { onOpen(p) }
            }
        }
    }
}
