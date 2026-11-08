import SwiftUI
import PixoraCore

struct PeopleScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var query = ""
    @State private var naming: Person?
    @State private var path = NavigationPath()

    private var named: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.namedPeople : model.namedPeople.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.people.isEmpty {
                        EmptyState(symbol: "person.2", title: "No people yet",
                                   message: "Scan some photos and Pixora groups the faces it finds. Name a group once and Pixora remembers them in every future import.",
                                   actionTitle: "Go to Library", action: { model.tab = .library })
                            .padding(.top, 40)
                    } else {
                        if model.stats.reviewItems > 0 { reviewBanner }
                        if !named.isEmpty {
                            section("Named", count: named.count)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 18) {
                                ForEach(named) { p in
                                    NavigationLink(value: p.id) { PersonCell(person: p) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        if !model.unnamedGroups.isEmpty && query.isEmpty {
                            section("Who’s this?", count: model.unnamedGroups.count)
                            Text("Groups of faces Pixora thinks are the same person. Tap a name tag to name them.")
                                .font(.footnote).foregroundStyle(Palette.ink2).padding(.horizontal, 16)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 18) {
                                ForEach(model.unnamedGroups.prefix(120)) { p in
                                    VStack(spacing: 6) {
                                        NavigationLink(value: p.id) { FaceImage(faceID: p.coverFaceID, size: 84) }.buttonStyle(.plain)
                                        Button { naming = p } label: {
                                            Label("Name", systemImage: "tag").font(.caption.weight(.semibold))
                                                .padding(.horizontal, 10).padding(.vertical, 6)
                                                .background(Capsule().fill(Palette.safelight.opacity(0.14)))
                                                .frame(minHeight: 44)
                                        }
                                        .buttonStyle(.plain).foregroundStyle(Palette.safelight)
                                        .accessibilityLabel("Name this group of \(Format.count(p.photoCount, "photo"))")
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .canvas()
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search people")
            .navigationDestination(for: Int64.self) { PersonScreen(personID: $0) }
            .sheet(item: $naming) { NameSheet(person: $0) }
            .overlay(alignment: .top) {
                if model.isMatching {
                    Label("Updating matches…", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.regularMaterial)).padding(.top, 4)
                }
            }
        }
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typo.display(.title3)).foregroundStyle(Palette.ink)
            EdgeLabel("\(count)")
            Spacer()
        }
        .padding(.horizontal, 16)
        .accessibilityAddTraits(.isHeader)
    }

    private var reviewBanner: some View {
        Button { model.tab = .review } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.bubble.fill").font(.title2).foregroundStyle(Palette.safelight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.count(model.stats.reviewItems, "face")) to check").font(.headline).foregroundStyle(Palette.ink)
                    Text("Quick yes-or-no answers make every match better.").font(.subheadline).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.ink2)
            }
            .card()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct PersonCell: View {
    let person: Person
    var body: some View {
        VStack(spacing: 6) {
            FaceImage(faceID: person.coverFaceID, size: 84)
            Text(person.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            Text(Format.count(person.photoCount, "photo")).font(.caption).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Name a person, or pick an existing name to merge into (typing a name that exists offers to merge).
struct NameSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let person: Person
    @State private var name = ""
    @FocusState private var focused: Bool

    private var matches: [Person] {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return model.namedPeople.filter { $0.id != person.id && $0.displayName.localizedCaseInsensitiveContains(q) }.prefix(5).map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                FaceImage(faceID: person.coverFaceID, size: 120).padding(.top, 12)
                TextField("Name", text: $name)
                    .font(.title3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rule))
                    .onSubmit(save)
                    .accessibilityIdentifier("name.field")
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        EdgeLabel("Same person as…")
                        ForEach(matches) { p in
                            Button { model.merge(person.id, into: p.id); dismiss() } label: {
                                HStack(spacing: 12) {
                                    FaceImage(faceID: p.coverFaceID, size: 40)
                                    Text("Merge into \(p.displayName)").font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                                    Spacer()
                                    Image(systemName: "arrow.triangle.merge").foregroundStyle(Palette.safelight)
                                }
                                .frame(minHeight: 48)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Pixora remembers this name. Faces that match in future imports are added automatically, and unsure ones wait for you in Review.")
                    .font(.footnote).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                Spacer()
                Button("Save Name", action: save).buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("name.save")
            }
            .padding(16)
            .canvas()
            .navigationTitle(person.isNamed ? "Rename" : "Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { name = person.name ?? ""; focused = true }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if let existing = model.namedPeople.first(where: { $0.id != person.id && $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }) {
            model.merge(person.id, into: existing.id)
        } else {
            model.name(personID: person.id, as: clean)
        }
        dismiss()
    }
}

// MARK: - Person

struct PersonScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let personID: Int64
    enum Pane: Hashable { case photos, faces }
    @State private var pane: Pane = .photos
    @State private var photos: [Photo] = []
    @State private var faces: [Face] = []
    @State private var unsure: [Face] = []
    @State private var naming = false
    @State private var merging = false
    @State private var confirmForget = false
    @State private var confirmPrivate = false
    @State private var selectingFaces = false
    @State private var pickedFaces: Set<Int64> = []
    @State private var studio = false

    private var person: Person? { model.person(personID) }

    var body: some View {
        ScrollView {
            if let person {
                VStack(alignment: .leading, spacing: 16) {
                    header(person)
                    if !unsure.isEmpty { unsureSection }
                    Picker("Show", selection: $pane) {
                        Text("Photos").tag(Pane.photos)
                        Text("Faces").tag(Pane.faces)
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    switch pane {
                    case .photos:
                        PhotoGrid(photos: photos) { p in model.openViewer(photos, at: p.id, title: person.displayName) }
                    case .faces:
                        facesPane
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .canvas()
        .navigationTitle(person?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { naming = true } label: { Label(person?.isNamed == true ? "Rename" : "Name", systemImage: "tag") }
                    Button { model.selectedPeople = [personID]; model.tab = .find } label: { Label("Find Photos", systemImage: "person.2.crop.square.stack") }
                    Button { studio = true } label: { Label("Slideshow", systemImage: "play.rectangle") }
                    Button { merging = true } label: { Label("Merge Into…", systemImage: "arrow.triangle.merge") }
                    Button { model.exportPhotos = photos } label: { Label("Save or Share Photos", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button { confirmPrivate = true } label: { Label("Make Private", systemImage: "lock") }
                    Button(role: .destructive) { confirmForget = true } label: { Label("Forget Person", systemImage: "person.badge.minus") }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Person actions")
                .accessibilityIdentifier("person.menu")
            }
        }
        .task(id: "\(personID)-\(model.stats.faces)-\(model.people.first { $0.id == personID }?.faceCount ?? 0)") { await load() }
        // Merged, forgotten or made private: this page has nothing left to show.
        .onChange(of: person == nil) { _, gone in if gone { dismiss() } }
        .sheet(isPresented: $naming) { if let person { NameSheet(person: person) } }
        .sheet(isPresented: $merging) { MergePicker(source: personID) }
        .sheet(isPresented: $studio) { SlideshowStudio(source: .library, personID: personID) }
        .confirmationDialog("Forget \(person?.displayName ?? "this person")?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Person", role: .destructive) { model.forget(personID); dismiss() }
        } message: { Text("Their name and groupings are removed. Photos stay in your library, and your originals aren’t touched. You can undo right after.") }
        .confirmationDialog("Make \(person?.displayName ?? "this person") private?", isPresented: $confirmPrivate, titleVisibility: .visible) {
            Button(model.isPrivateSetUp ? "Make Private" : "Set Up Private Space") {
                if model.isPrivateSetUp { model.makePrivate(personID: personID); dismiss() } else { model.tab = .privateSpace }
            }
        } message: {
            Text(model.isPrivateSetUp
                 ? "Their photos move into Private Space as encrypted copies and disappear from the library, search and slideshows while it’s locked. Future confirmed matches go there too; unsure ones wait in Private Space review. Originals aren’t changed."
                 : "Private Space needs a password first. It’s separate from your iPhone passcode and Apple Account.")
        }
    }

    private func header(_ person: Person) -> some View {
        HStack(spacing: 16) {
            FaceImage(faceID: person.coverFaceID, size: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName).font(Typo.display(.title)).foregroundStyle(Palette.ink).lineLimit(2)
                EdgeLabel("\(Format.count(person.photoCount, "photo")) · \(Format.count(person.faceCount, "face"))")
                if !person.isNamed {
                    Button { naming = true } label: { Label("Add Name", systemImage: "tag") }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var unsureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this \(person?.displayName ?? "them")?").font(.headline).foregroundStyle(Palette.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(unsure.prefix(30)) { f in
                        VStack(spacing: 8) {
                            FaceImage(faceID: f.id, size: 76)
                            HStack(spacing: 6) {
                                Button { model.reject([f.id]) } label: { Image(systemName: "xmark").frame(width: 38, height: 38) }
                                    .buttonStyle(.bordered).tint(.red).accessibilityLabel("Not \(person?.displayName ?? "them")")
                                Button { model.confirm([f.id]) } label: { Image(systemName: "checkmark").frame(width: 38, height: 38) }
                                    .buttonStyle(.borderedProminent).tint(Palette.confirmed).accessibilityLabel("Yes, \(person?.displayName ?? "them")")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Palette.panel)
    }

    private var facesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectingFaces ? "Select faces that aren’t \(person?.displayName ?? "them")" : "Every face matched to \(person?.displayName ?? "this person")")
                    .font(.footnote).foregroundStyle(Palette.ink2)
                Spacer()
                Button(selectingFaces ? "Done" : "Select") { selectingFaces.toggle(); pickedFaces = [] }.font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                ForEach(faces) { f in
                    let on = pickedFaces.contains(f.id)
                    FaceImage(faceID: f.id, size: 72)
                        .overlay(Circle().strokeBorder(on ? Palette.safelight : .clear, lineWidth: 3))
                        .overlay(alignment: .bottomTrailing) {
                            if f.state == .confirmed { Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.confirmed).font(.caption) }
                        }
                        .opacity(selectingFaces && !on ? 0.7 : 1)
                        .onTapGesture { if selectingFaces { if on { pickedFaces.remove(f.id) } else { pickedFaces.insert(f.id) } } }
                        .contextMenu {
                            Button { model.setCover(personID: personID, faceID: f.id) } label: { Label("Use as Cover", systemImage: "person.crop.circle") }
                            Button { model.reject([f.id]) } label: { Label("Not \(person?.displayName ?? "them")", systemImage: "xmark") }
                        }
                        .accessibilityLabel(on ? "Face, selected" : "Face")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 16)
            if selectingFaces && !pickedFaces.isEmpty {
                HStack(spacing: 10) {
                    Button("Not Them") { model.reject(Array(pickedFaces)); pickedFaces = [] }.buttonStyle(SecondaryButtonStyle())
                    Button("New Person") { model.split(Array(pickedFaces), name: nil); pickedFaces = []; selectingFaces = false }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
            }
        }
    }

    private func load() async {
        let store = model.store, id = personID
        let (p, f, u) = await Task.detached(priority: .userInitiated) { () -> ([Photo], [Face], [Face]) in
            let p = (try? store.search(people: [id], mode: .all, includeUncertain: false).map(\.photo)) ?? []
            let f = (try? store.faces(personID: id)) ?? []
            let u = ((try? store.faces(personID: id, minState: .suggested)) ?? []).filter { $0.state == .suggested }
            return (p, f, u)
        }.value
        photos = p; faces = f; unsure = u
    }
}

/// Pick the person to merge into.
struct MergePicker: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: Int64
    @State private var query = ""
    @State private var target: Person?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.namedPeople.filter { $0.id != source && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)) }) { p in
                    Button { target = p } label: {
                        HStack(spacing: 12) {
                            FaceImage(faceID: p.coverFaceID, size: 44)
                            Text(p.displayName).foregroundStyle(Palette.ink)
                            Spacer()
                            EdgeLabel(Format.count(p.photoCount, "photo"))
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Merge Into")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Merge into \(target?.displayName ?? "")?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
                Button("Merge") { if let t = target { model.merge(source, into: t.id) }; dismiss() }
            } message: { Text("All of \(model.person(source)?.displayName ?? "this group")’s faces become \(target?.displayName ?? "")’s. You can undo right after.") }
        }
    }
}
