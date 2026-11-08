import SwiftUI
import PixoraCore

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    enum Tab: Hashable { case groups, uncertain, unsorted }
    @State private var tab: Tab = .groups
    @State private var uncertain: [Face] = []
    @State private var unsorted: [Face] = []
    @State private var unrecognizable = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                UpgradeNotice()
                SectionHeader(title: "Review", subtitle: "Name new groups, confirm uncertain matches, and sort single faces. Every answer improves future matching.")
                Picker("", selection: $tab) {
                    Text("New groups (\(model.unnamedGroups.count))").tag(Tab.groups)
                    Text("Uncertain (\(uncertain.count))").tag(Tab.uncertain)
                    Text("Unsorted faces (\(unsorted.count))").tag(Tab.unsorted)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Palette.panel)
            Divider().overlay(Palette.rule)
            switch tab {
            case .groups: NewGroupsList()
            case .uncertain: UncertainReview(faces: uncertain)
            case .unsorted: UnsortedFaces(faces: unsorted, unrecognizable: unrecognizable)
            }
        }
        .background(Palette.canvas)
        .task(id: "\(model.people.count)-\(model.stats.reviewItems)-\(model.stats.faces)-\(model.isMatching)") {
            // Off the main thread: run on it, these queries froze the page as it slid in.
            let store = model.store
            let (u, s, n) = await Task.detached(priority: .userInitiated) {
                ((try? store.uncertainFaces()) ?? [], (try? store.unsortedFaces()) ?? [], (try? store.unrecognizableFaceCount()) ?? 0)
            }.value
            uncertain = u; unsorted = s; unrecognizable = n
        }
    }
}

// MARK: New groups

private struct NewGroupsList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.unnamedGroups.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "No new groups", message: "When a scan finds the same unknown face in several photos, it appears here for you to name.")
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.unnamedGroups) { g in GroupCard(group: g) }
                }.padding(24)
            }
        }
    }
}

private struct GroupCard: View {
    @Environment(AppModel.self) private var model
    let group: Person
    @State private var faces: [Face] = []
    @State private var name = ""
    @State private var excluded: Set<Int64> = []
    @State private var confirmMerge: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                EdgeLabel("\(Format.count(group.faceCount, "face")) · \(Format.count(group.photoCount, "photo"))")
                Spacer()
                Button("Not a group — ignore") { model.ignore(faces.map(\.id)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.ink2).underline().help("For strangers in the background. Their faces are removed from review and face templates are deleted.")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: only the faces in view are made, which kept the page from stalling as it slid in.
                LazyHStack(spacing: 8) {
                    ForEach(faces.prefix(30)) { f in
                        FaceImage(faceID: f.id, size: 76)
                            .opacity(excluded.contains(f.id) ? 0.3 : 1)
                            .hoverLift(scale: 1.07, radius: 10, glow: true)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: excluded.contains(f.id) ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(excluded.contains(f.id) ? Color.red : Palette.confirmed).background(Circle().fill(.white)).offset(x: 4, y: -4)
                            }
                            .onTapGesture { excluded.formSymmetricDifference([f.id]) }
                            .accessibilityLabel(excluded.contains(f.id) ? "Face excluded from group" : "Face included in group")
                            .accessibilityAddTraits(.isButton)
                            .help("Click to leave this face out")
                    }
                    if faces.count > 30 { EdgeLabel("+\(faces.count - 30) more").padding(.leading, 6) }
                }.padding(.vertical, 6).padding(.trailing, 6)
            }
            HStack(spacing: 10) {
                TextField("Who is this?", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260).onSubmit(save)
                if let s = suggestion { Button("Add to \(s.displayName)") { name = s.displayName; save() } }
                Spacer()
                Text(excluded.isEmpty ? "Naming confirms all \(faces.count) faces." : "\(excluded.count) left out will be unassigned.")
                    .font(.caption).foregroundStyle(Palette.ink2)
                Button("Name", action: save).buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).cardBackground()
        .task(id: group.faceCount) {
            let store = model.store, id = group.id
            faces = await Task.detached(priority: .userInitiated) { (try? store.faces(personID: id)) ?? [] }.value
        }
        .alert("Merge with existing \(confirmMerge?.displayName ?? "")?", isPresented: .constant(confirmMerge != nil), presenting: confirmMerge) { p in
            Button("Merge") { commit(); confirmMerge = nil }
            Button("Cancel", role: .cancel) { confirmMerge = nil }
        } message: { p in Text("There is already a person called \(p.displayName). These faces will be added to them.") }
    }

    private var suggestion: Person? {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return model.namedPeople.first { $0.displayName.localizedCaseInsensitiveContains(q) && $0.displayName.caseInsensitiveCompare(q) != .orderedSame }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let existing = model.namedPeople.first(where: { $0.displayName.caseInsensitiveCompare(n) == .orderedSame }) { confirmMerge = existing }
        else { commit() }
    }

    private func commit() {
        let excludedIDs = Array(excluded), groupID = group.id, newName = name
        model.change("Name “\(newName.trimmingCharacters(in: .whitespaces))”") {
            if !excludedIDs.isEmpty { try model.store.reject(faceIDs: excludedIDs) }
            _ = try model.store.name(personID: groupID, as: newName)
        }
    }
}

