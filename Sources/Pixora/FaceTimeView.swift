import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixoraCore

struct FaceTimeRequest: Identifiable {
    let id = UUID()
    let personID: Int64
    let name: String
}

/// The reel's frames. Separate from the view so that a frame getting sharper doesn't redraw the whole screen.
@MainActor @Observable
final class FaceTimeReel {
    var moments: [FaceMoment] = []
    var frames: [Int64: CGImage] = [:]
    var glows: [Int64: CGImage] = [:]
    var loaded = false
    var sharpened = 0
    /// Some frames are only as sharp as the stored thumbnail because the card or drive isn't connected.
    var offline = false

    func load(person: Int64, model: AppModel, ready: () -> Void) async {
        let store = model.store
        let plan = await Task.detached(priority: .userInitiated) { () -> [FaceMoment] in
            FaceTimeline.plan((try? FaceTimeline.moments(personID: person, store: store)) ?? [])
        }.value
        moments = plan
        // The face thumbnails in the library are already lined up by the eyes, so the reel works straight away.
        let thumbs = await Task.detached(priority: .userInitiated) { () -> [(Int64, CGImage, CGImage?)] in
            plan.compactMap { m in
                guard let data = try? store.faceThumb(id: m.faceID), let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return (m.faceID, cg, AmbientBackdrop.make(from: cg))
            }
        }.value
        for (id, frame, glow) in thumbs { frames[id] = frame; glows[id] = glow }
        moments = plan.filter { frames[$0.faceID] != nil }
        let roots = Dictionary(uniqueKeysWithValues: model.sources.filter(\.isOnline).map { ($0.id, $0.url) })
        offline = moments.contains { roots[$0.photo.sourceID] == nil }
        loaded = true
        ready()

        // Then each one is redone from the original, if it's connected, for a sharp frame.
        for m in moments {
            if Task.isCancelled { return }
            guard let root = roots[m.photo.sourceID] else { continue }
            let url = root.appendingPathComponent(m.photo.relPath), rect = m.rect
            let sharp = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let image = ImageLoader.image(at: url, maxPixel: 2600) else { return nil }
                return FaceFrames.frame(from: image, face: rect, side: 1080)
            }.value
            if let sharp { frames[m.faceID] = sharp; sharpened += 1 }
        }
    }
}

