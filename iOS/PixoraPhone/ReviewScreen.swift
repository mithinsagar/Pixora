import SwiftUI
import PixoraCore

/// Unsure matches, one at a time: "Is this Ana?" Yes / No / Skip. Swipe right for yes, left for no.
struct ReviewScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queue: [Face] = []
    @State private var skipped: Set<Int64> = []
    @State private var drag: CGSize = .zero
    @State private var loading = true
    @State private var assigning: Face?
    @State private var answered = 0
    /// The faces full-screen review goes through, fixed when it opens so answers don't reshuffle it.
    @State private var fullFaces: [Face]?

    /// Only questions that can be asked: the suggested person must be visible (not private while locked).
    private var answerable: [Face] { queue.filter { !skipped.contains($0.id) && model.person($0.personID) != nil } }
    private var current: Face? { answerable.first }

    var body: some View {
        NavigationStack {
            Group {
                if loading && queue.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let face = current, let person = model.person(face.personID) {
                    VStack(spacing: 18) {
                        Subtitle(text: "\(Format.count(answerable.count, "face")) Pixora wasn’t sure about. Your answers teach it.")
                        card(face, person).id(face.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                        Button { fullFaces = answerable } label: {
                            Label("Review on the whole photo", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("review.fullscreen")
                        Spacer(minLength: 0)
                        answers(face, person)
                    }
                    .padding(16)
                    .animation(Motion.spring, value: face.id)
                } else {
                    EmptyState(symbol: "checkmark.seal", title: "All caught up",
                               message: skipped.isEmpty
                               ? "Nothing to check right now. New unsure matches appear here after each scan."
                               : "You skipped \(Format.count(skipped.count, "face")). They’ll be here next time.",
                               actionTitle: skipped.isEmpty ? nil : "Show Skipped", action: skipped.isEmpty ? nil : { skipped = [] })
                        .frame(maxHeight: .infinity)
                }
            }
            .canvas()
            .navigationTitle("Review")
            .task(id: model.stats.uncertainItems) { await load() }
            .sheet(item: $assigning) { AssignSheet(face: $0) }
            .fullScreenCover(isPresented: Binding(get: { fullFaces != nil }, set: { if !$0 { fullFaces = nil } })) {
                ReviewFullScreen(faces: fullFaces ?? [], start: 0) { id in queue.removeAll { $0.id == id } }
            }
        }
    }

    private func card(_ face: Face, _ person: Person) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                VStack(spacing: 6) {
                    FaceImage(faceID: face.id, size: 132)
                        .onTapGesture { fullFaces = answerable }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens the whole photo full screen")
                    EdgeLabel("This face")
                }
                Image(systemName: "questionmark").font(.title2.weight(.bold)).foregroundStyle(Palette.ink2)
                VStack(spacing: 6) {
                    FaceImage(faceID: person.coverFaceID, size: 132)
                    EdgeLabel(person.displayName)
                }
            }
            Text("Is this \(person.displayName)?").font(Typo.display(.title)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
            if let s = face.score { EdgeLabel("Similarity \(Int(s * 100))") }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.card))
        .overlay(alignment: .topLeading) { stamp("YES", Palette.confirmed, visible: drag.width > 40).padding(18) }
        .overlay(alignment: .topTrailing) { stamp("NO", .red, visible: drag.width < -40).padding(18) }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .offset(x: reduceMotion ? 0 : drag.width, y: reduceMotion ? 0 : drag.height * 0.15)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width) / 22))
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    if v.translation.width > 110 { answer(yes: true, face) }
                    else if v.translation.width < -110 { answer(yes: false, face) }
                    withAnimation(Motion.spring) { drag = .zero }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Is this \(person.displayName)?")
        .accessibilityAction(named: "Yes") { answer(yes: true, face) }
        .accessibilityAction(named: "No") { answer(yes: false, face) }
        .accessibilityAction(named: "Review on the whole photo") { fullFaces = answerable }
    }

    private func stamp(_ text: String, _ color: Color, visible: Bool) -> some View {
        Text(text).font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 3))
            .rotationEffect(.degrees(-10)).opacity(visible ? 1 : 0)
            .animation(Motion.quick, value: visible)
            .accessibilityHidden(true)
    }

    private func answers(_ face: Face, _ person: Person) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { answer(yes: false, face) } label: { Label("No", systemImage: "xmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("review.no")
                Button { answer(yes: true, face) } label: { Label("Yes", systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.confirmed, onTint: Palette.onConfirmed))
                    .accessibilityIdentifier("review.yes")
            }
            HStack {
                Button("Skip") { withAnimation { _ = skipped.insert(face.id) } }.frame(minHeight: 44)
                Spacer()
                Button("It’s someone else…") { assigning = face }.frame(minHeight: 44)
            }
            .font(.subheadline.weight(.semibold))
        }
        .sensoryFeedback(.success, trigger: answered)
    }

    private func answer(yes: Bool, _ face: Face) {
        withAnimation(Motion.spring) { queue.removeAll { $0.id == face.id } }
        answered += 1
        if yes { model.confirm([face.id]) } else { model.reject([face.id]) }
    }

    private func load() async {
        let store = model.store
        let faces = await Task.detached(priority: .userInitiated) { (try? store.uncertainFaces(limit: 300)) ?? [] }.value
        queue = faces
        loading = false
    }
}