// MARK: Uncertain — side-by-side

private struct UncertainReview: View {
    @Environment(AppModel.self) private var model
    let faces: [Face]
    @AppStorage("uncertainMode") private var allAtOnce = true
    @State private var confirmAll = false

    var body: some View {
        if faces.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "Nothing uncertain", message: "Borderline matches show up here instead of silently counting as matches.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("", selection: $allAtOnce) {
                        Text("All at once").tag(true)
                        Text("One by one").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button { confirmAll = true } label: { Label("Accept All \(faces.count)", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Confirm every suggestion on this tab")
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                if allAtOnce { UncertainGrid(faces: faces) } else { UncertainOneByOne(faces: faces) }
            }
            .confirmationDialog("Accept all \(faces.count) suggestions?", isPresented: $confirmAll) {
                Button("Accept All") { model.confirmAllUncertain() }
            } message: { Text("Each face is confirmed as the person suggested for it. Scan the list first — anything wrong can still be fixed later from the person’s page.") }
        }
    }
}

/// Every uncertain face, grouped by the suggested person, so a whole batch can be accepted in one click.
private struct UncertainGrid: View {
    @Environment(AppModel.self) private var model
    let faces: [Face]

    var body: some View {
        let groups = Dictionary(grouping: faces, by: { $0.personID ?? -1 }).sorted { $0.value.count > $1.value.count }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.key) { pid, list in
                    if let person = model.person(pid) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                FaceImage(faceID: person.coverFaceID, size: 40, shape: AnyShape(Circle()))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Is this \(person.displayName)?").font(Typography.display(17))
                                    EdgeLabel(Format.count(list.count, "suggestion"))
                                }
                                Spacer()
                                Button("Reject All") { model.rejectAllUncertain(personID: pid) }
                                    .help("None of these are \(person.displayName). Remembered, so they won’t be suggested again.")
                                Button { model.confirmAllUncertain(personID: pid) } label: { Label("Accept All \(list.count)", systemImage: "checkmark") }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                                ForEach(list) { f in UncertainFaceCell(face: f, personName: person.displayName) }
                            }
                        }
                        .padding(16).cardBackground()
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
    }
}

/// A suggested face: hover to reveal ✓ / ✗.
private struct UncertainFaceCell: View {
    @Environment(AppModel.self) private var model
    let face: Face
    let personName: String
    @State private var hovering = false
    var body: some View {
        FaceImage(faceID: face.id, size: 104)
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 8) {
                        Button { model.reject([face.id]) } label: { Image(systemName: "xmark").frame(width: 30, height: 26) }
                            .buttonStyle(.plain).background(Capsule().fill(.black.opacity(0.65))).foregroundStyle(.white)
                            .accessibilityLabel("Not \(personName)")
                        Button { model.confirm([face.id]) } label: { Image(systemName: "checkmark").frame(width: 30, height: 26) }
                            .buttonStyle(.plain).background(Capsule().fill(Palette.safelight)).foregroundStyle(Palette.onSafelight)
                            .accessibilityLabel("Yes, \(personName)")
                    }
                    .padding(6).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .hoverLift(scale: 1.06, radius: 10, glow: true, cursor: false)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .onDrag { NSItemProvider(object: "pixora-face:\(face.id)" as NSString) }
            .help("Hover for ✓ / ✗ · drag onto someone in the sidebar to assign to them instead")
    }
}

private struct UncertainOneByOne: View {
    @Environment(AppModel.self) private var model
    let faces: [Face]
    @State private var index = 0
    @State private var refs: [Face] = []
    @State private var context: NSImage?

    var body: some View {
        let face = faces[min(index, faces.count - 1)]
        let person = model.person(face.personID)
        VStack(spacing: 20) {
            EdgeLabel("\(min(index, faces.count - 1) + 1) of \(faces.count)")
            HStack(alignment: .top, spacing: 32) {
                VStack(spacing: 10) {
                    Text("Known faces of \(person?.displayName ?? "this person")").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 3), spacing: 8) {
                        ForEach(refs.prefix(9)) { r in InteractiveFace(faceID: r.id, size: 84) }
                    }
                }
                .frame(width: 280)
                Image(systemName: "arrow.left.and.right").font(.title).foregroundStyle(Palette.ink2).padding(.top, 90)
                VStack(spacing: 10) {
                    Text("Is this \(person?.displayName ?? "them")?").font(.headline)
                    FaceImage(faceID: face.id, size: 200, shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                        .hoverLift(scale: 1.03, radius: 18, glow: true, cursor: false)
                    if let context {
                        Image(nsImage: context).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityLabel("The photo this face is from")
                    }
                    Text("Borderline similarity — Pixora won’t count this until you decide.").font(.caption).foregroundStyle(Palette.ink2)
                }.frame(width: 280)
            }
            HStack(spacing: 12) {
                Button { model.reject([face.id]) } label: { Label("No", systemImage: "xmark") }
                    .keyboardShortcut("n", modifiers: []).controlSize(.large)
                Button { index += 1; if index >= faces.count { index = 0 } } label: { Label("Skip", systemImage: "forward") }
                    .keyboardShortcut(.rightArrow, modifiers: []).controlSize(.large)
                Button { model.confirm([face.id]) } label: { Label("Yes, it’s \(person?.displayName ?? "them")", systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut("y", modifiers: [])
            }
            Text("Keyboard: Y yes · N no · → skip").font(.caption).foregroundStyle(Palette.ink2)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: face.id) {
            refs = face.personID.flatMap { try? model.store.faces(personID: $0) } ?? []
            if let p = try? model.store.photos(ids: [face.photoID]).first {
                context = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID)?.url)
            }
        }
    }
}