/// A person through the years: every frame lined up on the eyes, so dragging along the timeline shows one face
/// changing. Nothing here is saved anywhere unless the video is exported.
struct FaceTimeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: FaceTimeRequest
    @State private var reel = FaceTimeReel()
    @State private var position = 0.0
    @State private var playing = false
    @State private var exporting: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var savedTo: URL?
    @State private var lastTick = -1
    @FocusState private var focused: Bool

    private var last: Double { Double(max(0, reel.moments.count - 1)) }
    private var index: Int { Int(position.rounded()) }

    var body: some View {
        ZStack {
            FaceRoom(reel: reel, position: position)
            if !reel.loaded {
                ProgressView().controlSize(.large).tint(.white)
            } else if reel.moments.count < 2 {
                empty
            } else {
                VStack(spacing: 0) {
                    topBar
                    GeometryReader { g in
                        // Thumbnails only have so much detail: with the card out, the frame stays small enough to look sharp.
                        let side = min(g.size.height - 16, g.size.width - 120, reel.offline ? 470 : 760)
                        FaceStage(reel: reel, position: position, side: max(120, side))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    caption
                    FaceTimelineBar(reel: reel, position: $position, scrubbed: scrubbed, ended: settle)
                    controls
                }
            }
        }
        .background(ScrollMonitor(onScroll: { dx in
            guard reel.loaded else { return }
            playing = false
            scrub(to: position - Double(dx) / 26)
        }, onEnd: { settle() }))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePlay(); return .handled }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in playing = false; step(-1); return .handled }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in playing = false; step(1); return .handled }
        .onExitCommand { close() }
        .onAppear { focused = true }
        .task { await reel.load(person: request.personID, model: model, ready: { autoplay() }) }
        .task(id: playing) { await play() }
        .onDisappear { exportTask?.cancel() }
    }

    private func autoplay() {
        #if PIXORA_UI_TESTING
        let env = ProcessInfo.processInfo.environment
        if let path = env["PIXORA_TEST_FACE_VIDEO"] { saveVideo(to: URL(fileURLWithPath: path)) }
        if let at = env["PIXORA_TEST_FACE_AT"].flatMap(Double.init) { position = last * at; return }
        #endif
        if !reduceMotion && reel.moments.count > 2 { playing = true }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.7))
            Text("Not enough photos yet").font(Typography.display(24)).foregroundStyle(.white)
            Text("Through Time needs at least two dated photos of \(request.name) facing the camera.").font(.callout).foregroundStyle(.white.opacity(0.7))
            Button("Close") { close() }.keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            CloseCircle(help: "Close (Esc)") { close() }
            VStack(alignment: .leading, spacing: 1) {
                Text(request.name).font(Typography.display(18)).foregroundStyle(.white)
                EdgeLabel("Through Time · \(FaceTimeline.spanLabel(reel.moments))", color: .white.opacity(0.6))
            }
            Spacer()
            if reel.offline {
                Label("Connect the card for sharper frames", systemImage: "sdcard").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var caption: some View {
        let m = reel.moments[min(index, reel.moments.count - 1)]
        return Text(Self.label(for: m.date, in: reel.moments))
            .font(Typography.display(26)).foregroundStyle(.white).monospacedDigit()
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .padding(.top, 8).padding(.bottom, 12)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// The date at a useful grain: the time for a single day, the day for a single year, otherwise month and year.
    static func label(for date: Date, in moments: [FaceMoment]) -> String {
        guard let a = moments.first?.date, let b = moments.last?.date else { return "" }
        let f = DateFormatter()
        if Calendar.current.isDate(a, inSameDayAs: b) { f.dateFormat = "h:mm a" }
        else if b.timeIntervalSince(a) < 86_400 * 400 { f.dateFormat = "d MMMM" }
        else { f.dateFormat = "MMMM yyyy" }
        return f.string(from: date)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Spacer()
            Button { togglePlay() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).frame(width: 46, height: 46)
                    .contentTransition(.symbolEffect(.replace))
                    .background(Circle().fill(.white)).foregroundStyle(.black)
            }
            .buttonStyle(.plain).hoverLift(scale: 1.07, radius: 23).help(playing ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(playing ? "Pause" : "Play")
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Group {
                if let exporting {
                    HStack(spacing: 10) {
                        ProgressView(value: exporting).frame(width: 110).tint(.white)
                        Button("Cancel") { exportTask?.cancel() }.buttonStyle(GlassButtonStyle())
                    }
                } else if let savedTo {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([savedTo]) } label: { Label("Show in Finder", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(GlassButtonStyle())
                } else {
                    Button { exportVideo() } label: { Label("Save Video…", systemImage: "film") }.buttonStyle(GlassButtonStyle())
                        .help("Saves this reel as a movie, wherever you choose")
                }
            }
            .padding(.trailing, 24)
        }
        .padding(.bottom, 18)
    }

    // MARK: Moving along the reel

    private func scrubbed(_ to: Double) { playing = false; scrub(to: to) }

    private func scrub(to value: Double) {
        position = min(last, max(0, value))
        #if PIXORA_UI_TESTING
        if ProcessInfo.processInfo.environment["PIXORA_TEST_FACE_LOG"] != nil { fputs("REHEARSAL reel at \(position)\n", stderr) }
        #endif
        let frame = index
        if frame != lastTick {
            // A tap from the trackpad at each new year or month, so the timeline can be felt.
            if lastTick >= 0, reel.moments.indices.contains(frame), reel.moments.indices.contains(lastTick),
               Self.boundary(reel.moments[lastTick].date, reel.moments[frame].date, in: reel.moments) { Haptics.tick() }
            lastTick = frame
        }
    }

    static func boundary(_ a: Date, _ b: Date, in moments: [FaceMoment]) -> Bool {
        guard let first = moments.first?.date, let last = moments.last?.date else { return false }
        let c = Calendar.current
        let unit: Calendar.Component = c.component(.year, from: first) != c.component(.year, from: last) ? .year : (c.isDate(first, inSameDayAs: last) ? .hour : .month)
        return c.component(unit, from: a) != c.component(unit, from: b)
    }

    /// Lets go on the nearest face rather than halfway between two.
    private func settle() {
        guard !playing else { return }
        withAnimation(.easeOut(duration: 0.18)) { position = position.rounded() }
    }

    private func step(_ d: Int) { withAnimation(.easeOut(duration: 0.16)) { scrub(to: position.rounded() + Double(d)) } }

    private func togglePlay() {
        if !playing && position >= last { position = 0 }
        playing.toggle()
    }

    /// About two and a half faces a second, resting briefly on each.
    private func play() async {
        guard playing else { return }
        var previous = Date()
        while playing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = Date()
            let dt = now.timeIntervalSince(previous)
            previous = now
            let next = position + dt * 2.4
            if next >= last { scrub(to: last); playing = false; return }
            scrub(to: next)
        }
    }

    private func close() {
        exportTask?.cancel()
        model.faceTime = nil
    }

    private func exportVideo() {
        playing = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(request.name) Through Time.mov"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveVideo(to: url)
    }

    private func saveVideo(to url: URL) {
        let moments = reel.moments
        let frames = moments.compactMap { m in reel.frames[m.faceID].map { FaceTimeVideo.Frame(image: $0, caption: Self.label(for: m.date, in: moments)) } }
        let title = request.name
        exporting = 0
        savedTo = nil
        exportTask = Task {
            do {
                try await FaceTimeVideo.write(frames, title: title, to: url) { p in Task { @MainActor in if exporting != nil { exporting = p } } }
                savedTo = url
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            exporting = nil
        }
    }
}

/// The room takes on the colour of the face that's showing, dissolving between them along with the frames.
private struct FaceRoom: View {
    let reel: FaceTimeReel
    let position: Double
    var body: some View {
        let a = Int(position), mix = position - Double(a)
        let moments = reel.moments
        ZStack {
            Color(white: 0.04)
            if moments.indices.contains(a) {
                AmbientGlow(image: reel.glows[moments[a].faceID])
                if moments.indices.contains(a + 1) { AmbientGlow(image: reel.glows[moments[a + 1].faceID]).opacity(mix) }
            }
            RoomGrain()
            Vignette(strength: 0.7)
        }
        .ignoresSafeArea()
    }
}

private struct FaceStage: View {
    let reel: FaceTimeReel
    let position: Double
    let side: CGFloat

    var body: some View {
        let a = Int(position), mix = position - Double(a)
        // Holds on each face and dissolves in the second half of the gap, so it reads as photos, not as mush.
        let blend = max(0, min(1, (mix - 0.35) / 0.65))
        let moments = reel.moments
        ZStack {
            if moments.indices.contains(a), let image = reel.frames[moments[a].faceID] { frame(image) }
            if moments.indices.contains(a + 1), blend > 0, let image = reel.frames[moments[a + 1].faceID] { frame(image).opacity(blend) }
        }
        .frame(width: side, height: side)
        // Closer than the frame itself, and darkening to the edges: the face fills it, and a photo that stops short of
        // the frame (a face near the edge of the shot) fades out instead of ending in a hard black corner.
        .overlay { RadialGradient(stops: [.init(color: .clear, location: 0.62), .init(color: .black.opacity(0.7), location: 1)], center: .center, startRadius: 0, endRadius: side * 0.74) }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .background { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.55), radius: 36, y: 18) }
        .accessibilityLabel("Face at this point in time")
    }

    private func frame(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: side, height: side).scaleEffect(1.22)
    }
}

