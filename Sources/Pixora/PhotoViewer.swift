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

/// Where the photo is under the fingers. Kept out of the view's own state and read only by the small modifiers below,
/// so a swipe moves the photo without rebuilding the rest of the screen on every frame.
@MainActor @Observable
final class ViewerMotion {
    var slide: CGFloat = 0
    var drop: CGFloat = 0
}

private struct Travel: ViewModifier {
    let motion: ViewerMotion
    let shift: CGFloat
    let follows: Bool
    func body(content: Content) -> some View { content.offset(x: motion.slide + shift, y: follows ? motion.drop : 0) }
}

private struct ShrinkOnDrop: ViewModifier {
    let motion: ViewerMotion
    func body(content: Content) -> some View { content.scaleEffect(1 - min(0.3, abs(motion.drop) / 1100)) }
}

/// Everything around the photo thins out as it's swiped away to close.
private struct Presence: ViewModifier {
    let motion: ViewerMotion
    let shown: Bool
    func body(content: Content) -> some View { content.opacity(shown ? 1 - min(1, Double(abs(motion.drop)) / 320) : 0) }
}

private struct ArrivingGlow: View {
    let motion: ViewerMotion
    let before: CGImage?
    let after: CGImage?
    let pitch: CGFloat
    var body: some View { AmbientGlow(image: motion.slide < 0 ? after : before).opacity(min(1, abs(motion.slide) / pitch)) }
}

final class CGImageBox { let image: CGImage; init(image: CGImage) { self.image = image } }

