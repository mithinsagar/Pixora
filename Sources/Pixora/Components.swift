import SwiftUI
import AppKit
import ImageIO
import PixoraCore

/// Loads photo thumbnails (cached on disk during the scan, so browsing works even with the card ejected)
/// and face crops (stored in the library), off the main thread.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let photos = NSCache<NSNumber, NSImage>()
    private let faces = NSCache<NSNumber, NSImage>()
    init() { photos.countLimit = 1500; faces.countLimit = 3000 }

    // Private Space images live only in memory, under stand-in (negative) ids, and are purged on lock.
    private let privateLock = NSLock()
    private var privateKeys: [NSNumber] = []

    func registerPrivate(photoID: Int64, jpeg: Data?, faces: [(Int64, Data?)]) {
        privateLock.withLock {
            if let jpeg, let cg = Self.decoded(CGImageSourceCreateWithData(jpeg as CFData, nil), maxPixel: 640) {
                photos.setObject(Self.wrap(cg), forKey: photoID as NSNumber); privateKeys.append(photoID as NSNumber)
            }
            for (fid, data) in faces {
                if let data, let cg = Self.decoded(CGImageSourceCreateWithData(data as CFData, nil), maxPixel: 320) {
                    self.faces.setObject(Self.wrap(cg), forKey: fid as NSNumber); privateKeys.append(fid as NSNumber)
                }
            }
        }
    }

    func purgePrivate() {
        privateLock.withLock {
            for k in privateKeys { photos.removeObject(forKey: k); faces.removeObject(forKey: k) }
            privateKeys.removeAll()
        }
    }

    func forget(photoIDs: [Int64]) { for id in photoIDs { photos.removeObject(forKey: id as NSNumber) } }
    /// The thumbnail if it's in memory, without waiting.
    func cached(_ id: Int64) -> NSImage? { photos.object(forKey: id as NSNumber) }

    func photoThumb(_ photo: Photo, sourceRoot: URL?) async -> NSImage? {
        if let hit = photos.object(forKey: photo.id as NSNumber) { return hit }
        if photo.id < 0 {
            // Private photo evicted from memory: decode from the original if connected, never touch disk caches.
            return await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let root = sourceRoot, let cg = ImageLoader.image(at: root.appendingPathComponent(photo.relPath), maxPixel: 640) else { return nil }
                return Self.wrap(cg)
            }.value
        }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = AppPaths.thumbnail(photoID: photo.id)
            if let cg = Self.decoded(CGImageSourceCreateWithURL(url as CFURL, nil), maxPixel: 640) { return Self.wrap(cg) }
            // No cached thumbnail (e.g. cache cleared): rebuild from the original if it is connected.
            guard let root = sourceRoot, let cg = ImageLoader.image(at: root.appendingPathComponent(photo.relPath), maxPixel: 640) else { return nil }
            // Previews off in Settings: show it, but don't keep a copy.
            if AppSettings.keepPreviews, let data = ImageLoader.jpegData(cg, quality: 0.8) { try? data.write(to: url, options: .atomic) }
            return Self.wrap(cg)
        }.value
        if let image { photos.setObject(image, forKey: photo.id as NSNumber) }
        return image
    }

    func faceThumb(_ faceID: Int64, store: LibraryStore) async -> NSImage? {
        if let hit = faces.object(forKey: faceID as NSNumber) { return hit }
        if faceID < 0 { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = try? store.faceThumb(id: faceID) else { return nil }
            return Self.decoded(CGImageSourceCreateWithData(data as CFData, nil), maxPixel: 320).map(Self.wrap)
        }.value
        if let image { faces.setObject(image, forKey: faceID as NSNumber) }
        return image
    }

    /// Fully decoded bitmap, made off the main thread. (NSImage(contentsOf:) decodes lazily — on the main
    /// thread, at draw time, in the middle of a scroll — which is what made scrolling stutter.)
    nonisolated static func decoded(_ src: CGImageSource?, maxPixel: Int) -> CGImage? {
        guard let src else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    nonisolated static func wrap(_ cg: CGImage) -> NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }

    private let hiRes = NSCache<NSString, NSImage>()

    /// A sharp face crop from the original photo (for covers and big face views), cached on disk.
    /// Falls back to the stored thumbnail when the card or drive isn't connected.
    func faceHiRes(_ faceID: Int64, side: Int, store: LibraryStore, sourceRoot: @escaping @Sendable (Int64) -> URL?) async -> NSImage? {
        let key = "\(faceID)-\(side)" as NSString
        if let hit = hiRes.object(forKey: key) { return hit }
        if faceID < 0 { return nil }   // private faces: no disk-cached crops
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            let file = AppPaths.faceCrops.appendingPathComponent("\(faceID)-\(side).jpg")
            if let cg = Self.decoded(CGImageSourceCreateWithURL(file as CFURL, nil), maxPixel: side) { return Self.wrap(cg) }
            guard let face = try? store.face(id: faceID), let photo = try? store.photos(ids: [face.photoID]).first,
                  let root = sourceRoot(photo.sourceID),
                  let crop = ImageLoader.faceCrop(photoURL: root.appendingPathComponent(photo.relPath), rect: face.rect, side: side) else { return nil }
            if let data = ImageLoader.jpegData(crop, quality: 0.88) { try? data.write(to: file, options: .atomic) }
            return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        }.value
        if let image { hiRes.setObject(image, forKey: key) }
        return image
    }

    func invalidateFaces() { faces.removeAllObjects(); hiRes.removeAllObjects() }
}

