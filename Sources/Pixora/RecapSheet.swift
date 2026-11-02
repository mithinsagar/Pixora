import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixoraCore

struct RecapRequest: Identifiable {
    let id = UUID()
    let title: String
    let photos: [Photo]
}

/// Everything the card shows, gathered once (off the main thread).
struct RecapData {
    var hero: CGImage?
    var faces: [(name: String, image: NSImage?)] = []
    var photoCount = 0
    var peopleCount = 0
    var dateLine = ""
}

/// "Ravi's Birthday · 214 photos · 31 people" — a shareable card for a shoot.
struct RecapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RecapRequest
    @State private var title = ""
    @State private var data: RecapData?
    @State private var anchor: NSView?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Event recap card").font(Typography.display(22))
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    if let data {
                        RecapCardView(title: title, data: data)
                            .frame(width: RecapCardView.size.width, height: RecapCardView.size.height)
                            .scaleEffect(300 / RecapCardView.size.width, anchor: .topLeading)
                            .frame(width: 300, height: 300 * RecapCardView.size.height / RecapCardView.size.width, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Palette.rule).frame(width: 300, height: 375).overlay(ProgressView())
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Title").font(.headline)
                    TextField("Event name", text: $title).textFieldStyle(.roundedBorder).frame(width: 260)
                    if let data {
                        Text("\(Format.count(data.photoCount, "photo")) · \(Format.count(data.peopleCount, "person", "people")) · \(data.dateLine)")
                            .font(.caption).foregroundStyle(Palette.ink2)
                    }
                    Text("The best shot is picked automatically: the most named people, with sharp faces and open eyes. Faces show the people who appear most.")
                        .font(.caption).foregroundStyle(Palette.ink2).frame(width: 260, alignment: .leading)
                    Spacer()
                    Button { share() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        .background(ShareAnchor(view: $anchor)).disabled(data == nil)
                    Button { copy() } label: { Label("Copy Image", systemImage: "doc.on.doc") }.disabled(data == nil)
                    Button { save() } label: { Label("Save PNG…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(data == nil)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 640).background(Palette.panel)
        .onAppear { title = request.title }
        .task {
            data = await gather()
            // Testing hook: write the rendered card to a file (same path as Save PNG).
            if let out = ProcessInfo.processInfo.environment["PIXORA_RECAP_OUT"], let png = pngData() {
                try? png.write(to: URL(fileURLWithPath: out))
                if let hero = data?.hero, let jpg = ImageLoader.jpegData(hero, quality: 0.8) {
                    try? jpg.write(to: URL(fileURLWithPath: out + ".hero.jpg"))
                }
            }
        }
    }

    /// Render at 2× (2160 × 2700 px).
    @MainActor private func render() -> CGImage? {
        guard let data else { return nil }
        let r = ImageRenderer(content: RecapCardView(title: title, data: data).frame(width: RecapCardView.size.width, height: RecapCardView.size.height))
        r.scale = 2
        return r.cgImage
    }

    private func pngData() -> Data? {
        guard let cg = render() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private var fileName: String { (title.isEmpty ? "Recap" : Exporter.safeName(title)) + " — recap.png" }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url, let png = pngData() else { return }
        do { try png.write(to: url) ; NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { model.errorMessage = "Could not save the card: \(error.localizedDescription)" }
    }

    private func share() {
        guard let png = pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? png.write(to: url)
        let picker = NSSharingServicePicker(items: [url])
        if let anchor { picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
    }

    private func copy() {
        guard let cg = render() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        model.toast = Toast(text: "Recap card copied", offersUndo: false)
    }

    /// Largest crop of the given aspect that contains the faces (with headroom), clamped to the image.
    nonisolated static func crop(_ image: CGImage, around faces: CGRect, aspect: CGFloat) -> CGImage {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let f = CGRect(x: faces.minX * W, y: faces.minY * H, width: faces.width * W, height: faces.height * H).insetBy(dx: -faces.width * W * 0.35, dy: -faces.height * H * 0.45)
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        // If the faces can't all fit in this shape (a wide group shot), keep the whole photo: the card fits it instead.
        if f.width > w || f.height > h { return image }
        // Shrink no further than needed to keep every face in frame.
        if f.width < w && f.height < h {
            let scale = max(f.width / w, f.height / h, 0.55)
            w *= scale; h *= scale
        }
        var x = f.midX - w / 2, y = f.midY - h / 2
        x = min(max(0, x), W - w); y = min(max(0, y), H - h)
        return image.cropping(to: CGRect(x: x, y: y, width: w, height: h).integral) ?? image
    }

    private func gather() async -> RecapData {
        let photos = request.photos, store = model.store
        let named = Dictionary(uniqueKeysWithValues: model.namedPeople.map { ($0.id, $0) })
        let roots = Dictionary(uniqueKeysWithValues: model.sources.filter(\.isOnline).map { ($0.id, $0.url) })
        let result = await Task.detached(priority: .userInitiated) { () -> (RecapData, [Int64]) in
            var d = RecapData()
            d.photoCount = photos.count
            let ids = photos.map(\.id)
            var faces: [(photo: Int64, person: Int64, quality: Double, sharp: Double, eyes: Double?)] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let q = chunk.map { _ in "?" }.joined(separator: ",")
                faces += (try? store.db.read { try $0.query(
                    "SELECT photo_id, person_id, COALESCE(quality, 0.5), COALESCE(sharpness, 0), eye_ratio FROM faces WHERE photo_id IN (\(q)) AND person_id IS NOT NULL AND state >= 2",
                    chunk) { ($0.int(0), $0.int(1), $0.double(2), $0.double(3), $0.optDouble(4)) } }) ?? []
            }
            faces = faces.filter { named[$0.person] != nil }
            // People who appear most.
            var counts: [Int64: Int] = [:]
            for f in faces { counts[f.person, default: 0] += 1 }
            d.peopleCount = counts.count
            let top = counts.sorted { $0.value > $1.value }.prefix(8).map(\.key)
            // Best shot: most named people, good faces, eyes open.
            var score: [Int64: Double] = [:]
            for f in faces {
                let eyes = (f.eyes.map { $0 < Enrichment.eyesClosedRatio } ?? false) ? 0.3 : 1.0
                score[f.photo, default: 0] += (0.5 + f.quality) * eyes
            }
            if let bestID = score.max(by: { $0.value < $1.value })?.key ?? ids.first,
               let best = photos.first(where: { $0.id == bestID }) {
                if let root = roots[best.sourceID] { d.hero = ImageLoader.image(at: root.appendingPathComponent(best.relPath), maxPixel: 2200) }
                if d.hero == nil, let src = CGImageSourceCreateWithURL(AppPaths.thumbnail(photoID: best.id) as CFURL, nil) {
                    d.hero = CGImageSourceCreateImageAtIndex(src, 0, nil)
                }
                // Frame the card's crop around the named people in it, not the middle of the photo.
                let rects = ((try? store.faces(photoID: best.id)) ?? []).filter { $0.personID.map { named[$0] != nil } ?? false }.map(\.rect)
                var union: CGRect?
                for r in rects { union = union.map { $0.union(r) } ?? r }
                if let hero = d.hero, let union {
                    d.hero = Self.crop(hero, around: union, aspect: 960.0 / 700.0)
                }
            }
            let dates = photos.compactMap(\.takenAt).sorted()
            if let first = dates.first, let last = dates.last {
                let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
                d.dateLine = Calendar.current.isDate(first, inSameDayAs: last) ? f.string(from: first) : "\(f.string(from: first)) – \(f.string(from: last))"
            }
            return (d, top)
        }.value
        var d = result.0
        for pid in result.1 {
            guard let p = named[pid] else { continue }
            var img: NSImage?
            if let face = p.coverFaceID {
                img = await ImageCache.shared.faceHiRes(face, side: 240, store: store, sourceRoot: { roots[$0] })
                if img == nil { img = await ImageCache.shared.faceThumb(face, store: store) }
            }
            d.faces.append((p.displayName, img))
        }
        return d
    }
}

/// The card itself. Fixed colours (not light/dark adaptive) so the exported image always looks the same.
struct RecapCardView: View {
    static let size = CGSize(width: 1080, height: 1350)
    let title: String
    let data: RecapData
    private let bg = Color(red: 0.07, green: 0.067, blue: 0.063)
    private let ink = Color(red: 0.95, green: 0.93, blue: 0.89)
    private let ink2 = Color(red: 0.66, green: 0.63, blue: 0.58)
    private let amber = Color(red: 0.94, green: 0.53, blue: 0.29)

    var body: some View {
        ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 0) {
                // Film-edge header
                HStack {
                    Text("▸ PIXORA · RECAP").font(.system(size: 20, weight: .semibold, design: .monospaced)).tracking(4).foregroundStyle(amber)
                    Spacer()
                    Text("\(data.photoCount) FR").font(.system(size: 20, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(ink2)
                }
                .padding(.bottom, 26)
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.05))
                    if let hero = data.hero {
                        let aspect = CGFloat(hero.width) / CGFloat(max(hero.height, 1))
                        if abs(aspect / (960.0 / 700.0) - 1) < 0.18 {
                            Image(decorative: hero, scale: 1).resizable().scaledToFill().frame(width: 960, height: 700).clipped()
                        } else {
                            // Different shape (wide group shot, portrait): whole photo over a soft blurred copy of itself.
                            // Each layer is pinned to the frame — an unpinned fill layer would enlarge the stack.
                            Image(decorative: hero, scale: 1).resizable().scaledToFill()
                                .frame(width: 960, height: 700).clipped().blur(radius: 40).opacity(0.55)
                            Image(decorative: hero, scale: 1).resizable().scaledToFit()
                                .frame(width: 960, height: 700).shadow(color: .black.opacity(0.5), radius: 20)
                        }
                    }
                }
                .frame(width: 960, height: 700)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text(title.isEmpty ? "Untitled shoot" : title)
                    .font(.system(size: 78, weight: .bold, design: .serif)).foregroundStyle(ink)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.top, 38)
                Text(data.dateLine.uppercased()).font(.system(size: 22, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(ink2)
                    .padding(.top, 10)
                HStack(spacing: 16) {
                    stat("\(data.photoCount)", "photos")
                    Rectangle().fill(ink2.opacity(0.4)).frame(width: 2, height: 46)
                    stat("\(data.peopleCount)", data.peopleCount == 1 ? "person" : "people")
                }
                .padding(.top, 26)
                Spacer(minLength: 20)
                HStack(spacing: 18) {
                    ForEach(Array(data.faces.prefix(7).enumerated()), id: \.offset) { _, f in
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.08))
                                if let img = f.image { Image(nsImage: img).resizable().scaledToFill() }
                            }
                            .frame(width: 112, height: 112).clipShape(Circle())
                            .overlay(Circle().strokeBorder(amber.opacity(0.8), lineWidth: 3))
                            Text(f.name.replacingOccurrences(of: "_", with: " ")).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ink).lineLimit(1).frame(width: 120)
                        }
                    }
                }
            }
            .padding(60)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(v).font(.system(size: 54, weight: .semibold, design: .serif)).foregroundStyle(ink)
            Text(l.uppercased()).font(.system(size: 20, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(ink2)
        }
    }
}