/// Decoded full-size images for the viewer; the neighbours of the current photo are preloaded.
final class ViewerCache: @unchecked Sendable {
    static let shared = ViewerCache()
    private let cache = NSCache<NSNumber, NSImage>()
    private let glows = NSCache<NSNumber, CGImageBox>()
    init() { cache.countLimit = 12; glows.countLimit = 400 }
    func purge() { cache.removeAllObjects(); glows.removeAllObjects() }
    /// Already decoded, without waiting.
    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: id as NSNumber) }

    /// The soft colour behind a photo. Kept only in memory, like everything here, and purged when Private Space locks.
    func glow(for photo: Photo, from image: NSImage?) async -> CGImage? {
        if let hit = glows.object(forKey: photo.id as NSNumber) { return hit.image }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let glow = await Task.detached(priority: .userInitiated) { AmbientBackdrop.make(from: cg) }.value
        if let glow { glows.setObject(CGImageBox(image: glow), forKey: photo.id as NSNumber) }
        return glow
    }
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

    /// The photo at its full size, for zooming in past what the viewer normally decodes. Not cached: it can be large.
    func detail(for photo: Photo, root: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = ImageLoader.image(at: root.appendingPathComponent(photo.relPath), maxPixel: 16000) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// Full-window photo viewer. Swipe or ← / → to move, swipe down, Esc or Space to close, pinch or + / − to zoom, press
/// and hold to lift the subject out. Opens by zooming out of the photo's tile and closes by shrinking back into it,
/// and the room takes on the colours of whatever photo is showing.
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
    @State private var zoom = ViewerZoom()
    @State private var detailLoaded: Int64?
    @AppStorage("viewerGlow") private var showGlow = true
    /// Which photo `image` is, so a photo that has just slid in isn't swapped for its thumbnail.
    @State private var imageID: Int64?
    /// Sideways and vertical travel of the photo under the fingers.
    @State private var swipe = ViewerSwipe()
    @State private var motion = ViewerMotion()
    /// The photo sliding in, while the move plays. The rest of the screen already shows it.
    @State private var target: Int?
    @State private var neighbours: [Int64: NSImage] = [:]
    @State private var glows: [Int64: CGImage] = [:]
    @State private var crossedLine = false
    @State private var hearts: [UUID] = []
    @State private var lifted: SubjectLift.Result?
    @State private var lifting = false
    @State private var note: String?
    /// The pointer moved recently. The arrows and zoom control fade away when it rests, leaving just the photo.
    @State private var awake = true
    @State private var sleepTimer: Task<Void, Never>?

    private var spring: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86) }
    private var glide: Animation { reduceMotion ? .easeOut(duration: 0.12) : Motion.glide }
    /// How far one photo is from the next.
    private var pitch: CGFloat { max(area.width, 1) }

    var body: some View {
        if let state = model.viewer {
            let photo = state.current
            let shown = state.photos[target ?? state.index]
            GeometryReader { root in
                let rootOrigin = root.frame(in: .global).origin
                ZStack {
                    room(state).modifier(Presence(motion: motion, shown: revealed))
                    VStack(spacing: 0) {
                        topBar(state, shown: shown)
                        ZStack {
                            GeometryReader { g in
                                PhotoGestureSurface(zoomed: zoom.isZoomed,
                                                    onZoom: { delta, p in zoomTo(zoom.scale * (1 + delta), around: p) },
                                                    onZoomEnded: {
                                                        if zoom.scale < 1.05 { zoomTo(1, around: .zero, animated: true); Haptics.tick() }
                                                    },
                                                    onPan: { zoom.pan(by: $0, image: fittedSize, viewport: area.size) },
                                                    onToggle: { toggleZoom(at: $0) },
                                                    onSwipe: { swiped($0, at: $1) },
                                                    onSwipeEnded: { swipeEnded() },
                                                    onWheelStep: { move($0) },
                                                    onHold: photo.id > 0 ? { p in liftSubject(at: p) } : nil)
                                    .onAppear { area = g.frame(in: .global) }
                                    .onChange(of: g.frame(in: .global)) { _, f in
                                        area = f
                                        zoom.pan(by: .zero, image: fittedSize, viewport: f.size)
                                    }
                            }
                            HStack {
                                navButton("chevron.left", enabled: (target ?? state.index) > 0) { move(-1) }
                                Spacer()
                                navButton("chevron.right", enabled: (target ?? state.index) < state.photos.count - 1) { move(1) }
                            }.padding(.horizontal, 18)
                            .opacity(zoom.isZoomed || lifted != nil || !awake ? 0 : 1).allowsHitTesting(!zoom.isZoomed && lifted == nil)   // the zoomed photo covers them
                            if image == nil { ProgressView().controlSize(.large).tint(.white) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onContinuousHover { phase in
                            if case .active = phase { wake() }
                        }
                        if showInfo { infoBar(shown) }
                        Filmstrip(photos: state.photos, selected: target ?? state.index) { go(to: $0) }.equatable()
                    }
                    .modifier(Presence(motion: motion, shown: revealed))
                    if revealed && !closing {
                        sidePhoto(state, step: -1, rootOrigin: rootOrigin)
                        sidePhoto(state, step: 1, rootOrigin: rootOrigin)
                    }
                    if let image { hero(image, rootOrigin: rootOrigin, rootSize: root.size) }
                    if let lifted, let image { liftLayer(lifted, image: image, rootOrigin: rootOrigin) }
                    if image != nil && revealed && !closing && lifted == nil && !lifting {
                        zoomControls.position(x: area.midX - rootOrigin.x, y: area.maxY - rootOrigin.y - 30)
                            .modifier(Presence(motion: motion, shown: zoom.isZoomed || awake))
                    }
                    if lifting || note != nil {
                        notice.position(x: area.midX - rootOrigin.x, y: area.maxY - rootOrigin.y - 30)
                    }
                    ForEach(hearts, id: \.self) { id in
                        HeartBurst { hearts.removeAll { $0 == id } }
                            .position(x: area.midX - rootOrigin.x, y: area.midY - rootOrigin.y)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow, phases: [.down, .repeat]) { step(-1, held: $0.phase == .repeat); return .handled }
            .onKeyPress(.rightArrow, phases: [.down, .repeat]) { step(1, held: $0.phase == .repeat); return .handled }
            .onKeyPress(.space) { close(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "f")) { _ in showFaces.toggle(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "i")) { _ in showInfo.toggle(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in zoomStep(1.5); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "-")) { _ in zoomStep(1 / 1.5); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in zoomTo(1, around: .zero, animated: true); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "l")) { _ in
                if let p = model.viewer?.current { favorite(p) }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "c")) { press in
                if press.modifiers.contains(.command) {
                    guard lifted != nil else { return .ignored }
                    copyLifted()
                } else if lifted == nil, photo.id > 0 { liftSubject(at: nil) }
                return .handled
            }
            .onExitCommand { close() }
            .onAppear {
                focused = true
                wake()
                heroFrom = state.origin
                revealed = false
                DispatchQueue.main.async { withAnimation(spring) { revealed = true } }
                #if PIXORA_UI_TESTING
                if let z = ProcessInfo.processInfo.environment["PIXORA_TEST_ZOOM"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        zoomTo(z, around: CGPoint(x: 0, y: -80))
                        if let w = NSApp.keyWindow ?? NSApp.windows.first, let c = w.contentView {
                            let p = c.convert(NSPoint(x: area.midX, y: area.midY), to: nil)
                            let flipped = NSPoint(x: p.x, y: c.isFlipped ? c.bounds.height - p.y : p.y)
                            fputs("view under pointer: \(c.hitTest(flipped).map { String(describing: type(of: $0)) } ?? "none"), zoom: \(zoom.scale)\n", stderr)
                        }
                    }
                }
                #endif
            }
            .task(id: photo.id) { await load(state) }
            .background(ShareAnchor(view: $anchor))
        }
    }

    /// The photo itself: at its tile while closed, fitted into the viewer once revealed.
    private func hero(_ image: NSImage, rootOrigin: CGPoint, rootSize: CGSize) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.5
        let target = Self.fit(aspect: aspect, in: area.insetBy(dx: 80, dy: 12))
        let from = heroFrom ?? target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04)
        let r = revealed ? target : from
        // While zoomed the photo stays inside its own area, under the bars. Otherwise it may travel from its tile.
        let window = zoom.isZoomed ? area.offsetBy(dx: -rootOrigin.x, dy: -rootOrigin.y) : CGRect(origin: .zero, size: rootSize)
        return Image(nsImage: image).resizable()
            .aspectRatio(contentMode: revealed ? .fit : .fill)
            .frame(width: max(1, r.width), height: max(1, r.height))
            .clipShape(RoundedRectangle(cornerRadius: revealed ? 2 : 3))
            .overlay { if revealed && !closing && showFaces { faceBoxes } }
            // On a plain shape behind the photo: a shadow on the photo itself is re-rendered every frame of a swipe.
            .background { Rectangle().fill(.black.opacity(0.001)).shadow(color: .black.opacity(revealed ? 0.55 : 0), radius: 34, y: 14) }
            .opacity(heroFrom == nil && !revealed ? 0 : 1)
            .scaleEffect(zoom.scale)
            .modifier(ShrinkOnDrop(motion: motion))
            .offset(zoom.offset)
            .position(x: r.midX - rootOrigin.x, y: r.midY - rootOrigin.y)
            .modifier(Travel(motion: motion, shift: 0, follows: true))
            .clipShape(RegionShape(region: window))
            .opacity(lifted == nil ? 1 : 0.28)
            .allowsHitTesting(false)
    }

    /// The photo waiting just off-screen on one side. Always in place, even at rest: something added at the moment a
    /// move starts would appear where it's going instead of travelling there.
    private func sidePhoto(_ state: ViewerState, step: Int, rootOrigin: CGPoint) -> some View {
        let i = target.flatMap { ($0 > state.index) == (step > 0) ? $0 : nil } ?? state.index + step
        let side = state.photos.indices.contains(i) ? neighbours[state.photos[i].id] : nil
        let aspect = side.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? 1.5
        let r = Self.fit(aspect: aspect, in: area.insetBy(dx: 80, dy: 12))
        return ZStack {
            if let side {
                Image(nsImage: side).resizable()
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .background { Rectangle().fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.55), radius: 34, y: 14) }
            }
        }
        .frame(width: max(1, r.width), height: max(1, r.height))
        .transaction { $0.animation = nil }
        .position(x: area.midX - rootOrigin.x, y: r.midY - rootOrigin.y)
        .modifier(Travel(motion: motion, shift: CGFloat(step) * pitch, follows: false))
        .modifier(Presence(motion: motion, shown: lifted == nil))
        .allowsHitTesting(false)
    }

    /// Behind everything: near-black, tinted by the photo. Mid-swipe the next photo's colours fade in as it arrives.
    private func room(_ state: ViewerState) -> some View {
        func glow(_ step: Int) -> CGImage? {
            let i = target.flatMap { ($0 > state.index) == (step > 0) ? $0 : nil } ?? state.index + step
            return state.photos.indices.contains(i) ? glows[state.photos[i].id] : nil
        }
        return ZStack {
            Color(white: 0.04)
            if showGlow {
                AmbientGlow(image: glows[state.current.id]).id(state.current.id).transition(.opacity)
                ArrivingGlow(motion: motion, before: glow(-1), after: glow(1), pitch: pitch)
                RoomGrain()
                Vignette()
            }
        }
        .animation(.easeInOut(duration: 0.45), value: glows[state.current.id] == nil)
        .ignoresSafeArea()
    }

    /// − 100% + under the photo. The percentage is relative to the photo fitted in the window; clicking it fits again.
    private var zoomControls: some View {
        let percent = Int((zoom.scale * 100).rounded())
        return HStack(spacing: 2) {
            zoomButton("minus", "Zoom out (−)", enabled: zoom.isZoomed) { zoomStep(1 / 1.5) }
            Button { zoomTo(1, around: .zero, animated: true) } label: {
                Text("\(percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(width: 50, height: 28).contentShape(Rectangle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain).help("Fit the photo (0)").accessibilityLabel("Fit photo, zoomed to \(percent) percent")
            zoomButton("plus", "Zoom in (+)", enabled: zoom.scale < ViewerZoom.maxScale) { zoomStep(1.5) }
        }
        .padding(.horizontal, 4)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }

    private func zoomButton(_ icon: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                .contentShape(Rectangle()).foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
        }.buttonStyle(.plain).disabled(!enabled).help(help).accessibilityLabel(help)
    }

    /// The photo's size on screen at 100%.
    private var fittedSize: CGSize {
        guard let image, image.size.height > 0 else { return .zero }
        return Self.fit(aspect: image.size.width / image.size.height, in: area.insetBy(dx: 80, dy: 12)).size
    }

    private func zoomTo(_ scale: CGFloat, around point: CGPoint, animated: Bool = false) {
        guard image != nil else { return }
        withAnimation(animated ? spring : nil) { zoom.zoom(to: scale, around: point, image: fittedSize, viewport: area.size) }
        if zoom.isZoomed { loadDetail() }
    }

    private func zoomStep(_ factor: CGFloat) { zoomTo(zoom.scale * factor, around: .zero, animated: true) }

    private func toggleZoom(at point: CGPoint) {
        zoomTo(zoom.isZoomed ? 1 : ViewerZoom.toggleScale, around: point, animated: true)
    }

    /// The viewer decodes photos to 3200 px; zooming in swaps in the full size when the original is larger.
    private func loadDetail() {
        guard let photo = model.viewer?.current, photo.id > 0, isFullRes, detailLoaded != photo.id,
              max(photo.width ?? 0, photo.height ?? 0) > 3200,
              let root = model.source(photo.sourceID).flatMap({ $0.isOnline ? $0.url : nil }) else { return }
        detailLoaded = photo.id
        Task {
            if let full = await ViewerCache.shared.detail(for: photo, root: root), model.viewer?.current.id == photo.id { image = full }
        }
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

    private func topBar(_ state: ViewerState, shown: Photo) -> some View {
        HStack(spacing: 12) {
            CloseCircle(help: "Close (Esc)") { close() }
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.filename).font(Typography.display(16)).foregroundStyle(.white)
                EdgeLabel("\((target ?? state.index) + 1) of \(state.photos.count) · \(state.title)\(isPreview(shown) ? " · Preview, original offline" : "")", color: .white.opacity(0.6))
            }
            Spacer()
            if state.current.id > 0 {
                let fav = model.favorites.contains(shown.id)
                Button { favorite(shown) } label: {
                    Image(systemName: fav ? "heart.fill" : "heart").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 32)
                        .symbolEffect(.bounce, value: fav)
                        .background(RoundedRectangle(cornerRadius: 8).fill(fav ? Color.pink.opacity(0.85) : .white.opacity(0.12))).foregroundStyle(.white)
                }.buttonStyle(.plain).help(fav ? "Remove from favorites (L)" : "Add to favorites (L)")
                .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
                .hoverLift(scale: 1.1, radius: 8, glow: true)
            }
            if state.current.id > 0 {
                barButton("person.and.background.dotted", "Lift Subject (C), or press and hold on someone") { liftSubject(at: nil) }
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
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).hoverLift(scale: 1.1, radius: 8, glow: true)
    }

    private func toggle(_ icon: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(value.wrappedValue ? Palette.safelight : .white.opacity(0.12)))
                .foregroundStyle(value.wrappedValue ? Palette.onSafelight : .white)
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).hoverLift(scale: 1.08, radius: 8)
    }

    private func isPreview(_ photo: Photo) -> Bool { !isFullRes && image != nil && model.source(photo.sourceID)?.isOnline == false }

    private func wake() {
        if !awake { withAnimation(Motion.quick) { awake = true } }
        sleepTimer?.cancel()
        sleepTimer = Task {
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.45)) { awake = false } }
        }
    }

    // MARK: Moving between photos

    private func swiped(_ delta: CGSize, at time: TimeInterval) {
        guard let state = model.viewer, image != nil, !closing, lifted == nil, !zoom.isZoomed else { return }
        if target != nil { finishMove() }
        if !swipe.isActive {
            swipe = ViewerSwipe(allowLeft: state.index < state.photos.count - 1, allowRight: state.index > 0)
            crossedLine = false
        }
        swipe.add(delta, at: time)
        motion.slide = swipe.offset.width
        motion.drop = swipe.offset.height
        let past = swipe.outcome(width: pitch) != .none
        if past != crossedLine { crossedLine = past; if past { Haptics.tick() } }
    }

    private func swipeEnded() {
        let outcome = swipe.outcome(width: pitch)
        swipe = ViewerSwipe()
        switch outcome {
        case .left: move(1)
        case .right: move(-1)
        case .up, .down: close()
        case .none: withAnimation(glide) { motion.slide = 0; motion.drop = 0 }
        }
    }

    private func step(_ delta: Int, held: Bool) {
        if held {   // holding an arrow key runs through the photos with nothing in the way
            guard var v = model.viewer, v.photos.indices.contains(v.index + delta) else { return }
            finishMove()
            v.index += delta
            model.viewer = v
        } else {
            move(delta)
        }
    }

    private func move(_ delta: Int) {
        guard let state = model.viewer else { return }
        let from = target ?? state.index
        guard state.photos.indices.contains(from + delta) else {
            // Nothing further that way: the photo nudges and comes back.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) { motion.slide = CGFloat(delta) * -26 } completion: {
                withAnimation(glide) { motion.slide = 0 }
            }
            return
        }
        go(to: from + delta)
    }

    /// Slides to any photo: the current one leaves as the new one arrives, and they swap roles when it settles.
    private func go(to index: Int) {
        guard let state = model.viewer, index != (target ?? state.index) else { return }
        finishMove()
        guard let v = model.viewer else { return }
        let photo = v.photos[index]
        zoom = ViewerZoom()
        lifted = nil
        if neighbours[photo.id] == nil { neighbours[photo.id] = ViewerCache.shared.cached(photo.id) ?? ImageCache.shared.cached(photo.id) }
        target = index
        let forward = index > v.index
        withAnimation(glide, completionCriteria: .logicallyComplete) {
            motion.slide = forward ? -pitch : pitch
            motion.drop = 0
        } completion: {
            if target == index { finishMove() }
        }
    }

    /// Hands over to the photo that slid in. Nothing visibly changes: it's already where it needs to be.
    private func finishMove() {
        guard let index = target, var v = model.viewer else { return }
        let photo = v.photos[index]
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            if let arrived = neighbours[photo.id] { image = arrived; imageID = photo.id }
            target = nil
            motion.slide = 0
            v.index = index
            model.viewer = v
        }
    }

    private func favorite(_ photo: Photo) {
        guard photo.id > 0 else { return }
        let adding = !model.favorites.contains(photo.id)
        model.toggleFavorite([photo])
        Haptics.tick()
        if adding && !reduceMotion { hearts.append(UUID()) }
    }

    private func close() {
        if lifted != nil { withAnimation(glide) { lifted = nil }; return }
        guard !closing, let state = model.viewer else { return }
        finishMove()
        closing = true
        withAnimation(spring) { zoom = ViewerZoom(); motion.slide = 0; motion.drop = 0 }
        heroFrom = model.tileFrame(model.viewer?.current.id ?? state.current.id)   // nil → fade out instead
        withAnimation(spring) { revealed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.36)) {
            model.viewer = nil
            closing = false
        }
    }

    private func load(_ state: ViewerState) async {
        let photo = state.current
        zoom = ViewerZoom()
        detailLoaded = nil
        faces = photo.id < 0 ? model.privateFaces(photo.id) : ((try? model.store.faces(photoID: photo.id)) ?? [])
        // The decoded photo if it's ready, else the cached thumbnail straight away and the full image after.
        if let ready = ViewerCache.shared.cached(photo.id) {
            image = ready; imageID = photo.id; isFullRes = true
        } else {
            isFullRes = false
            if imageID != photo.id {
                image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url)
                imageID = photo.id
            }
            let root = model.source(photo.sourceID).flatMap { $0.isOnline ? $0.url : nil }
            if let full = await ViewerCache.shared.image(for: photo, root: root), model.viewer?.current.id == photo.id {
                image = full; isFullRes = true
            }
        }
        if showGlow, let glow = await ViewerCache.shared.glow(for: photo, from: image) { glows[photo.id] = glow }
        // Get the neighbours ready: their thumbnails first so a swipe always has something to show.
        let around = [state.index + 1, state.index - 1, state.index + 2, state.index - 2].filter(state.photos.indices.contains).map { state.photos[$0] }
        neighbours = neighbours.filter { id, _ in around.contains { $0.id == id } }
        glows = glows.filter { id, _ in id == photo.id || around.contains { $0.id == id } }
        for p in around where neighbours[p.id] == nil && !Task.isCancelled {
            neighbours[p.id] = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID)?.url)
        }
        for p in around where showGlow && glows[p.id] == nil && !Task.isCancelled {
            glows[p.id] = await ViewerCache.shared.glow(for: p, from: neighbours[p.id])
        }
        for p in around.prefix(2) where !Task.isCancelled {
            let r = model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil }
            if let full = await ViewerCache.shared.image(for: p, root: r), !Task.isCancelled { neighbours[p.id] = full }
        }
    }

    // MARK: Lifting the subject out

    private func liftSubject(at point: CGPoint?) {
        guard let photo = model.viewer?.current, photo.id > 0, !lifting, lifted == nil, !zoom.isZoomed,
              let source = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let box = Self.fit(aspect: CGFloat(source.width) / CGFloat(max(1, source.height)), in: area.insetBy(dx: 80, dy: 12))
        // `point` is from the middle of the photo area; the request wants a position within the photo.
        let spot = point.map { CGPoint(x: ($0.x + area.midX - box.minX) / box.width, y: ($0.y + area.midY - box.minY) / box.height) }
        let inside = spot.flatMap { (0...1).contains($0.x) && (0...1).contains($0.y) ? $0 : nil }
        lifting = true
        note = nil
        Haptics.tick()
        Task {
            let result = await Task.detached(priority: .userInitiated) { try? SubjectLift.lift(source, at: inside) }.value
            lifting = false
            guard model.viewer?.current.id == photo.id else { return }
            if let result {
                Haptics.thud()
                withAnimation(Motion.pop) { lifted = result }
            } else {
                show("No clear subject in this photo")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation(Motion.quick) { note = text }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if note == text { withAnimation(Motion.quick) { note = nil } }
        }
    }

    private var notice: some View {
        HStack(spacing: 8) {
            if lifting { ProgressView().controlSize(.small).tint(.white) }
            Text(lifting ? "Finding the subject…" : (note ?? "")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .transition(.opacity)
    }

    /// The subject raised off the dimmed photo, ready to drag anywhere.
    private func liftLayer(_ result: SubjectLift.Result, image: NSImage, rootOrigin: CGPoint) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.5
        let r = Self.fit(aspect: aspect, in: area.insetBy(dx: 80, dy: 12))
        let name = (model.viewer?.current.filename as NSString?)?.deletingPathExtension ?? "Subject"
        return ZStack {
            Image(decorative: result.overlay, scale: 1).resizable()
                .frame(width: r.width, height: r.height)
                .shadow(color: .white.opacity(0.85), radius: 1.5)
                .shadow(color: .white.opacity(0.45), radius: 14)
                .shadow(color: .black.opacity(0.5), radius: 26, y: 18)
                .scaleEffect(1.025)
                .overlay { CutoutDragSource(cutout: result.cutout, name: name) }
                .position(x: r.midX - rootOrigin.x, y: r.midY - rootOrigin.y)
                .transition(.scale(scale: 0.98).combined(with: .opacity))
            HStack(spacing: 4) {
                Label("Drag it out, or", systemImage: "hand.draw").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 8)
                liftButton("Copy", "doc.on.doc") { copyLifted() }
                liftButton("Save PNG…", "square.and.arrow.down") { saveLifted(result, name: name) }
                liftButton("Done", "xmark") { withAnimation(glide) { lifted = nil } }
            }
            .padding(4)
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .position(x: area.midX - rootOrigin.x, y: area.maxY - rootOrigin.y - 30)
        }
    }

    private func liftButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(.white.opacity(0.14))).foregroundStyle(.white).contentShape(Capsule())
        }.buttonStyle(.plain).hoverLift(scale: 1.05, radius: 14)
    }

    private func copyLifted() {
        guard let cutout = lifted?.cutout, let png = CutoutFile.png(cutout) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        Haptics.tick()
        show("Copied")
    }

    private func saveLifted(_ result: SubjectLift.Result, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(name) cutout.png"
        guard panel.runModal() == .OK, let url = panel.url, let png = CutoutFile.png(result.cutout) else { return }
        do { try png.write(to: url, options: .atomic); show("Saved") } catch { model.errorMessage = error.localizedDescription }
    }
}

/// Separate and equatable: a swipe redraws the screen every frame, and this strip can hold thousands of photos.
private struct Filmstrip: View, Equatable {
    let photos: [Photo]
    let selected: Int
    let onSelect: (Int) -> Void
    static func == (a: Filmstrip, b: Filmstrip) -> Bool { a.selected == b.selected && a.photos.count == b.photos.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                        FilmThumb(photo: p, selected: i == selected)
                            .id(p.id)
                            .onTapGesture { onSelect(i) }
                    }
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
            .frame(height: 74)
            .background(Color.white.opacity(0.04))
            .onChange(of: selected) { _, i in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(photos[i].id, anchor: .center) } }
            .onAppear { proxy.scrollTo(photos[selected].id, anchor: .center) }
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