// MARK: Unsorted

private struct UnsortedFaces: View {
    @Environment(AppModel.self) private var model
    let faces: [Face]
    let unrecognizable: Int
    @State private var selection: Set<Int64> = []
    @State private var naming: Int64?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                EdgeLabel(selection.isEmpty ? "Click a face to name it · ⌘-click to select several" : "\(selection.count) selected")
                Spacer()
                Menu("Assign to…") {
                    ForEach(model.namedPeople) { p in Button(p.displayName) { model.assign(Array(selection), to: p.id); selection = [] } }
                }.fixedSize().disabled(selection.isEmpty || model.namedPeople.isEmpty)
                Button("Name Selected…") { naming = selection.first }.disabled(selection.isEmpty)
                Button("Ignore") { model.ignore(Array(selection)); selection = [] }.disabled(selection.isEmpty)
                    .help("Strangers: removes these faces from review and deletes their face templates.")
            }.padding(.horizontal, 24).padding(.vertical, 10)
            if unrecognizable > 0 {
                Notice(symbol: "eye.slash", text: "\(Format.count(unrecognizable, "face")) were too small, blurry or ignored, so they aren’t used for recognition.")
                    .padding(.horizontal, 24)
            }
            if faces.isEmpty {
                EmptyState(symbol: "square.grid.3x3", title: "No unsorted faces", message: "Faces seen only once, and not similar to anyone you’ve named, collect here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(faces) { f in
                            FaceImage(faceID: f.id, size: 96)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection.contains(f.id) ? Palette.safelight : .clear, lineWidth: 3))
                                .hoverLift(scale: 1.07, radius: 10, glow: true)
                                .onDrag { NSItemProvider(object: "pixora-face:\(f.id)" as NSString) }
                                .overlay(alignment: .bottomLeading) {
                                    if (f.quality ?? 1) < Matcher.minAutoQuality {
                                        EdgeLabel("hard", color: .white).padding(.horizontal, 4).background(.black.opacity(0.55)).padding(4)
                                            .help("Side-on, blurry or small: Pixora won’t match this face automatically")
                                    }
                                }
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) { selection.formSymmetricDifference([f.id]) }
                                    else { selection = [f.id]; naming = f.id }
                                }
                                .popover(isPresented: Binding(get: { naming == f.id }, set: { if !$0 { naming = nil } }), arrowEdge: .bottom) {
                                    NameFacesPopover(faceIDs: selection.contains(f.id) ? Array(selection) : [f.id]) { naming = nil; selection = [] }
                                }
                                .accessibilityAddTraits(selection.contains(f.id) ? [.isButton, .isSelected] : .isButton)
                                .accessibilityLabel("Unsorted face")
                                .accessibilityAction(named: "Name this face") { selection = [f.id]; naming = f.id }
                        }
                    }.padding(24)
                }
            }
        }
    }
}

/// "Who is this?" — type a new name or pick someone you've already named.
struct NameFacesPopover: View {
    @Environment(AppModel.self) private var model
    let faceIDs: [Int64]
    let done: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var matches: [Person] {
        model.namedPeople.filter { name.isEmpty || $0.displayName.localizedCaseInsensitiveContains(name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(faceIDs.count == 1 ? "Who is this?" : "Who are these \(faceIDs.count) faces?").font(.headline)
            HStack(spacing: 10) {
                if let first = faceIDs.first { FaceImage(faceID: first, size: 48) }
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            }
            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches.prefix(12)) { p in
                            Button { model.assign(faceIDs, to: p.id); done() } label: {
                                HStack { FaceImage(faceID: p.coverFaceID, size: 24, shape: AnyShape(Circle())); Text(p.displayName); Spacer() }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.vertical, 3)
                        }
                    }
                }.frame(maxHeight: 200)
            }
            HStack {
                Button("Ignore") { model.ignore(faceIDs); done() }.help("A stranger: remove from review")
                Spacer()
                Button(model.namedPeople.contains { $0.displayName.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame } ? "Add" : "Create Person", action: save)
                    .buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14).frame(width: 280)
        .onAppear { focused = true }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let existing = try? model.store.person(named: n) { model.assign(faceIDs, to: existing) }
        else { model.newPerson(from: faceIDs, name: n) }
        done()
    }
}