struct FaceImage: View {
    @Environment(AppModel.self) private var model
    let faceID: Int64?
    var size: CGFloat = 56
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.rule
            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.medium).scaledToFill()
            }
            else { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(Palette.ink2) }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: faceID) {
            guard let faceID else { image = nil; return }
            image = await ImageCache.shared.faceThumb(faceID, store: model.store)
            // Big faces (covers, review): swap in a sharp crop from the original.
            if size >= 96 {
                let roots = Dictionary(uniqueKeysWithValues: model.sources.filter(\.isOnline).map { ($0.id, $0.url) })
                if let sharp = await ImageCache.shared.faceHiRes(faceID, side: Int(size * 2), store: model.store, sourceRoot: { roots[$0] }) {
                    image = sharp
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A face crop you can hover (it lifts and glows) and drag onto a person in the sidebar to assign it.
struct InteractiveFace: View {
    let faceID: Int64
    var size: CGFloat = 84
    var body: some View {
        FaceImage(faceID: faceID, size: size)
            .hoverLift(scale: 1.07, radius: 10, glow: true)
            .onDrag { NSItemProvider(object: "pixora-face:\(faceID)" as NSString) }
    }
}

/// A person's face as a portrait tile. Certain matches get a solid ring; uncertain ones a dashed ring and "?",
/// so certainty is never conveyed by colour alone.
struct FaceBadge: View {
    let faceID: Int64?
    var size: CGFloat = 24
    var state: FaceState = .confirmed
    var body: some View {
        FaceImage(faceID: faceID, size: size, shape: AnyShape(Circle()))
            .overlay(
                Circle().strokeBorder(state.isCertain ? Color.white.opacity(0.9) : Color.yellow,
                                      style: StrokeStyle(lineWidth: 1.5, dash: state.isCertain ? [] : [3, 2]))
            )
            .overlay(alignment: .bottomTrailing) {
                if !state.isCertain {
                    Text("?").font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: size * 0.5, height: size * 0.5).background(Circle().fill(Color.yellow)).offset(x: 3, y: 3)
                }
            }
    }
}

struct PersonChip: View {
    let person: Person
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            FaceImage(faceID: person.coverFaceID, size: 26, shape: AnyShape(Circle()))
            Text(person.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.ink2)
                .accessibilityLabel("Remove \(person.displayName) from selection")
                .help("Remove \(person.displayName)")
        }
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
        .background(Capsule().fill(Palette.safelight.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Palette.safelight.opacity(0.7), lineWidth: 1))
        .foregroundStyle(Palette.ink)
    }
}

