import SwiftUI
import AppKit
import PixoraCore

struct ViewerState: Identifiable {
    let id = UUID()
    var photos: [Photo]
    var index: Int
    var title: String
    /// Where the photo's tile was on screen when opened (for the zoom transition).
    var origin: CGRect?
    var current: Photo { photos[index] }
}

/// Decoded full-size images for the viewer; the neighbours of the current photo are preloaded.
final class ViewerCache: @unchecked Sendable {
    static let shared = ViewerCache()
    private let cache = NSCache<NSNumber, NSImage>()
    init() { cache.countLimit = 8 }
    func purge() { cache.removeAllObjects() }
    func image(for photo: Photo, root: URL?) async -> NSImage? {
        if let hit = cache.object(forKey: photo.id as NSNumber) { return hit }
        guard let root else { return nil }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageLoader.image(at: root.appendingPathComponent(photo.relPath), maxPixel: 3200) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: photo.id as NSNumber) }
        return img
    }
}

/// Full-window photo viewer: ← / → to move, Esc or Space to close. Opens by zooming out of the photo's tile and
/// closes by shrinking back into it.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var faces: [Face] = []
    @State private var isFullRes = false
    @AppStorage("viewerFaces") private var showFaces = false
    @AppStorage("viewerInfo") private var showInfo = true
    @State private var anchor: NSView?
    @FocusState private var focused: Bool
    @State private var revealed = false
    @State private var heroFrom: CGRect?
    @State private var area: CGRect = .zero
    @State private var closing = false

    private var spring: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86) }

    var body: some View {
        if let state = model.viewer {
            let photo = state.current
            GeometryReader { root in
                let rootOrigin = root.frame(in: .global).origin
                ZStack {
                    Color(white: 0.04).ignoresSafeArea().opacity(revealed ? 1 : 0)
                    VStack(spacing: 0) {
                        topBar(state)
                        ZStack {
                            GeometryReader { g in
                                Color.clear
                                    .onAppear { area = g.frame(in: .global) }
                                    .onChange(of: g.frame(in: .global)) { _, f in area = f }
                            }
                            HStack {
                                navButton("chevron.left", enabled: state.index > 0) { step(-1) }
                                Spacer()
                                navButton("chevron.right", enabled: state.index < state.photos.count - 1) { step(1) }
                            }.padding(.horizontal, 18)
                            if image == nil { ProgressView().controlSize(.large).tint(.white) }
                            if !isFullRes, image != nil, model.source(photo.sourceID)?.isOnline == false {
                                VStack { Spacer(); EdgeLabel("Preview — original offline", color: .white.opacity(0.7)).padding(.bottom, 8) }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showInfo { infoBar(photo) }
                        filmstrip(state)
                    }
                    .opacity(revealed ? 1 : 0)
                    if let image { hero(image, rootOrigin: rootOrigin) }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.space) { close(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "f")) { _ in showFaces.toggle(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "i")) { _ in showInfo.toggle(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "l")) { _ in
                if let p = model.viewer?.current, p.id > 0 { model.toggleFavorite([p]) }
                return .handled
            }
            .onExitCommand { close() }
            .onAppear {
                focused = true
                heroFrom = state.origin
                revealed = false
                DispatchQueue.main.async { withAnimation(spring) { revealed = true } }
            }
            .task(id: photo.id) { await load(state) }
            .background(ShareAnchor(view: $anchor))
        }
    }

    /// The photo itself: at its tile while closed, fitted into the viewer once revealed.
    private func hero(_ image: NSImage, rootOrigin: CGPoint) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.5
        let target = Self.fit(aspect: aspect, in: area.insetBy(dx: 80, dy: 12))
        let from = heroFrom ?? target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04)
        let r = revealed ? target : from
        return Image(nsImage: image).resizable()
            .aspectRatio(contentMode: revealed ? .fit : .fill)
            .frame(width: max(1, r.width), height: max(1, r.height))
            .clipShape(RoundedRectangle(cornerRadius: revealed ? 0 : 3))
            .overlay { if revealed && !closing && showFaces { faceBoxes } }
            .shadow(color: .black.opacity(revealed ? 0.6 : 0), radius: 30)
            .opacity(heroFrom == nil && !revealed ? 0 : 1)
            .position(x: r.midX - rootOrigin.x, y: r.midY - rootOrigin.y)
            .allowsHitTesting(false)
    }

    private var faceBoxes: some View {
        GeometryReader { geo in
            ForEach(faces) { f in
                let r = CGRect(x: f.rect.minX * geo.size.width, y: f.rect.minY * geo.size.height,
                               width: f.rect.width * geo.size.width, height: f.rect.height * geo.size.height)
                ZStack(alignment: .bottom) {
                    Rectangle().strokeBorder(f.state.isCertain ? Color.white : Color.yellow,
                                             style: StrokeStyle(lineWidth: 2, dash: f.state.isCertain ? [] : [5, 3]))
                    if let name = model.person(f.personID)?.displayName {
                        Text(name + (f.state.isCertain ? "" : "?")).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.7))).foregroundStyle(.white)
                            .offset(y: 20)
                    }
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            }
        }
    }

    static func fit(aspect: CGFloat, in box: CGRect) -> CGRect {
        guard box.width > 0, box.height > 0 else { return box }
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private func topBar(_ state: ViewerState) -> some View {
        HStack(spacing: 12) {
            Button { close() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 32, height: 32) }
                .buttonStyle(.plain).background(Circle().fill(.white.opacity(0.12))).foregroundStyle(.white)
                .keyboardShortcut(.cancelAction).help("Close (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(state.current.filename).font(Typography.display(16)).foregroundStyle(.white)
                EdgeLabel("\(state.index + 1) of \(state.photos.count) · \(state.title)", color: .white.opacity(0.6))
            }
            Spacer()
            if state.current.id > 0 {
                let fav = model.favorites.contains(state.current.id)
                Button { model.toggleFavorite([state.current]) } label: {
                    Image(systemName: fav ? "heart.fill" : "heart").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(fav ? Color.pink.opacity(0.85) : .white.opacity(0.12))).foregroundStyle(.white)
                }.buttonStyle(.plain).help(fav ? "Remove from favorites (L)" : "Add to favorites (L)")
                .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
                .hoverLift(scale: 1.08, radius: 8)
            }
            toggle("person.crop.square", "Faces (F)", $showFaces)
            toggle("info.circle", "Info (I)", $showInfo)
            barButton("square.and.arrow.up", "Share / AirDrop") { model.share([state.current], from: anchor) }
            barButton("folder", "Show in Finder") {
                if let s = model.source(state.current.sourceID), s.isOnline {
                    NSWorkspace.shared.activateFileViewerSelecting([s.url.appendingPathComponent(state.current.relPath)])
                }
            }
            barButton("square.and.arrow.down.on.square", "Copy to Folder…") { model.requestExport(photos: [state.current]) }
            if state.current.id < 0 {
                barButton("lock.open", "Move to Library") { model.moveToLibrary(photos: [state.current]); close() }
            } else if model.canMakePrivate {
                barButton("lock", "Make Private") { model.makePrivate(photos: [state.current]); close() }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func infoBar(_ p: Photo) -> some View {
        let names = faces.compactMap { f -> String? in
            guard let n = model.person(f.personID)?.displayName, model.person(f.personID)?.isNamed == true else { return nil }
            return n + (f.state.isCertain ? "" : "?")
        }
        return HStack(spacing: 18) {
            if let d = p.takenAt { Label(Format.dateTime.string(from: d), systemImage: "calendar") }
            if let c = p.camera { Label(c, systemImage: "camera") }
            if let l = p.lens { Label(l, systemImage: "camera.aperture") }
            if let w = p.width, let h = p.height { Label("\(w) × \(h)", systemImage: "aspectratio") }
            if !names.isEmpty { Label(names.joined(separator: ", "), systemImage: "person.2") }
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    private func filmstrip(_ state: ViewerState) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(state.photos.enumerated()), id: \.element.id) { i, p in
                        FilmThumb(photo: p, selected: i == state.index)
                            .id(p.id)
                            .onTapGesture { model.viewer?.index = i }
                    }
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            .frame(height: 74)
            .background(Color.white.opacity(0.04))
            .onChange(of: state.index) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(state.current.id, anchor: .center) } }
            .onAppear { proxy.scrollTo(state.current.id, anchor: .center) }
        }
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(enabled ? 0.14 : 0.04))).foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .hoverLift(scale: 1.1, radius: 26, glow: enabled)
        .accessibilityLabel(icon == "chevron.left" ? "Previous photo" : "Next photo")
    }

    private func barButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12))).foregroundStyle(.white)
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).hoverLift(scale: 1.08, radius: 8)
    }

    private func toggle(_ icon: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(value.wrappedValue ? Palette.safelight : .white.opacity(0.12)))
                .foregroundStyle(value.wrappedValue ? Palette.onSafelight : .white)
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).hoverLift(scale: 1.08, radius: 8)
    }

    private func step(_ delta: Int) {
        guard var v = model.viewer else { return }
        let next = v.index + delta
        guard next >= 0, next < v.photos.count else { NSSound.beep(); return }
        v.index = next
        model.viewer = v
    }

    private func close() {
        guard !closing, let state = model.viewer else { return }
        closing = true
        heroFrom = model.tileFrame(state.current.id)   // nil → fade out instead
        withAnimation(spring) { revealed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.36)) {
            model.viewer = nil
            closing = false
        }
    }

    private func load(_ state: ViewerState) async {
        let photo = state.current
        isFullRes = false
        faces = photo.id < 0 ? model.privateFaces(photo.id) : ((try? model.store.faces(photoID: photo.id)) ?? [])
        // Instant preview from the cached thumbnail, then the full image.
        image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url)
        let root = model.source(photo.sourceID).flatMap { $0.isOnline ? $0.url : nil }
        if let full = await ViewerCache.shared.image(for: photo, root: root), model.viewer?.current.id == photo.id {
            image = full; isFullRes = true
        }
        // Preload neighbours.
        for i in [state.index + 1, state.index - 1] where i >= 0 && i < state.photos.count {
            let p = state.photos[i]
            let r = model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil }
            _ = await ViewerCache.shared.image(for: p, root: r)
        }
    }
}

private struct FilmThumb: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let selected: Bool
    @State private var image: NSImage?
    var body: some View {
        ZStack { Color.white.opacity(0.08); if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .frame(width: selected ? 72 : 60, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Palette.safelight : .clear, lineWidth: 2))
            .opacity(selected ? 1 : 0.6)
            .animation(.easeOut(duration: 0.15), value: selected)
            .hoverLift(scale: 1.08, radius: 4)
            .task(id: photo.id) { image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url) }
    }
}
