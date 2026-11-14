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
/// question beside it. Y yes, N no, → skip, ← back, Z zoom to the face, Esc closes. Answering moves on to the
/// next face; the screen closes after the last one.
struct ReviewFullScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ReviewFullRequest
    @State private var index = 0
    @State private var answered: Set<Int64> = []
    @State private var photo: Photo?
    @State private var image: NSImage?
    @State private var isPreview = false
    @State private var zoomed = false
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
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { _ in withAnimation(Motion.quick) { zoomed.toggle() }; return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onExitCommand { close() }
        .onAppear { index = min(max(0, request.start), max(0, request.faces.count - 1)); focused = true }
        .task(id: face?.id) { await load() }
    }

    // MARK: Photo

    private func stage(_ face: Face) -> some View {
        GeometryReader { geo in
            let area = geo.size
            if let image {
                let fit = fitted(image.size, in: CGSize(width: area.width - 48, height: area.height - 96))
                let box = CGRect(x: face.rect.minX * fit.width, y: face.rect.minY * fit.height,
                                 width: face.rect.width * fit.width, height: face.rect.height * fit.height)
                // Zoom so the face fills about a third of the height, centred on it.
                // Zoom so the face fills about half the height (at least 1.6×), centred on it as far as the photo's
                // edges allow, so the zoomed photo never slides off and leaves empty space.
                let scale = zoomed ? min(6, max(1.6, fit.height * 0.5 / max(box.height, 1))) : 1
                let maxX = max(0, (fit.width * scale - area.width) / 2), maxY = max(0, (fit.height * scale - area.height) / 2)
                let shift = zoomed ? CGSize(width: min(maxX, max(-maxX, (fit.width / 2 - box.midX) * scale)),
                                            height: min(maxY, max(-maxY, (fit.height / 2 - box.midY) * scale))) : .zero
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: fit.width, height: fit.height)
                    // Dim everything except the face in question.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: fit))
                        p.addRoundedRect(in: box.insetBy(dx: -box.width * 0.125, dy: -box.height * 0.125),
                                         cornerSize: CGSize(width: box.width * 0.12, height: box.width * 0.12))
                    }
                    .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    RoundedRectangle(cornerRadius: box.width * 0.12)
                        .strokeBorder(Palette.safelight, lineWidth: 3 / scale)
                        .frame(width: box.width * 1.25, height: box.height * 1.25)
                        .position(x: box.midX, y: box.midY)
                        .shadow(color: Palette.safelight.opacity(0.6), radius: 8 / scale)
                }
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(scale)
                .offset(shift)
                .frame(width: area.width, height: area.height)
                .clipped()
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: zoomed)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation(Motion.quick) { zoomed.toggle() } }
                .accessibilityLabel("The photo, with the face in question outlined")
            } else {
                ProgressView().controlSize(.large).tint(.white).frame(width: area.width, height: area.height)
            }
        }
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
                    Button { withAnimation(Motion.quick) { zoomed.toggle() } } label: {
                        Label(zoomed ? "Fit" : "Zoom", systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.regular)
            }
            .disabled(done)
            Text("Y yes · N no · → skip · ← back · Z zoom · Esc close").font(.caption).foregroundStyle(.white.opacity(0.5))
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
            zoomed = false
            index = next
        } else {
            close()
        }
    }

    private func step(_ d: Int) {
        let next = index + d
        guard request.faces.indices.contains(next) else { return }
        zoomed = false
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