/// Move a face to the right person (or a new one).
struct AssignSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let face: Face
    @State private var query = ""
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        FaceImage(faceID: face.id, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("New person") {
                    HStack {
                        TextField("Name", text: $newName).textInputAutocapitalization(.words)
                        Button("Add") { model.split([face.id], name: newName.trimmingCharacters(in: .whitespaces)); dismiss() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Someone you’ve named") {
                    ForEach(model.namedPeople.filter { $0.id != face.personID && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)) }) { p in
                        Button { model.assign([face.id], to: p.id); dismiss() } label: {
                            HStack(spacing: 12) {
                                FaceImage(faceID: p.coverFaceID, size: 40)
                                Text(p.displayName).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }
                Section {
                    Button("Not a person I know (ignore)", role: .destructive) { model.ignore([face.id]); dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .navigationTitle("Who is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Review over the whole screen: the full photo with the face in question outlined, Yes / No below it.
/// Double-tap or "Zoom" to fill the screen with the face. Answering moves to the next face.
struct ReviewFullScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let faces: [Face]
    let start: Int
    let onAnswered: (Int64) -> Void
    @State private var index = 0
    @State private var answered: Set<Int64> = []
    @State private var image: UIImage?
    @State private var isPreview = false
    @State private var zoomed = false

    private var face: Face? { faces.indices.contains(index) ? faces[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let face {
                VStack(spacing: 0) {
                    topBar
                    stage(face).frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls(face)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onAppear { index = min(max(0, start), max(0, faces.count - 1)) }
        .task(id: face?.id) { await load() }
        .sensoryFeedback(.success, trigger: answered.count)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.white.opacity(0.14)))
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("reviewfull.close")
            Text("\(index + 1) of \(faces.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button { withAnimation(Motion.spring) { zoomed.toggle() } } label: {
                Label(zoomed ? "Whole Photo" : "Zoom", systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func stage(_ face: Face) -> some View {
        GeometryReader { geo in
            if let image {
                let fit = fitted(image.size, in: geo.size)
                let box = CGRect(x: face.rect.minX * fit.width, y: face.rect.minY * fit.height,
                                 width: face.rect.width * fit.width, height: face.rect.height * fit.height)
                // Zoom so the face fills about half the height (at least 1.6×), centred on it as far as the photo's
                // edges allow, so the zoomed photo never slides off and leaves empty space.
                let scale = zoomed ? min(6, max(1.6, fit.height * 0.5 / max(box.height, 1))) : 1
                let maxX = max(0, (fit.width * scale - geo.size.width) / 2), maxY = max(0, (fit.height * scale - geo.size.height) / 2)
                let shift = zoomed ? CGSize(width: min(maxX, max(-maxX, (fit.width / 2 - box.midX) * scale)),
                                            height: min(maxY, max(-maxY, (fit.height / 2 - box.midY) * scale))) : .zero
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
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
                }
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(scale)
                .offset(shift)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .animation(reduceMotion ? nil : Motion.spring, value: zoomed)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation(Motion.spring) { zoomed.toggle() } }
                .accessibilityLabel("The whole photo, with the face in question outlined")
            } else {
                ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(.vertical, 8)
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    private func controls(_ face: Face) -> some View {
        let person = model.person(face.personID)
        let name = person?.displayName ?? "them"
        let done = answered.contains(face.id)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                FaceImage(faceID: person?.coverFaceID, size: 44)
                Text(done ? "Answered" : "Is this \(name)?").font(Typo.display(.title2)).foregroundStyle(.white)
                Spacer()
            }
            if isPreview {
                Label("Original not on this iPhone, showing the saved preview", systemImage: "externaldrive.badge.xmark")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { answer(false) } label: { Label("No", systemImage: "xmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("reviewfull.no")
                Button { answer(true) } label: { Label("Yes", systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.confirmed, onTint: Palette.onConfirmed))
                    .accessibilityIdentifier("reviewfull.yes")
            }
            .disabled(done)
            HStack {
                Button("Back") { step(-1) }.disabled(index == 0).frame(minHeight: 44)
                Spacer()
                Button("Skip") { step(1) }.disabled(index >= faces.count - 1).frame(minHeight: 44)
            }
            .font(.subheadline.weight(.semibold))
            .tint(.white)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func answer(_ yes: Bool) {
        guard let face, !answered.contains(face.id) else { return }
        answered.insert(face.id)
        if yes { model.confirm([face.id]) } else { model.reject([face.id]) }
        onAnswered(face.id)
        let order = Array(faces.indices.dropFirst(index + 1)) + Array(faces.indices.prefix(index))
        if let next = order.first(where: { !answered.contains(faces[$0].id) }) { zoomed = false; index = next } else { dismiss() }
    }

    private func step(_ d: Int) {
        let next = index + d
        guard faces.indices.contains(next) else { return }
        zoomed = false
        index = next
    }

    private func load() async {
        guard let face else { return }
        image = nil
        guard let p = try? model.store.photos(ids: [face.photoID]).first else { return }
        if let full = await PhotoImages.shared.full(p, sourceRoot: model.source(p.sourceID)?.url) {
            image = full.image; isPreview = full.isPreview
        }
    }
}