/// Selectable portrait in the people strip / grid.
struct PersonTile: View {
    let person: Person
    var selected: Bool
    var size: CGFloat = 76
    var body: some View {
        VStack(spacing: 6) {
            FaceImage(faceID: person.coverFaceID, size: size, shape: AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(selected ? Palette.safelight : .clear, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                            .foregroundStyle(Palette.onSafelight, Palette.safelight).offset(x: 5, y: -5)
                    }
                }
            Text(person.displayName).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(person.isNamed ? Palette.ink : Palette.ink2).lineLimit(1).frame(width: size + 12)
        }
        .contentShape(Rectangle())
        .hoverLift(scale: 1.06, radius: size * 0.22, glow: !selected)
        .help("\(person.displayName) · \(Format.count(person.photoCount, "photo"))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.displayName), \(person.photoCount) photos")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Extra per-photo context for a tile in Find.
struct TileInfo {
    var matches: [PersonMatch] = []
    var isBest = false
    /// >1 when this tile stands for a stacked burst.
    var burstCount = 0
    var burstExpanded = false
    /// Unstacked: this frame's position in its burst, e.g. 2 of 4 (0 = not in a burst).
    var burstPosition = 0
    var burstSize = 0
    var eyesClosed = false
    var soft = false
}

/// A frame on the contact sheet: thumbnail, edge-printed frame number and filename, matched faces, quality
/// badges. Hover lifts it and reveals who's in it plus quick actions.
struct PhotoTile: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    var index: Int
    var info = TileInfo()
    var isInspected = false
    var isIncluded: Bool? = nil
    var onToggleInclude: (() -> Void)? = nil
    var onToggleBurst: (() -> Void)? = nil
    var onView: (() -> Void)? = nil
    var selecting = false
    /// Justified layout: the exact size of the picture area (keeps the photo's real shape).
    var imageSize: CGSize? = nil
    @State private var image: CGImage?
    @State private var hovering = false
    @State private var anchor: NSView?
    private var corner: CGFloat { CGFloat(ThemeManager.shared.tileCorner) }

    private var fileURL: URL? {
        guard let s = model.source(photo.sourceID), s.isOnline else { return nil }
        return s.url.appendingPathComponent(photo.relPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                // Stacked burst: hint of frames behind.
                if info.burstCount > 1 && !info.burstExpanded {
                    RoundedRectangle(cornerRadius: corner).fill(Palette.rule).offset(x: 5, y: -5).opacity(0.7)
                    RoundedRectangle(cornerRadius: corner).fill(Palette.rule.opacity(0.8)).offset(x: 2.5, y: -2.5)
                }
                ZStack {
                    Rectangle().fill(Palette.rule.opacity(0.5))
                    // A ready-decoded CGImage: SwiftUI just uploads it, no per-frame image conversion.
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                            .aspectRatio(contentMode: imageSize == nil ? .fit : .fill)
                    }
                    else { Image(systemName: "photo").foregroundStyle(Palette.ink2) }
                }
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay(alignment: .bottom) { if hovering { hoverOverlay.transition(.opacity) } }
            }
            .aspectRatio(imageSize == nil ? 1 : nil, contentMode: .fit)
            .frame(width: imageSize?.width, height: imageSize?.height)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if !hovering && ThemeManager.shared.showFaceBadges {
                    HStack(spacing: -6) {
                        ForEach(info.matches, id: \.faceID) { m in FaceBadge(faceID: m.faceID, size: 24, state: m.state) }
                    }.padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !hovering && model.favorites.contains(photo.id) {
                    Image(systemName: "heart.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.pink.opacity(0.9))).padding(6)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .animation(Motion.pop, value: model.favorites.contains(photo.id))
            .overlay(alignment: .topLeading) { includeToggle }
            .overlay(alignment: .topTrailing) { if ThemeManager.shared.showQualityBadges { badges.padding(6) } }
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(isInspected || (selecting && isIncluded == true) ? Palette.safelight : .clear,
                                                                    lineWidth: selecting && isIncluded == true ? 3 : 2))
            .opacity(isIncluded == false ? (selecting ? 0.75 : 0.5) : 1)
            .hoverLift(scale: 1.04, radius: corner, glow: true)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .background(ShareAnchor(view: $anchor))
            .onChange(of: anchor) { _, v in model.registerTile(photo, v) }
            .onDisappear { model.unregisterTile(photo.id, anchor) }
            if ThemeManager.shared.showFilenames {
                HStack(spacing: 6) {
                    EdgeLabel(String(format: "▸%04d", index + 1), color: Palette.safelight)
                    EdgeLabel(photo.filename)
                    if !photo.siblings.isEmpty { EdgeLabel("+RAW") }
                }
                .frame(width: imageSize?.width, alignment: .leading)
                .clipped()
            }
        }
        .task(id: photo.id) {
            image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var includeToggle: some View {
        if let isIncluded, let onToggleInclude {
            Button(action: onToggleInclude) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).symbolRenderingMode(.palette)
                    .foregroundStyle(isIncluded ? Palette.onSafelight : Color.white, isIncluded ? Palette.safelight : Color.black.opacity(0.35))
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain).padding(6)
            .accessibilityLabel(isIncluded ? "Included in export" : "Excluded from export")
            .help(isIncluded ? "Exclude from export" : "Include in export")
        }
    }

    @ViewBuilder private var badges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if info.isBest { ShotBadge(icon: "star.fill", text: "Best", tint: Palette.safelight, fg: Palette.onSafelight).help("Among the sharpest, most open-eyed shots of them") }
            if info.burstSize > 1 && info.burstCount <= 1 {
                ShotBadge(icon: "square.stack.3d.up", text: "Burst \(info.burstPosition)/\(info.burstSize)")
                    .help("Frame \(info.burstPosition) of \(info.burstSize) shot within 2 seconds")
            }
            if info.burstCount > 1 {
                Button { onToggleBurst?() } label: {
                    ShotBadge(icon: info.burstExpanded ? "rectangle.compress.vertical" : "square.stack.3d.up.fill",
                              text: info.burstExpanded ? "Collapse" : "×\(info.burstCount)")
                }.buttonStyle(.plain).help(info.burstExpanded ? "Stack this burst again" : "Burst of \(info.burstCount) frames — showing the best. Click to see all.")
            }
            if info.eyesClosed { ShotBadge(icon: "eye.slash", text: "Eyes").help("Eyes may be closed") }
            if info.soft { ShotBadge(icon: "camera.metering.unknown", text: "Soft").help("Softer than usual for this person — check focus") }
        }
    }

    private var hoverOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            let names = info.matches.compactMap { m in model.person(m.personID)?.displayName.appending(m.state.isCertain ? "" : "?") }
            if !names.isEmpty {
                Text(names.joined(separator: ", ")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let d = photo.takenAt { Text(Format.day.string(from: d)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).fixedSize() }
                Spacer()
                if photo.id > 0 {
                    let favorite = model.favorites.contains(photo.id)
                    quickButton(favorite ? "heart.fill" : "heart", favorite ? "Remove from favorites" : "Add to favorites", bounce: favorite) {
                        model.toggleFavorite([photo])
                        Haptics.tick()
                    }
                }
                if let onView { quickButton("arrow.up.left.and.arrow.down.right", "View full photo") { onView() } }
                quickButton("square.and.arrow.up", "Share") { model.share([photo], from: anchor) }
                quickButton("folder", "Show in Finder") { if let u = fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                quickButton("info.circle", "Details") { model.inspectedPhotoID = photo.id; model.showInspector = true }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom))
    }

    private func quickButton(_ icon: String, _ label: String, bounce: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                .symbolEffect(.bounce, value: bounce)
                .background(Circle().fill(.white.opacity(0.18))).foregroundStyle(.white)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    @ViewBuilder private var contextMenu: some View {
        if let onView { Button("View Full Photo", action: onView) }
        Button("Details") { model.inspectedPhotoID = photo.id; model.showInspector = true }
        Button("Share…") { model.share([photo], from: anchor) }
        Button("Show in Finder") { if let u = fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }.disabled(fileURL == nil)
        if let onToggleInclude, let isIncluded { Button(isIncluded ? "Exclude from Export" : "Include in Export", action: onToggleInclude) }
        if info.burstCount > 1, let onToggleBurst { Button(info.burstExpanded ? "Stack Burst" : "Show All \(info.burstCount) Frames", action: onToggleBurst) }
        if photo.id > 0 {
            Button(model.favorites.contains(photo.id) ? "Remove from Favorites" : "Add to Favorites ♥") { model.toggleFavorite([photo]) }
        }
        Divider()
        if photo.id < 0 { Button("Move to Library") { model.moveToLibrary(photos: [photo]) } }
        else if model.canMakePrivate { Button("Make Private") { model.makePrivate(photos: [photo]) } }
    }

    private var accessibilityText: String {
        var parts = [photo.filename]
        if let d = photo.takenAt { parts.append(Format.day.string(from: d)) }
        let names = info.matches.map { m in (model.person(m.personID)?.displayName ?? "") + (m.state.isCertain ? "" : " (uncertain)") }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if model.favorites.contains(photo.id) { parts.append("favorite") }
        if info.isBest { parts.append("best shot") }
        if info.eyesClosed { parts.append("eyes may be closed") }
        if info.soft { parts.append("soft focus") }
        if info.burstCount > 1 { parts.append("burst of \(info.burstCount)") }
        if info.burstSize > 1 && info.burstCount <= 1 { parts.append("burst frame \(info.burstPosition) of \(info.burstSize)") }
        return parts.joined(separator: ", ")
    }
}

