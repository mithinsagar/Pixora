import SwiftUI
import AppKit
import PixoraCore

struct ReviewFullRequest: Identifiable {
    let id = UUID()
    /// Uncertain faces to go through, in order; starts at `start`.
    let faces: [Face]
    let start: Int
}

/// Uncertain matches reviewed over the whole window: the full photo with the face in question outlined, and the
/// question beside it. Y yes, N no, → skip, ← back, Z zoom to the face, Esc closes. Pinch or the mouse wheel zooms
/// at the pointer; two fingers or a drag move around when zoomed in; double-click toggles zoom. Answering moves on
/// to the next face; the screen closes after the last one.
struct ReviewFullScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ReviewFullRequest
    @State private var index = 0
    @State private var answered: Set<Int64> = []
    @State private var photo: Photo?
    @State private var image: NSImage?
    @State private var isPreview = false
    @State private var zoom = ViewerZoom()
    @State private var stageSize: CGSize = .zero
    @FocusState private var focused: Bool

    private var face: Face? { request.faces.indices.contains(index) ? request.faces[index] : nil }
    private var remaining: Int { request.faces.filter { !answered.contains($0.id) }.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let face {
                HStack(spacing: 0) {
                    stage(face).frame(maxWidth: .infinity, maxHeight: .infinity)
                    panel(face).frame(width: 320)
                }
            }
        }
        .overlay(alignment: .topLeading) { topBar }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "yY")) { _ in answer(true); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "nN")) { _ in answer(false); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { _ in toggleFaceZoom(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in zoomTo(zoom.scale * 1.5, around: .zero, animated: true); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in zoomTo(zoom.scale / 1.5, around: .zero, animated: true); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in zoomTo(1, around: .zero, animated: true); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onExitCommand { close() }
        .onAppear { index = min(max(0, request.start), max(0, request.faces.count - 1)); focused = true }
        .task(id: face?.id) { await load() }
    }

    // MARK: Photo

    private func stage(_ face: Face) -> some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    photoLayer(face, image)
                        .frame(width: fit.width, height: fit.height)
                        .scaleEffect(zoom.scale)
                        .offset(zoom.offset)
                        .allowsHitTesting(false)
                        .accessibilityLabel("The photo, with the face in question outlined")
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
                // Trackpad and mouse, the same as the photo viewer: pinch or wheel zooms at the pointer, two fingers
                // or a drag pan when zoomed in, double-click or two-finger double-tap toggles zoom.
                PhotoGestureSurface(zoomed: zoom.isZoomed,
                                    onZoom: { delta, p in zoomTo(zoom.scale * (1 + delta), around: p) },
                                    onZoomEnded: { if zoom.scale < 1.05 { zoomTo(1, around: .zero, animated: true) } },
                                    onPan: { zoom.pan(by: $0, image: fit, viewport: stageSize) },
                                    onToggle: { p in zoomTo(zoom.isZoomed ? 1 : ViewerZoom.toggleScale, around: p, animated: true) },
                                    wheelZooms: true)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .bottom) { zoomBar.padding(.bottom, 16) }
            .onAppear { stageSize = geo.size }
            .onChange(of: geo.size) { _, size in stageSize = size; zoom.pan(by: .zero, image: fit, viewport: size) }
        }
    }

    /// The photo with everything but the face in question dimmed, and that face outlined.
    private func photoLayer(_ face: Face, _ image: NSImage) -> some View {
        let box = CGRect(x: face.rect.minX * fit.width, y: face.rect.minY * fit.height,
                         width: face.rect.width * fit.width, height: face.rect.height * fit.height)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: fit.width, height: fit.height)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: fit))
                p.addRoundedRect(in: box.insetBy(dx: -box.width * 0.125, dy: -box.height * 0.125),
                                 cornerSize: CGSize(width: box.width * 0.12, height: box.width * 0.12))
            }
            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: box.width * 0.12)
                .strokeBorder(Palette.safelight, lineWidth: 3 / zoom.scale)
                .frame(width: box.width * 1.25, height: box.height * 1.25)
                .position(x: box.midX, y: box.midY)
                .shadow(color: Palette.safelight.opacity(0.6), radius: 8 / zoom.scale)
        }
    }

    /// − 100% + and Fit, over the bottom of the photo.
    private var zoomBar: some View {
        HStack(spacing: 4) {
            zoomButton("minus", "Zoom out (−)", enabled: zoom.isZoomed) { zoomTo(zoom.scale / 1.5, around: .zero, animated: true) }
            Button { zoomTo(1, around: .zero, animated: true) } label: {
                Text("\(Int((zoom.scale * 100).rounded()))%").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white).frame(minWidth: 52, minHeight: 28)
            }
            .buttonStyle(.plain)
            .help("Fit the whole photo (0)")
            zoomButton("plus", "Zoom in (+)", enabled: zoom.scale < ViewerZoom.maxScale) { zoomTo(zoom.scale * 1.5, around: .zero, animated: true) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func zoomButton(_ symbol: String, _ help: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var fit: CGSize {
        guard let image else { return .zero }
        return fitted(image.size, in: CGSize(width: max(1, stageSize.width - 48), height: max(1, stageSize.height - 96)))
    }

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9) }

    private func zoomTo(_ scale: CGFloat, around point: CGPoint, animated: Bool = false) {
        guard image != nil else { return }
        withAnimation(animated ? spring : nil) { zoom.zoom(to: scale, around: point, image: fit, viewport: stageSize) }
    }

    /// Z or the Zoom button: fill about half the height with the face and centre it (as far as the photo's edges
    /// allow). Again to see the whole photo.
    private func toggleFaceZoom() {
        guard let face, image != nil else { return }
        if zoom.isZoomed { withAnimation(spring) { zoom = ViewerZoom() }; return }
        let s = min(ViewerZoom.maxScale, max(1.6, 0.5 / max(face.rect.height, 0.01)))
        let p = CGPoint(x: (face.rect.midX - 0.5) * fit.width, y: (face.rect.midY - 0.5) * fit.height)
        var z = ViewerZoom()
        z.zoom(to: s, around: .zero, image: fit, viewport: stageSize)
        z.pan(by: CGSize(width: -p.x * s, height: -p.y * s), image: fit, viewport: stageSize)
        withAnimation(spring) { zoom = z }
    }

    private func fitted(_ size: NSSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    // MARK: Question

    private func panel(_ face: Face) -> some View {
        let person = model.person(face.personID)
        let name = person?.displayName ?? "them"
        let done = answered.contains(face.id)
        return VStack(alignment: .leading, spacing: 18) {
            Spacer()
            EdgeLabel("\(index + 1) of \(request.faces.count) · \(remaining) left", color: .white.opacity(0.6))
            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    FaceImage(faceID: face.id, size: 104, shape: AnyShape(Circle()))
                    EdgeLabel("This face", color: .white.opacity(0.6))
                }
                Image(systemName: "questionmark").font(.title2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                VStack(spacing: 6) {
                    FaceImage(faceID: person?.coverFaceID, size: 104, shape: AnyShape(Circle()))
                    EdgeLabel(name, color: .white.opacity(0.6))
                }
            }
            Text(done ? "Answered" : "Is this \(name)?").font(Typography.display(28)).foregroundStyle(.white)
            if let s = face.score { EdgeLabel("Similarity \(Int(s * 100))", color: .white.opacity(0.5)) }
            if isPreview {
                Label("Original not connected: showing the saved preview", systemImage: "externaldrive.badge.xmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { answer(false) } label: { Label("No", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .controlSize(.large)
                    Button { answer(true) } label: { Label("Yes", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                HStack(spacing: 10) {
                    Button { step(-1) } label: { Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity) }.disabled(index == 0)
                    Button { step(1) } label: { Label("Skip", systemImage: "chevron.right").frame(maxWidth: .infinity) }
                    Button { toggleFaceZoom() } label: {
                        Label(zoom.isZoomed ? "Fit" : "Face", systemImage: zoom.isZoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.regular)
            }
            .disabled(done)
            VStack(alignment: .leading, spacing: 3) {
                Text("Y yes · N no · → skip · ← back · Esc close")
                Text("Pinch or scroll to zoom · drag to move · Z zoom to the face")
            }
            .font(.caption).foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .padding(24)
        .background(Color.white.opacity(0.06))
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            Text("Review").font(Typography.display(17)).foregroundStyle(.white)
        }
        .padding(.leading, 20).padding(.top, 18)
    }

    // MARK: Actions

    private func answer(_ yes: Bool) {
        guard let face, !answered.contains(face.id) else { return }
        answered.insert(face.id)
        if yes { model.confirm([face.id]) } else { model.reject([face.id]) }
        // Next unanswered face after this one, wrapping round; close when none are left.
        let order = Array(request.faces.indices.dropFirst(index + 1)) + Array(request.faces.indices.prefix(index))
        if let next = order.first(where: { !answered.contains(request.faces[$0].id) }) {
            zoom = ViewerZoom()
            index = next
        } else {
            close()
        }
    }

    private func step(_ d: Int) {
        let next = index + d
        guard request.faces.indices.contains(next) else { return }
        zoom = ViewerZoom()
        index = next
    }

    private func close() { model.reviewFull = nil }

    private func load() async {
        guard let face else { return }
        image = nil
        guard let p = try? model.store.photos(ids: [face.photoID]).first else { return }
        photo = p
        let root = model.source(p.sourceID)?.url
        if let full = await ViewerCache.shared.image(for: p, root: root) {
            image = full; isPreview = false
        } else {
            image = await ImageCache.shared.photoThumb(p, sourceRoot: root); isPreview = true
        }
    }
}
