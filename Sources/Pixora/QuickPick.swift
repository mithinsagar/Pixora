import SwiftUI
import AppKit
import PixoraCore

struct QuickPickRequest: Identifiable {
    let id = UUID()
    let title: String
    let photos: [Photo]
}

/// Goes through photos one at a time, full screen: → or swipe right keeps one, ↑ or swipe up makes it a favorite,
/// ← or swipe left skips it. Skipping only moves on; nothing is removed from anywhere.
struct QuickPickView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: QuickPickRequest

    /// A decided photo on its way off the screen. It leaves on its own so the next decision never has to wait.
    private struct Departure: Identifiable {
        let id = UUID()
        let image: NSImage?
        let rect: CGRect
        let start: CGSize
        let decision: PickSession.Decision
    }

    @State private var session: PickSession
    @State private var images: [Int64: NSImage] = [:]
    @State private var glows: [Int64: CGImage] = [:]
    @State private var swipe = ViewerSwipe()
    @State private var offset: CGSize = .zero
    @State private var zoom = ViewerZoom()
    @State private var departures: [Departure] = []
    @State private var returning: PickSession.Decision?
    @State private var area: CGRect = .zero
    @State private var armed: PickSession.Decision?
    @State private var names: [Int64: [String]] = [:]
    @State private var lastGlow: CGImage?
    /// Stopped before the end: the rest weren't looked at, so they aren't counted as skipped.
    @State private var stoppedEarly = false
    @FocusState private var focused: Bool
    private let byID: [Int64: Photo]

    init(request: QuickPickRequest) {
        self.request = request
        _session = State(initialValue: PickSession(ids: request.photos.map(\.id)))
        byID = Dictionary(request.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var current: Photo? { session.current.flatMap { byID[$0] } }
    private var showingSummary: Bool { session.isFinished || stoppedEarly }

    var body: some View {
        ZStack {
            room
            if showingSummary {
                summary.transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 0) {
                    topBar
                    GeometryReader { g in
                        stage(size: g.size)
                            .onAppear { area = g.frame(in: .local) }
                            .onChange(of: g.size) { area = CGRect(origin: .zero, size: g.size) }
                    }
                    controls
                }
            }
        }
        .animation(Motion.glide, value: showingSummary)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { decide(.skip); return .handled }
        .onKeyPress(.rightArrow) { decide(.keep); return .handled }
        .onKeyPress(.upArrow) { decide(.favorite); return .handled }
        .onKeyPress(.delete) { undo(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { _ in undo(); return .handled }
        .onExitCommand { finish() }
        .onAppear { focused = true }
        .task(id: session.index) { await prepare() }
    }

    private var room: some View {
        ZStack {
            Color(white: 0.04)
            if !showingSummary, let id = session.current, let glow = glows[id] {
                AmbientGlow(image: glow).id(id).transition(.opacity)
            } else if showingSummary {
                AmbientGlow(image: lastGlow).transition(.opacity)
            }
            RoomGrain()
            Vignette()
        }
        .animation(.easeInOut(duration: 0.5), value: session.current)
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            CloseCircle(help: "Finish (Esc)") { finish() }
            VStack(alignment: .leading, spacing: 1) {
                Text("Quick Pick").font(Typography.display(16)).foregroundStyle(.white)
                EdgeLabel(request.title, color: .white.opacity(0.6))
            }
            Spacer()
            tally("heart.fill", session.count(.favorite), .pink, "favorites")
            tally("checkmark", session.count(.keep), Color(hue: 0.38, saturation: 0.6, brightness: 0.85), "kept")
            tally("arrow.uturn.forward", session.count(.skip), .white.opacity(0.6), "skipped")
            Text("\(min(session.index + 1, session.ids.count)) of \(session.ids.count)").font(Typography.edgeLarge).foregroundStyle(.white.opacity(0.7))
                .rollingNumber(session.index).frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.75)).frame(width: max(2, g.size.width * session.progress), height: 2)
                    .animation(Motion.glide, value: session.index)
            }.frame(height: 2)
        }
    }

    private func tally(_ icon: String, _ n: Int, _ tint: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).rollingNumber(n)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(n) \(label)")
    }

    private func stage(size: CGSize) -> some View {
        let box = CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 22)
        return ZStack {
            PhotoGestureSurface(zoomed: zoom.isZoomed,
                                onZoom: { d, p in zoomTo(zoom.scale * (1 + d), around: p, in: box) },
                                onZoomEnded: { if zoom.scale < 1.05 { zoomTo(1, around: .zero, in: box, animated: true) } },
                                onPan: { if let f = fitted(in: box) { zoom.pan(by: $0, image: f.size, viewport: size) } },
                                onToggle: { zoomTo(zoom.isZoomed ? 1 : ViewerZoom.toggleScale, around: $0, in: box, animated: true) },
                                onSwipe: { swiped($0, at: $1) },
                                onSwipeEnded: { swipeEnded() })
            if let next = session.upNext, let p = byID[next] { card(p, in: box, top: false) }
            if let p = current { card(p, in: box, top: true) }
            ForEach(departures) { d in
                FlyingCard(image: d.image, rect: d.rect, start: d.start, decision: d.decision, reduceMotion: reduceMotion) {
                    departures.removeAll { $0.id == d.id }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func card(_ photo: Photo, in box: CGRect, top: Bool) -> some View {
        let image = images[photo.id]
        let aspect = image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? photoAspect(photo)
        let r = PhotoViewer.fit(aspect: aspect, in: box)
        return ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let image { Image(nsImage: image).resizable() }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if top { stamp } }
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.5), radius: 26, y: 14) }
        .overlay(alignment: .bottomLeading) { if top { caption(photo) } }
        .overlay(alignment: .topTrailing) {
            if top, model.favorites.contains(photo.id) {
                Image(systemName: "heart.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(Color.pink.opacity(0.9))).padding(10)
            }
        }
        .scaleEffect(top ? zoom.scale : 0.93)
        .offset(top ? zoom.offset : .zero)
        .opacity(top ? 1 : 0.55)
        .rotationEffect(.degrees(top && !reduceMotion ? Double(offset.width) / 42 : 0), anchor: .bottom)
        .offset(top ? offset : .zero)
        .position(x: r.midX, y: r.midY)
        .animation(reduceMotion ? nil : Motion.glide, value: top)
        .transition(.asymmetric(insertion: returnTransition, removal: .identity))
        .allowsHitTesting(false)
        .accessibilityLabel(top ? "\(photo.filename)\(photo.takenAt.map { ", " + Format.day.string(from: $0) } ?? "")" : "")
    }

    private func photoAspect(_ p: Photo) -> CGFloat {
        guard let w = p.width, let h = p.height, h > 0 else { return 1.5 }
        return CGFloat(w) / CGFloat(h)
    }

    /// An undone photo comes back from where it went.
    private var returnTransition: AnyTransition {
        guard let returning else { return .identity }
        return .offset(FlyingCard.exit(returning, size: area.size))
    }

    private func caption(_ photo: Photo) -> some View {
        let people = names[photo.id] ?? []
        let line = [photo.takenAt.map { Format.dateTime.string(from: $0) }, people.isEmpty ? nil : people.prefix(4).joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
        return Group {
            if !line.isEmpty {
                Text(line).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.5))).padding(10)
                    .opacity(offset == .zero && !zoom.isZoomed ? 1 : 0)
            }
        }
    }

    /// Fades in over the card as it heads for a decision.
    @ViewBuilder private var stamp: some View {
        let reach = max(abs(offset.width) / max(area.width * 0.2, 1), abs(min(0, offset.height)) / 110)
        if let d = heading {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint(d).opacity(0.22))
                VStack(spacing: 8) {
                    Image(systemName: icon(d)).font(.system(size: 54, weight: .bold))
                    Text(label(d).uppercased()).font(.system(size: 13, weight: .heavy)).tracking(2)
                }
                .foregroundStyle(.white)
                .scaleEffect(armed == d ? 1.1 : 0.92)
                .animation(Motion.pop, value: armed)
            }
            .opacity(min(1, Double(reach)))
        }
    }

    private var heading: PickSession.Decision? {
        if offset.width > 4 { return .keep }
        if offset.width < -4 { return .skip }
        return offset.height < -4 ? .favorite : nil
    }

    private func tint(_ d: PickSession.Decision) -> Color {
        switch d {
        case .skip: .black
        case .keep: Color(hue: 0.38, saturation: 0.65, brightness: 0.7)
        case .favorite: .pink
        }
    }
    private func icon(_ d: PickSession.Decision) -> String {
        switch d {
        case .skip: "arrow.uturn.forward"
        case .keep: "checkmark"
        case .favorite: "heart.fill"
        }
    }
    private func label(_ d: PickSession.Decision) -> String {
        switch d {
        case .skip: "Skip"
        case .keep: "Keep"
        case .favorite: "Favorite"
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .bold)).frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.1))).foregroundStyle(.white.opacity(session.index > 0 ? 0.9 : 0.3))
            }.buttonStyle(.plain).disabled(session.index == 0).help("Undo (Z)").accessibilityLabel("Undo")
            action(.skip, key: "←", size: 58)
            action(.favorite, key: "↑", size: 68)
            action(.keep, key: "→", size: 58)
            Button { finish() } label: {
                Image(systemName: "flag.checkered").font(.system(size: 13, weight: .bold)).frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.1))).foregroundStyle(.white.opacity(0.9))
            }.buttonStyle(.plain).help("Finish now").accessibilityLabel("Finish now")
        }
        .padding(.top, 4).padding(.bottom, 18)
    }

    private func action(_ d: PickSession.Decision, key: String, size: CGFloat) -> some View {
        Button { decide(d) } label: {
            VStack(spacing: 5) {
                Image(systemName: icon(d)).font(.system(size: size * 0.36, weight: .bold)).frame(width: size, height: size)
                    .background(Circle().fill(d == .skip ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(tint(d).gradient)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                    .foregroundStyle(.white)
                    .scaleEffect(armed == d ? 1.14 : 1)
                    .animation(Motion.pop, value: armed)
                Text("\(label(d)) \(key)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain).hoverLift(scale: 1.06, radius: size / 2).accessibilityLabel(label(d))
    }

    // MARK: Deciding

    private func fitted(in box: CGRect) -> CGRect? {
        guard let p = current else { return nil }
        let image = images[p.id]
        let aspect = image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? photoAspect(p)
        return PhotoViewer.fit(aspect: aspect, in: box)
    }

    private func zoomTo(_ scale: CGFloat, around p: CGPoint, in box: CGRect, animated: Bool = false) {
        guard let f = fitted(in: box) else { return }
        withAnimation(animated ? Motion.glide : nil) { zoom.zoom(to: scale, around: p, image: f.size, viewport: area.size) }
    }

    private func swiped(_ delta: CGSize, at time: TimeInterval) {
        guard !zoom.isZoomed, current != nil else { return }
        swipe.add(delta, at: time)
        offset = swipe.offset
        let next: PickSession.Decision?
        switch swipe.outcome(width: area.width) {
        case .left: next = .skip
        case .right: next = .keep
        case .up: next = .favorite
        default: next = nil
        }
        if next != armed { armed = next; if next != nil { Haptics.tick() } }
    }

    private func swipeEnded() {
        let outcome = swipe.outcome(width: area.width)
        swipe = ViewerSwipe()
        armed = nil
        switch outcome {
        case .left: decide(.skip)
        case .right: decide(.keep)
        case .up: decide(.favorite)
        default: withAnimation(Motion.pop) { offset = .zero }
        }
    }

    private func decide(_ d: PickSession.Decision) {
        guard let photo = current else { return }
        let box = area.insetBy(dx: 40, dy: 22)
        let image = images[photo.id]
        let aspect = image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? photoAspect(photo)
        departures.append(Departure(image: image, rect: PhotoViewer.fit(aspect: aspect, in: box), start: offset, decision: d))
        let wasFavorite = model.favorites.contains(photo.id)
        if d == .favorite, !wasFavorite, photo.id > 0 { model.toggleFavorite([photo]) }
        returning = nil
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { offset = .zero; zoom = ViewerZoom() }
        withAnimation(reduceMotion ? nil : Motion.glide) { session.decide(d, wasFavorite: wasFavorite) }
        if d == .skip { Haptics.tick() } else { Haptics.thud() }
    }

    private func undo() {
        guard let last = session.history.last else { return }
        returning = last.decision
        withAnimation(reduceMotion ? nil : Motion.pop) { _ = session.undo() }
        if last.decision == .favorite, !last.wasFavorite, let p = byID[last.id], model.favorites.contains(p.id) { model.toggleFavorite([p]) }
        Haptics.tick()
    }

    private func finish() {
        if showingSummary || session.index == 0 { model.quickPick = nil; return }
        stoppedEarly = true
    }

    private func prepare() async {
        let ahead = session.ids[min(session.index, session.ids.count)...].prefix(4).compactMap { byID[$0] }
        let wanted = Set(ahead.map(\.id) + session.history.suffix(2).map(\.id))
        images = images.filter { wanted.contains($0.key) }
        for p in ahead where names[p.id] == nil { names[p.id] = model.namesInPhoto(p.id) }
        for p in ahead where images[p.id] == nil && !Task.isCancelled {
            if let ready = ViewerCache.shared.cached(p.id) { images[p.id] = ready; continue }
            images[p.id] = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID)?.url)
        }
        for p in ahead where glows[p.id] == nil && !Task.isCancelled {
            glows[p.id] = await ViewerCache.shared.glow(for: p, from: images[p.id])
        }
        if let id = session.current, let glow = glows[id] { lastGlow = glow }
        for p in ahead.prefix(3) where !Task.isCancelled {
            let root = model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil }
            if let full = await ViewerCache.shared.image(for: p, root: root), wanted.contains(p.id) { images[p.id] = full }
        }
    }

    // MARK: Done

    private var kept: [Photo] { session.kept.compactMap { byID[$0] } }
    private var favorites: [Photo] { session.picked(.favorite).compactMap { byID[$0] } }

    private var summary: some View {
        let picks = kept
        let unseen = session.ids.count - session.index
        let columns = min(max(picks.count, 1), 6)
        let rows = (picks.count + columns - 1) / columns
        let cell: CGFloat = 132
        return VStack(spacing: 26) {
            VStack(spacing: 8) {
                Text(picks.isEmpty ? "Nothing picked" : (picks.count == 1 ? "1 photo picked" : "\(picks.count) photos picked"))
                    .font(Typography.display(38)).foregroundStyle(.white)
                Text(summaryLine(unseen: unseen)).font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            if !picks.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 10), count: columns), spacing: 10) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { i, p in
                            PickThumb(photo: p, favorite: model.favorites.contains(p.id), delay: min(Double(i) * 0.025, 0.5))
                                .onTapGesture { model.openViewer(picks, at: p.id, title: "Quick Pick") }
                        }
                    }.padding(6)
                }
                .scrollIndicators(.never)
                .frame(width: CGFloat(columns) * (cell + 10) + 12, height: min(CGFloat(rows) * (cell + 10) + 12, 440))
            }
            HStack(spacing: 10) {
                if unseen > 0 { Button("Keep Going") { withAnimation(Motion.glide) { stoppedEarly = false } }.buttonStyle(GlassButtonStyle()) }
                if !favorites.isEmpty && favorites.count < picks.count {
                    Button("Copy \(Format.count(favorites.count, "Favorite"))…") { model.requestExport(photos: favorites) }.buttonStyle(GlassButtonStyle())
                }
                if !picks.isEmpty {
                    Button { play(picks) } label: { Label("Slideshow", systemImage: "play.fill") }.buttonStyle(GlassButtonStyle())
                    Button { model.requestExport(photos: picks) } label: {
                        Label("Copy \(Format.count(picks.count, "Photo")) to Folder…", systemImage: "square.and.arrow.down.on.square")
                    }.buttonStyle(PrimaryButtonStyle())
                }
                Button("Done") { model.quickPick = nil }.buttonStyle(GlassButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryLine(unseen: Int) -> String {
        var parts = [Format.count(session.count(.favorite), "favorite"), "\(session.count(.keep)) kept", "\(session.count(.skip)) skipped"]
        if unseen > 0 { parts.append("\(unseen) not looked at") }
        return parts.joined(separator: " · ") + ". Nothing was removed from your library."
    }

    private func play(_ photos: [Photo]) {
        model.slideshow = SlideshowRequest(title: request.title, slides: photos,
                                           captions: Dictionary(photos.map { ($0.id, $0.takenAt.map { $0.formatted(date: .long, time: .omitted) } ?? "") }, uniquingKeysWith: { a, _ in a }),
                                           duration: 4, transition: .zoom, showCaptions: true, music: nil, volume: 0.35, isPrivate: false)
    }
}

/// A decided photo leaving: it carries on from wherever the fingers let go.
private struct FlyingCard: View {
    let image: NSImage?
    let rect: CGRect
    let start: CGSize
    let decision: PickSession.Decision
    let reduceMotion: Bool
    let done: () -> Void
    @State private var gone = false
    @State private var size: CGSize = .zero

    static func exit(_ d: PickSession.Decision, size: CGSize) -> CGSize {
        switch d {
        case .skip: CGSize(width: -(size.width + 200), height: 40)
        case .keep: CGSize(width: size.width + 200, height: 40)
        case .favorite: CGSize(width: 0, height: -(size.height + 200))
        }
    }

    var body: some View {
        GeometryReader { g in
            let end = Self.exit(decision, size: g.size)
            let at = gone ? end : start
            ZStack { if let image { Image(nsImage: image).resizable() } else { Rectangle().fill(.white.opacity(0.06)) } }
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(at.width) / 42), anchor: .bottom)
                .offset(at)
                .opacity(reduceMotion && gone ? 0 : 1)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeIn(duration: 0.26)) { gone = true } completion: { done() }
        }
    }
}

private struct PickThumb: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let favorite: Bool
    let delay: Double
    @State private var image: NSImage?
    @State private var shown = false
    var body: some View {
        ZStack { Color.white.opacity(0.06); if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if favorite {
                    Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.pink.opacity(0.9))).padding(5)
                }
            }
            .scaleEffect(shown ? 1 : 0.9).opacity(shown ? 1 : 0)
            .hoverLift(scale: 1.04, radius: 8)
            .task(id: photo.id) { image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url) }
            .onAppear { withAnimation(Motion.pop.delay(delay)) { shown = true } }
    }
}