struct GridEntry: Identifiable {
    let index: Int
    let photo: Photo
    let info: TileInfo
    var id: Int64 { photo.id }
}

struct DayGroup: Identifiable {
    let title: String
    var entries: [GridEntry]
    var id: String { title + "\(entries.first?.index ?? 0)" }
}

/// Grid of photos grouped by day, contact-sheet style, with an optional "check before sending" section.
struct PhotoGrid: View {
    @Environment(AppModel.self) private var model
    let items: [(photo: Photo, info: TileInfo)]
    var weaker: [(photo: Photo, info: TileInfo, reason: String)] = []
    @Binding var inspected: Int64?
    var excluded: Set<Int64>? = nil
    var onToggleExport: ((Int64) -> Void)? = nil
    var onToggleBurst: ((Int64) -> Void)? = nil
    /// Select mode: clicks pick photos (`selected`) instead of opening them.
    var selecting = false
    var selected: Set<Int64>? = nil
    var onToggleSelect: ((Int64) -> Void)? = nil
    /// What a click does outside Select mode (default: show details in the inspector).
    var onOpen: ((Int64) -> Void)? = nil
    var viewerTitle = "Photos"
    var headerBackground: Color? = nil
    /// Sections other than by day, for photos in an order of their own.
    var groupTitle: ((Photo) -> String)? = nil
    @AppStorage("tileSize") private var tileSize: Double = 190

