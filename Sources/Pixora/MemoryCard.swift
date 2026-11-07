import SwiftUI
import PixoraCore

/// A look back at the top of Find Photos: photos from this day in past years or, in a younger library, from around
/// this date in an earlier month. It isn't shown at all when there's nothing to remember.
struct MemoryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memory: Memory?
    @State private var index = 0
    @State private var image: NSImage?
    @State private var hover = false
    @State private var width: CGFloat = 1052

    var body: some View {
        ZStack {
            if let memory {
                card(memory)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.easeOut(duration: 0.35), value: memory?.title)
        .task(id: model.stats.photos) { await load() }
    }

    private func card(_ memory: Memory) -> some View {
        Button { play(memory.photos, title: memory.title) } label: {
            ZStack(alignment: .bottomLeading) {
                Palette.card
                if let image {
                    MemoryFrame(image: image, drift: !reduceMotion, seed: index)
                        .id(index)
                        .transition(.opacity)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.28), location: 0.55), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        EdgeLabel("Looking back", color: .white.opacity(0.75))
                        Text(memory.title).font(Typography.display(32)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                        Text(memory.subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 6) {
                        if memory.groups.count > 1 {
                            ForEach(memory.groups.prefix(4)) { g in
                                Button(g.label) { play(g.photos, title: g.label) }.buttonStyle(MemoryChipStyle())
                            }
                        }
                    }
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 42, height: 42).background(Circle().fill(.white))
                        .scaleEffect(hover ? 1.1 : 1)
                }
                .padding(20)
            }
            .frame(height: min(320, max(210, width * 0.2)))   // keeps its shape as the window grows
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(hover ? 0.32 : 0.16), radius: hover ? 18 : 10, y: hover ? 10 : 5)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
        .animation(.easeInOut(duration: reduceMotion ? 1.6 : 1.2), value: index)
        .task(id: memory.title) { await cycle(memory.photos) }
        .accessibilityLabel("\(memory.title), \(memory.subtitle)")
        .accessibilityHint("Plays them as a slideshow")
    }

    private func load() async {
        let store = model.store
        memory = await Task.detached(priority: .utility) { Memories.make(from: (try? store.photos()) ?? []) }.value
    }

    private func cycle(_ photos: [Photo]) async {
        guard !photos.isEmpty else { return }
        index = 0
        image = await thumb(photos[0])
        while !Task.isCancelled && photos.count > 1 {
            try? await Task.sleep(for: .seconds(reduceMotion ? 7 : 4.6))
            if hover { continue }
            let next = (index + 1) % photos.count
            let upcoming = await thumb(photos[next])
            index = next
            image = upcoming
        }
    }

    private func thumb(_ p: Photo) async -> NSImage? {
        await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil })
    }

    private func play(_ photos: [Photo], title: String) {
        model.slideshow = SlideshowRequest(title: title, slides: photos,
                                           captions: Dictionary(photos.map { ($0.id, $0.takenAt.map { $0.formatted(date: .long, time: .omitted) } ?? "") }, uniquingKeysWith: { a, _ in a }),
                                           duration: 4, transition: .zoom, showCaptions: true, music: nil, volume: 0.35, isPrivate: false)
    }
}

private struct MemoryChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.32 : 0.18)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
    }
}

/// One photo filling the card, drifting slowly.
private struct MemoryFrame: View {
    let image: NSImage
    let drift: Bool
    let seed: Int
    @State private var scale: CGFloat = 1.0

    var body: some View {
        let anchors: [UnitPoint] = [.top, .trailing, .center, .leading, .bottom]
        GeometryReader { g in
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                .frame(width: g.size.width, height: g.size.height)
                .scaleEffect(scale, anchor: anchors[seed % anchors.count])
                .clipped()
        }
        .onAppear { if drift { withAnimation(.linear(duration: 7)) { scale = 1.09 } } }
    }
}
