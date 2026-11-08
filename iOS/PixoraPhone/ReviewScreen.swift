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
    @State private var context: Photo?
    @State private var assigning: Face?
    @State private var answered = 0

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
            .task(id: model.stats.reviewItems) { await load() }
            .sheet(item: $assigning) { AssignSheet(face: $0) }
        }
    }

    private func card(_ face: Face, _ person: Person) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                VStack(spacing: 6) {
                    FaceImage(faceID: face.id, size: 132)
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
            Button { Task { context = try? model.store.photos(ids: [face.photoID]).first; if let c = context { model.openViewer([c], at: c.id, title: "Is this \(person.displayName)?") } } } label: {
                Label("See the whole photo", systemImage: "photo").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
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
                    .buttonStyle(PrimaryButtonStyle(tint: Palette.confirmed, onTint: .white))
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
