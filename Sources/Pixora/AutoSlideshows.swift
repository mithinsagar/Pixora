import SwiftUI
import PixoraCore

/// One ready-made slideshow: a person and a handful of their best photos.
struct AutoSlideshow: Identifiable, Equatable {
    var id: Int64 { personID }
    let personID: Int64
    let name: String
    let photos: [Photo]
    let span: String?
}

/// "Slideshows for you": one row of cards, one per person you photograph most, each quietly cycling through that
/// person's best photos. A wider window fits more people rather than leaving gaps. Nothing to choose: click a card
/// and it plays full screen.
struct AutoSlideshows: View {
    @Environment(AppModel.self) private var model
    @State private var shows: [AutoSlideshow] = []
    @State private var loaded = false
    @State private var width: CGFloat = 1052
    private static let cardWidth: CGFloat = 225, gap: CGFloat = 18, mostCards = 8

    private var fit: Int { max(1, Int((width + Self.gap) / (Self.cardWidth + Self.gap))) }
    /// As many cards as fit. They share the row exactly, so it reaches both edges; with too few people to fill it they
    /// keep a sensible size from the left rather than stretching.
    private var columns: [GridItem] {
        Array(repeating: shows.count < fit ? GridItem(.fixed(300), spacing: Self.gap) : GridItem(.flexible(), spacing: Self.gap), count: min(shows.count, fit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slideshows for you").font(Typography.display(26))
                    Text("Made automatically from the people you photograph most. Click one to play it full screen.")
                        .font(.callout).foregroundStyle(Palette.ink2)
                }
                Spacer()
            }
            if shows.isEmpty {
                if loaded {
                    Text("Name a few people in Review and their slideshows will appear here.")
                        .font(.callout).foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
            } else {
                LazyVGrid(columns: columns, spacing: Self.gap) {
                    ForEach(Array(shows.prefix(fit).enumerated()), id: \.element.id) { i, show in
                        SlideshowCard(show: show, stagger: Double(i) * 0.9) { play(show) }
                    }
                }
                .frame(width: shows.count < fit ? CGFloat(shows.count) * (300 + Self.gap) - Self.gap : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: "\(model.people.count)-\(model.stats.photos)-\(model.stats.namedPeople)") { await load() }
    }

    private func play(_ show: AutoSlideshow) {
        model.slideshow = SlideshowRequest(
            title: show.name, slides: show.photos,
            captions: Dictionary(uniqueKeysWithValues: show.photos.map { ($0.id, $0.takenAt.map { $0.formatted(date: .long, time: .omitted) } ?? "") }),
            duration: 4, transition: .zoom, showCaptions: true, music: nil, volume: 0.35, isPrivate: false)
    }

    /// Top people by photo count; for each, their best certain photos (sharp, eyes open, close-ups first),
    /// a different selection each day when there are plenty to choose from, played in the order taken.
    private func load() async {
        let store = model.store
        let people = model.namedPeople.filter { $0.photoCount >= 3 }.sorted { $0.photoCount > $1.photoCount }.prefix(Self.mostCards)
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let input = people.map { ($0.id, $0.displayName) }
        shows = await Task.detached(priority: .utility) { () -> [AutoSlideshow] in
            input.compactMap { pid, name in
                guard let results = try? store.search(people: [pid], mode: .all, includeUncertain: false), results.count >= 3 else { return nil }
                let faces = (try? store.slideFaces(photoIDs: results.map(\.photo.id))) ?? [:]
                let good = results.filter { !$0.eyesClosed && !$0.soft }
                let pool = (good.count >= 3 ? good : results).map { r -> (SearchResult, Double) in
                    let c = SlideCandidate(photo: r.photo, faces: faces[r.photo.id] ?? [])
                    let portrait = SlideshowPlanner.pick(.portraits, from: [c], people: [pid]).isEmpty ? 0.0 : 0.25
                    return (r, r.score + portrait)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(30)
                var rng = DaySeed(UInt64(day) &* 1_000_003 &+ UInt64(bitPattern: pid))
                let picked = Array(pool).shuffled(using: &rng).prefix(12).map(\.0.photo)
                let ordered = picked.sorted { ($0.takenAt ?? .distantFuture, $0.filename) < ($1.takenAt ?? .distantFuture, $1.filename) }
                let years = Set(ordered.compactMap { $0.takenAt.map { Calendar.current.component(.year, from: $0) } }).sorted()
                let span = years.isEmpty ? nil : (years.count == 1 ? "\(years[0])" : "\(years.first!)–\(years.last!)")
                return AutoSlideshow(personID: pid, name: name, photos: ordered, span: span)
            }
        }.value
        loaded = true
    }
}

private struct DaySeed: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

/// A rounded card that slides through its photos by itself: a slow crossfade with a gentle push-in.
/// Cycling pauses while the pointer is over it; with Reduce Motion it only fades, more slowly.
private struct SlideshowCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let show: AutoSlideshow
    let stagger: Double
    let play: () -> Void
    @State private var index = 0
    @State private var images: [Int: NSImage] = [:]
    @State private var hover = false

    var body: some View {
        Button(action: play) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Palette.card
                    if let img = images[index] {
                        CardFrame(image: img, zoom: !reduceMotion, seed: index)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(index)
                            .transition(.opacity)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.name).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(.white)
                            .lineLimit(1)
                        Text([Format.count(show.photos.count, "photo"), show.span].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        progress.padding(.top, 6)
                    }
                    .padding(16)
                    if hover {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(Circle().fill(.ultraThinMaterial))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .aspectRatio(4 / 5, contentMode: .fit)
                        .shadow(color: .black.opacity(hover ? 0.35 : 0.18), radius: hover ? 18 : 10, y: hover ? 10 : 5)
            .scaleEffect(hover ? 1.025 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
        #if PIXORA_UI_TESTING
        .onAppear { if ProcessInfo.processInfo.environment["PIXORA_TEST_HOVER"] != nil { hover = true } }
        #endif
        .animation(.easeInOut(duration: reduceMotion ? 1.6 : 1.1), value: index)
        .task(id: show.photos.map(\.id)) { await cycle() }
        .accessibilityLabel("\(show.name) slideshow, \(show.photos.count) photos")
        .accessibilityHint("Plays full screen")
    }

    /// Dots under the title showing which photo is up.
    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(show.photos.count, 12), id: \.self) { i in
                Capsule().fill(.white.opacity(i == index ? 0.95 : 0.35)).frame(width: i == index ? 14 : 5, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }

    private func load(_ i: Int) async {
        guard images[i] == nil, show.photos.indices.contains(i) else { return }
        let p = show.photos[i]
        images[i] = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil })
    }

    private func cycle() async {
        index = 0
        await load(0)
        await load(1)
        try? await Task.sleep(for: .seconds(1.5 + stagger))
        while !Task.isCancelled {
            if !hover && show.photos.count > 1 {
                let next = (index + 1) % show.photos.count
                await load(next)
                index = next
                await load((next + 1) % show.photos.count)
                images = images.filter { abs($0.key - index) <= 1 || ($0.key == 0 && index == show.photos.count - 1) }
            }
            try? await Task.sleep(for: .seconds(reduceMotion ? 5 : 3.4))
        }
    }
}

/// One photo filling the card, slowly pushing in towards a varying corner.
private struct CardFrame: View {
    let image: NSImage
    let zoom: Bool
    let seed: Int
    @State private var scale: CGFloat = 1.0

    var body: some View {
        let anchors: [UnitPoint] = [.center, .top, .bottomTrailing, .topLeading, .bottom]
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            .scaleEffect(scale, anchor: anchors[seed % anchors.count])
            .clipped()
            .onAppear { if zoom { withAnimation(.linear(duration: 5)) { scale = 1.08 } } }
    }
}