/// The reel laid out as a strip of tiny faces with a playhead: drag anywhere along it.
private struct FaceTimelineBar: View {
    let reel: FaceTimeReel
    @Binding var position: Double
    let scrubbed: (Double) -> Void
    let ended: () -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, count = reel.moments.count
            let at = count > 1 ? position / Double(count - 1) : 0
            ZStack(alignment: .leading) {
                FaceStrip(reel: reel, width: w)
                Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, w * (1 - at))).frame(maxWidth: .infinity, alignment: .trailing)
                    .allowsHitTesting(false)
                Capsule().fill(.white).frame(width: 3, height: 62).shadow(color: .black.opacity(0.5), radius: 4)
                    .offset(x: w * at - 1.5)
            }
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.3 : 0.14)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                scrubbed(min(1, max(0, v.location.x / max(w, 1))) * Double(max(0, count - 1)))
            }.onEnded { _ in ended() })
            .onHover { hovering = $0 }
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue("Photo \(Int(position.rounded()) + 1) of \(count)")
            .accessibilityAdjustableAction { d in
                scrubbed(position.rounded() + (d == .increment ? 1 : -1))
            }
        }
        .frame(height: 54)
        .padding(.horizontal, 48).padding(.bottom, 14)
    }
}

/// Drawn once: it doesn't depend on the playhead, so scrubbing never redraws it.
private struct FaceStrip: View, Equatable {
    let reel: FaceTimeReel
    let width: CGFloat
    static func == (a: FaceStrip, b: FaceStrip) -> Bool { a.width == b.width && a.reel === b.reel }

    var body: some View {
        let count = max(1, min(reel.moments.count, Int(width / 40)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let m = reel.moments[i * reel.moments.count / count]
                if let image = reel.frames[m.faceID] {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFill()
                        .frame(width: width / CGFloat(count), height: 54).clipped()
                }
            }
        }
        .frame(width: width, height: 54)
    }
}

/// Two-finger sideways scrolling anywhere on the screen moves along the reel, with momentum.
private struct ScrollMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onEnd: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.parent = self
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event)
            return event
        }
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    @MainActor final class Coordinator {
        var parent: ScrollMonitor?
        var monitor: Any?
        func handle(_ event: NSEvent) {
            guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return }
            if event.scrollingDeltaX != 0 { parent?.onScroll(event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 8)) }
            if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase == []) { parent?.onEnd() }
        }
    }
}