    var body: some View {
        let groups = grouped
        let photos = items.map(\.photo) + weaker.map(\.photo)   // once per render, not once per tile
        GeometryReader { geo in
            let width = max(200, geo.size.width - 48)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(Self.rows(group.entries, width: width, target: tileSize)) { row in
                                HStack(alignment: .top, spacing: Self.gap) {
                                    ForEach(row.cells, id: \.entry.id) { cell in tile(cell.entry, photos: photos, size: cell.size) }
                                }
                                .scrollEntrance()
                            }
                        } header: { header(group.title, count: group.entries.count) }
                    }
                    if !weaker.isEmpty {
                        Section {
                            Text("Kept here instead of removed: eyes may be closed, or softer focus than usual. They start out of the export — tick any you want.")
                                .font(.callout).foregroundStyle(Palette.ink2)
                            let entries = weaker.enumerated().map { i, w in GridEntry(index: items.count + i, photo: w.photo, info: w.info) }
                            ForEach(Self.rows(entries, width: width, target: tileSize)) { row in
                                HStack(alignment: .top, spacing: Self.gap) {
                                    ForEach(row.cells, id: \.entry.id) { cell in
                                        VStack(alignment: .leading, spacing: 3) {
                                            tile(cell.entry, photos: photos, size: cell.size)
                                            Text(weaker.first { $0.photo.id == cell.entry.id }?.reason ?? "").font(.caption2).foregroundStyle(Palette.ink2)
                                                .lineLimit(1).frame(width: cell.size.width, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        } header: { header("Check before sending", count: weaker.count, icon: "eye.trianglebadge.exclamationmark") }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .onChange(of: picked, initial: true) { _, photos in model.dragSelection = photos }
        .onDisappear { model.dragSelection = [] }
    }

    /// The photos picked in Select mode, in grid order.
    private var picked: [Photo] {
        guard selecting else { return [] }
        let all = items.map(\.photo) + weaker.map(\.photo)
        if let selected { return all.filter { selected.contains($0.id) } }
        if let excluded { return all.filter { !excluded.contains($0.id) } }
        return []
    }

    static var gap: CGFloat { CGFloat(ThemeManager.shared.gridGap) }

    struct Cell { let entry: GridEntry; let size: CGSize }
    struct Row: Identifiable { let cells: [Cell]; var id: Int64 { cells.first?.entry.id ?? 0 } }

    /// Justified rows: photos keep their real shape; each full row is scaled to fill the width exactly.
    static func rows(_ entries: [GridEntry], width: CGFloat, target: Double) -> [Row] {
        let targetH = CGFloat(target)
        var rows: [Row] = [], current: [(GridEntry, CGFloat)] = [], sum: CGFloat = 0
        func aspect(_ p: Photo) -> CGFloat {
            guard let w = p.width, let h = p.height, w > 0, h > 0 else { return 1.5 }
            return min(3, max(0.4, CGFloat(w) / CGFloat(h)))
        }
        func flush(fill: Bool) {
            guard !current.isEmpty else { return }
            let gaps = gap * CGFloat(current.count - 1)
            var h = (width - gaps) / sum
            if !fill { h = min(h, targetH) }   // last row keeps the normal height
            rows.append(Row(cells: current.map { Cell(entry: $0.0, size: CGSize(width: ($0.1 * h).rounded(.down), height: h.rounded())) }))
            current = []; sum = 0
        }
        for e in entries {
            let a = aspect(e.photo)
            current.append((e, a)); sum += a
            if sum * targetH + gap * CGFloat(current.count - 1) >= width { flush(fill: true) }
        }
        flush(fill: false)
        return rows
    }

    private func tile(_ entry: GridEntry, photos: [Photo], size: CGSize? = nil) -> some View {
        let id = entry.photo.id
        let included: Bool? = selected.map { $0.contains(id) } ?? excluded.map { !$0.contains(id) }
        let toggle: (() -> Void)? = selected != nil ? onToggleSelect.map { f in { f(id) } } : onToggleExport.map { f in { f(id) } }
        let burstToggle: (() -> Void)? = onToggleBurst.map { f in { f(id) } }
        let title = viewerTitle
        return PhotoTile(photo: entry.photo, index: entry.index, info: entry.info, isInspected: !selecting && inspected == id,
                         isIncluded: (selected != nil && !selecting) ? nil : included, onToggleInclude: toggle, onToggleBurst: burstToggle,
                         onView: { model.openViewer(photos, at: id, title: title) }, selecting: selecting, imageSize: size)
            .onTapGesture {
                if selecting { toggle?() }
                else if let onOpen { onOpen(id) }
                else { inspected = id; model.showInspector = true }
            }
            .accessibilityAction(named: selecting ? "Select" : "Open") {
                if selecting { toggle?() } else if let onOpen { onOpen(id) } else { inspected = id; model.showInspector = true }
            }
    }

    private func header(_ title: String, count: Int, icon: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(Palette.safelight) }
            Text(title).font(Typography.display(17))
            EdgeLabel(Format.count(count, "frame"))
            Spacer()
        }
        .padding(.vertical, 6)
        .background(headerBackground ?? Palette.canvas.opacity(0.94))
    }

    private var grouped: [DayGroup] {
        var out: [DayGroup] = []
        for (i, item) in items.enumerated() {
            let title = groupTitle?(item.photo) ?? item.photo.takenAt.map { Format.day.string(from: $0) } ?? "No date"
            let entry = GridEntry(index: i, photo: item.photo, info: item.info)
            if out.last?.title == title { out[out.count - 1].entries.append(entry) } else { out.append(DayGroup(title: title, entries: [entry])) }
        }
        return out
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(Palette.ink2)
            Text(title).font(Typography.display(22))
            Text(message).font(.callout).foregroundStyle(Palette.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let action { Button(action.label, action: action.run).buttonStyle(PrimaryButtonStyle()).padding(.top, 4) }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small banner for honest caveats (uncertain matches, offline sources, basic mode).
struct Notice: View {
    let symbol: String
    let text: String
    var actions: [(String, () -> Void)] = []
    var lines = 2
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.safelight)
            // Capped at two lines: an unbounded wrapping Text inflates the window's minimum height.
            Text(text).font(.callout).foregroundStyle(Palette.ink).lineLimit(lines).truncationMode(.tail).help(text)
            Spacer(minLength: 8)
            ForEach(actions.indices, id: \.self) { i in Button(actions[i].0, action: actions[i].1).controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.safelight.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.safelight.opacity(0.3)))
    }
}

/// Shown when faces were analysed by an older model than the one now installed.
struct UpgradeNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.needsReanalysis {
            Notice(symbol: "sparkles",
                   text: "Better face model installed. \(model.stats.facesFromOtherEmbedder) faces from the old model are ignored until you re-analyse.",
                   actions: [("Re-analyse…", { model.reanalyseLibrary() })])
        }
    }
}

/// Actions for a picked set of photos: AirDrop/Share, drag out, send to a linked contact, contact sheet, copy.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let selected: [Photo]
    let total: Int
    var person: Person? = nil
    var title = "Selected photos"
    let selectAll: () -> Void
    let selectNone: () -> Void
    /// Picks only the favorites among these photos; nil when there are none.
    var selectFavorites: (() -> Void)? = nil
    let done: () -> Void
    @State private var anchor: NSView?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selected.count)").font(.system(size: 20, weight: .semibold, design: .serif)).monospacedDigit()
                .contentTransition(.numericText()).animation(.snappy, value: selected.count)
            EdgeLabel("of \(total) selected")
            Button("Select All", action: selectAll).controlSize(.small)
            Button("None", action: selectNone).controlSize(.small).disabled(selected.isEmpty)
            if let selectFavorites {
                Button(action: selectFavorites) { Label("Favorites", systemImage: "heart.fill") }.controlSize(.small)
                    .help("Select only your favorites, ready to copy")
            }
            Spacer()
            Button { model.toggleFavorite(selected) } label: {
                Label("Favorite", systemImage: !selected.isEmpty && selected.allSatisfy { model.favorites.contains($0.id) } ? "heart.fill" : "heart")
            }.disabled(selected.isEmpty).help("Add these to your favorites, or remove them if they all are already")
            DragOutHandle(urls: { model.fileURLs(for: selected) }, label: "Drag \(selected.count)").fixedSize()
            Button { model.share(selected, from: anchor) } label: { Label("AirDrop / Share", systemImage: "square.and.arrow.up") }
                .background(ShareAnchor(view: $anchor)).disabled(selected.isEmpty)
            if let person, !person.contactHandles.isEmpty {
                Menu {
                    if person.contactHandles.contains(where: { !$0.contains("@") }) { Button("Messages") { model.send(selected, to: person, via: .composeMessage) } }
                    if person.contactHandles.contains(where: { $0.contains("@") }) { Button("Mail") { model.send(selected, to: person, via: .composeEmail) } }
                    Button("AirDrop") { model.send(selected, to: person, via: .sendViaAirDrop) }
                } label: { Label("Send to \(person.displayName)", systemImage: "paperplane") }
                .fixedSize().disabled(selected.isEmpty)
            }
            Button { model.makeContactSheet(selected, title: title) } label: { Label("Contact Sheet", systemImage: "doc.richtext") }
                .disabled(selected.isEmpty)
            if model.canMakePrivate {
                Button { model.makePrivate(photos: selected); selectNone() } label: { Label("Make Private", systemImage: "lock") }
                    .disabled(selected.isEmpty).help("Hide these from the library; they’ll only show in Private Space")
            }
            Button { model.requestExport(photos: selected) } label: {
                Label("Copy to Folder…", systemImage: "square.and.arrow.down.on.square").lineLimit(1)
            }
            .buttonStyle(PrimaryButtonStyle()).fixedSize().disabled(selected.isEmpty)
            Button("Done", action: done).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.safelight).frame(height: 2) }
    }
}

/// The "Select" toggle used in headers.
struct SelectToggle: View {
    @Binding var selecting: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { selecting.toggle() } } label: {
            Label(selecting ? "Selecting…" : "Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(selecting ? Palette.safelight : Palette.card))
                .overlay(Capsule().strokeBorder(selecting ? .clear : Palette.rule))
                .foregroundStyle(selecting ? Palette.onSafelight : Palette.ink)
        }
        .buttonStyle(.plain).hoverLift(scale: 1.04, radius: 16)
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .help("Select photos to share, AirDrop or copy (⇧⌘S)")
    }
}
