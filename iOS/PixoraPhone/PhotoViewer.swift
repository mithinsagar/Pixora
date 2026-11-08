import SwiftUI
import PixoraCore

/// Full-screen photo viewer: swipe between photos, pinch or double-tap to zoom, pull down to close.
struct PhotoViewer: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ViewerRequest
    @State private var current: Int64?
    @State private var chrome = true
    @State private var pull: CGFloat = 0
    @State private var zoomed = false
    @State private var showInfo = false
    @State private var askSetup = false

    private var photo: Photo? { request.photos.first { $0.id == current } ?? request.photos.first }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(1 - Double(min(1, abs(pull) / 400))).ignoresSafeArea()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(request.photos) { p in
                            ZoomablePhoto(photo: p, zoomed: $zoomed, onTap: { withAnimation(Motion.quick) { chrome.toggle() } })
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(p.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)
                .scrollDisabled(zoomed)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .offset(y: pull)
                .simultaneousGesture(zoomed ? nil : DragGesture(minimumDistance: 20)
                    .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { pull = v.translation.height } }
                    .onEnded { v in
                        if abs(v.translation.height) > 140 { dismiss() } else { withAnimation(Motion.spring) { pull = 0 } }
                    })
                if chrome { topBar.transition(.opacity); bottomBar.transition(.opacity) }
            }
        }
        .statusBarHidden(!chrome)
        .onAppear { current = request.photos[request.index].id }
        .sheet(isPresented: $showInfo) { if let photo { PhotoInfoSheet(photo: photo) } }
        .alert("Set up Private Space first", isPresented: $askSetup) {
            Button("Set Up") { dismiss(); model.tab = .privateSpace }
            Button("Not Now", role: .cancel) {}
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("viewer.close")
                VStack(alignment: .leading, spacing: 1) {
                    Text(photo?.takenAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? (photo?.filename ?? ""))
                        .font(.subheadline.weight(.semibold))
                    if let i = request.photos.firstIndex(where: { $0.id == current }) {
                        Text("\(i + 1) of \(request.photos.count)").font(.caption).opacity(0.7)
                    }
                }
                .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 12)
            if let photo, model.isOffline(photo) {
                Label("Original not on this iPhone, showing the saved preview", systemImage: "externaldrive.badge.xmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.orange.opacity(0.85)))
                    .accessibilityIdentifier("viewer.offline")
            }
            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            if let photo {
                let names = model.namesInPhoto(photo.id)
                if !names.isEmpty {
                    Text(ListFormatter.localizedString(byJoining: names)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(.ultraThinMaterial))
                        .padding(.bottom, 8)
                }
                HStack(spacing: 0) {
                    if photo.id > 0 {
                        bar(model.favorites.contains(photo.id) ? "heart.fill" : "heart", model.favorites.contains(photo.id) ? "Remove favourite" : "Favourite") {
                            model.toggleFavorite([photo])
                        }
                    }
                    bar("square.and.arrow.up", "Share") { model.share = ShareRequest(photos: [photo]) }
                    bar("info.circle", "Info") { showInfo = true }
                    if photo.id > 0 {
                        bar("lock", "Make private") {
                            if model.isPrivateSetUp { model.makePrivate(photos: [photo]) } else { askSetup = true }
                        }
                    } else {
                        bar("lock.open", "Move to library") { model.moveToLibrary(photos: [photo]); dismiss() }
                    }
                }
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
        }
    }

    private func bar(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// One page of the viewer. Pinch to zoom, double-tap to toggle 2.5×, drag to pan while zoomed.
private struct ZoomablePhoto: View {
    @Environment(PhoneModel.self) private var model
    let photo: Photo
    @Binding var zoomed: Bool
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale).offset(offset)
                    .accessibilityLabel(model.describe(photo))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(MagnifyGesture()
            .onChanged { v in scale = max(1, min(6, base * v.magnification)); zoomed = scale > 1.01 }
            .onEnded { _ in base = scale; if scale <= 1.01 { reset() } })
        .simultaneousGesture(scale > 1.01 ? DragGesture()
            .onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height) }
            .onEnded { _ in baseOffset = offset } : nil)
        .onTapGesture(count: 2) {
            withAnimation(Motion.spring) { if scale > 1.01 { reset() } else { scale = 2.5; base = 2.5; zoomed = true } }
        }
        .onTapGesture { onTap() }
        .task(id: photo.id) {
            if image == nil, let thumb = await PhotoImages.shared.thumbnail(photo, sourceRoot: model.source(photo.sourceID)?.url) { image = thumb }
            if let full = await PhotoImages.shared.full(photo, sourceRoot: model.source(photo.sourceID)?.url) { image = full.image }
        }
        .onDisappear { reset() }
    }

    private func reset() { scale = 1; base = 1; offset = .zero; baseOffset = .zero; zoomed = false }
}

/// Details of a photo: date, camera, file, where the original is, and the faces in it.
struct PhotoInfoSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photo: Photo
    @State private var faces: [Face] = []
    @State private var assigning: Face?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Taken", photo.takenAt.map { $0.formatted(date: .long, time: .shortened) } ?? "Unknown")
                    row("File", photo.filename)
                    if let w = photo.width, let h = photo.height { row("Size", "\(w) × \(h) · \(Format.size(photo.fileSize))") }
                    if let c = photo.camera { row("Camera", c) }
                    if let l = photo.lens { row("Lens", l) }
                }
                Section("Original") {
                    if let s = model.source(photo.sourceID) {
                        row("From", s.name)
                        Label(s.isOnline ? "Available on this iPhone" : "Not connected. Plug in the card or drive, then reconnect it in Library.",
                              systemImage: s.isOnline ? "checkmark.circle" : "externaldrive.badge.xmark")
                            .foregroundStyle(s.isOnline ? Palette.confirmed : Palette.warning)
                    }
                }
                if !faces.isEmpty {
                    Section("People in this photo") {
                        ForEach(faces) { f in
                            Button { if f.id > 0 { assigning = f } } label: {
                                HStack(spacing: 12) {
                                    FaceImage(faceID: f.id, size: 44)
                                    VStack(alignment: .leading) {
                                        Text(model.person(f.personID)?.displayName ?? "Unknown").foregroundStyle(Palette.ink)
                                        Text(f.state == .suggested ? "Unsure" : (f.state.isCertain ? "Matched" : "Not matched")).font(.caption).foregroundStyle(Palette.ink2)
                                    }
                                    Spacer()
                                    if f.id > 0 { Text("Change").font(.caption.weight(.semibold)).foregroundStyle(Palette.safelight) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { faces = photo.id < 0 ? (model.privateContent?.items.first { $0.photo.id == photo.id }?.faces ?? []) : ((try? model.store.faces(photoID: photo.id)) ?? []) }
            .sheet(item: $assigning) { AssignSheet(face: $0) }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Palette.ink2); Spacer(); Text(v).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing) }
    }
}
