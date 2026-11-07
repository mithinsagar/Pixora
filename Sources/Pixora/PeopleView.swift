import SwiftUI
import PixoraCore

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: Set<Int64> = []

    var body: some View {
        if let id = model.openPersonID, let person = model.person(id) {
            PersonDetailView(person: person)
        } else {
            library
        }
    }

    private var filtered: [Person] {
        model.namedPeople.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "People", subtitle: "\(Format.count(model.namedPeople.count, "person", "people")) named · \(Format.count(model.unnamedGroups.count, "group")) waiting for a name")
                if selection.count == 2 {
                    Button("Merge Selected…") { merge() }.help("Combine two people who are actually the same person")
                }
                if !selection.isEmpty {
                    Button("Find Photos of Selected") { model.selectedPeople = Array(selection); model.section = .find }
                }
                Button { model.exportEveryone = ExportEveryoneRequest(preselected: selection) } label: {
                    Label(selection.isEmpty ? "Export Everyone…" : "Export Selected…", systemImage: "folder.badge.person.crop")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("A folder of photos for each person, saved wherever you choose")
                .disabled(model.namedPeople.isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Palette.panel)
            Divider().overlay(Palette.rule)
            if model.namedPeople.isEmpty {
                EmptyState(symbol: "person.crop.rectangle.stack", title: "Nobody named yet",
                           message: "Name groups in Review and they’ll appear here — remembered for every future import.",
                           action: ("Go to Review", { model.section = .review }))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18, alignment: .top)], spacing: 22) {
                        ForEach(filtered) { p in card(p) }
                    }.padding(24)
                    Text("Click to open · ⌘-click to select several (select two to merge)").font(.caption).foregroundStyle(Palette.ink2).padding(.bottom, 20)
                }
            }
        }
        .background(Palette.canvas)
        .searchable(text: $query, placement: .toolbar, prompt: "Search people")
    }

    private func card(_ p: Person) -> some View {
        let selected = selection.contains(p.id)
        return VStack(alignment: .leading, spacing: 8) {
            FaceImage(faceID: p.coverFaceID, size: 170, shape: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Palette.safelight : .clear, lineWidth: 3))
                .overlay(alignment: .topLeading) {
                    if p.id == model.mePersonID { ShotBadge(icon: "person.fill", text: "Me", tint: Palette.confirmed).padding(8) }
                }
                .hoverLift(scale: 1.04, radius: 14, glow: !selected)
            Text(p.displayName).font(Typography.display(17)).lineLimit(1)
            EdgeLabel("\(Format.count(p.photoCount, "photo"))\(p.lastSeen.map { " · " + Format.day.string(from: $0) } ?? "")")
            if p.uncertainCount > 0 { Text("\(p.uncertainCount) to review").font(.caption).foregroundStyle(Palette.safelight) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { selection.formSymmetricDifference([p.id]) }
            else { model.openPersonID = p.id }
        }
        .contextMenu {
            Button("Open") { model.openPersonID = p.id }
            Button("Find Photos") { model.selectedPeople = [p.id]; model.section = .find }
            Button("Solo Photos Only") { model.selectedPeople = [p.id]; model.matchMode = .only; model.section = .find }
            Button("Through Time") { model.faceTime = FaceTimeRequest(personID: p.id, name: p.displayName) }
            Button("Export All Photos…") { model.exportEveryone = ExportEveryoneRequest(preselected: [p.id]) }
            Button(p.id == model.mePersonID ? "This Isn’t Me" : "This Is Me") { model.setMe(p.id == model.mePersonID ? nil : p.id) }
            Button(selected ? "Deselect" : "Select") { selection.formSymmetricDifference([p.id]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Select") { selection.formSymmetricDifference([p.id]) }
    }

    private func merge() {
        let ids = Array(selection)
        guard ids.count == 2, let a = model.person(ids[0]), let b = model.person(ids[1]) else { return }
        let alert = NSAlert()
        alert.messageText = "Merge \(a.displayName) and \(b.displayName)?"
        alert.informativeText = "All faces become one person. Choose which name to keep."
        alert.addButton(withTitle: "Keep “\(a.displayName)”")
        alert.addButton(withTitle: "Keep “\(b.displayName)”")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.merge(b.id, into: a.id)
        case .alertSecondButtonReturn: model.merge(a.id, into: b.id)
        default: return
        }
        selection = []
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var faces: [Face] = []
    @State private var uncertain: [Face] = []
    @State private var selection: Set<Int64> = []
    @State private var name = ""
    @State private var confirmForget = false
    @State private var confirmPrivate = false
    @State private var anchor: NSView?
    enum DetailTab: Hashable { case photos, faces }
    @AppStorage("personTab") private var tabRaw = "photos"
    private var tab: DetailTab {
        get { tabRaw == "faces" ? .faces : .photos }
    }
    private var tabBinding: Binding<DetailTab> { Binding(get: { tab }, set: { tabRaw = $0 == .faces ? "faces" : "photos" }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { model.openPersonID = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).font(.title2).accessibilityLabel("Back to People").keyboardShortcut("[", modifiers: .command)
                FaceImage(faceID: person.coverFaceID, size: 84, shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name).font(Typography.display(26)).textFieldStyle(.plain)
                        .onSubmit { model.name(personID: person.id, as: name) }
                        .accessibilityLabel("Person’s name")
                    EdgeLabel("\(Format.count(person.photoCount, "photo")) · \(Format.count(person.faceCount, "face"))\(person.lastSeen.map { " · last seen " + Format.day.string(from: $0) } ?? "")")
                }
                Spacer()
                Button { model.faceTime = FaceTimeRequest(personID: person.id, name: person.displayName) } label: {
                    Label("Through Time", systemImage: "clock.arrow.circlepath")
                }.help("Watch \(person.displayName) change over time, with every photo lined up on the eyes")
                Button("Solo Photos") { model.selectedPeople = [person.id]; model.matchMode = .only; model.section = .find }
                    .help("Photos with nobody else in them")
                Button("Find Photos") { model.selectedPeople = [person.id]; model.matchMode = .all; model.section = .find }
                Button { model.exportEveryone = ExportEveryoneRequest(preselected: [person.id]) } label: {
                    Label("Export All…", systemImage: "folder.badge.person.crop")
                }.buttonStyle(PrimaryButtonStyle()).help("Save every photo of \(person.displayName) into a folder you choose")
                Menu {
                    Button(person.contactHandles.isEmpty ? "Link to Contact…" : "Change Linked Contact…") {
                        ContactLinker.shared.pick(relativeTo: anchor) { id, _, handles in
                            model.setContact(personID: person.id, contactID: id, handles: handles)
                        }
                    }
                    if !person.contactHandles.isEmpty {
                        Button("Unlink Contact") { model.setContact(personID: person.id, contactID: nil, handles: []) }
                    }
                    Button(person.id == model.mePersonID ? "This Isn’t Me" : "This Is Me") { model.setMe(person.id == model.mePersonID ? nil : person.id) }
                    Button("Contact Sheet PDF…") {
                        let photos = (try? model.store.search(people: [person.id], mode: .all, includeUncertain: false).map(\.photo)) ?? []
                        model.makeContactSheet(photos, title: person.displayName)
                    }
                    Divider()
                    Menu("Merge into…") {
                        ForEach(model.namedPeople.filter { $0.id != person.id }) { p in Button(p.displayName) { model.merge(person.id, into: p.id); model.openPersonID = p.id } }
                    }
                    Divider()
                    if model.canMakePrivate {
                        Button("Make Private…") { confirmPrivate = true }
                    } else {
                        Button("Set Up Private Space…") { model.section = .privateSpace }
                    }
                    Button("Forget \(person.displayName)…", role: .destructive) { confirmForget = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Palette.panel)
            .background(ShareAnchor(view: $anchor))
            if !person.contactHandles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Palette.confirmed)
                    Text("Linked contact: " + person.contactHandles.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(Palette.ink2)
                    Spacer()
                }.padding(.horizontal, 24).padding(.top, 8)
            }
            Divider().overlay(Palette.rule)
            Picker("", selection: tabBinding) {
                Text("Photos (\(person.photoCount))").tag(DetailTab.photos)
                Text("Faces (\(person.faceCount))").tag(DetailTab.faces)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 12)
            if tab == .photos {
                PersonPhotosView(person: person)
            } else {

            HStack(spacing: 10) {
                EdgeLabel(selection.isEmpty ? "Select faces to correct mistakes" : "\(selection.count) selected")
                Spacer()
                Button("Not \(person.displayName)") { model.reject(Array(selection)); selection = [] }.disabled(selection.isEmpty)
                    .help("Remove these faces. Pixora won’t suggest this person for them again.")
                Button("Split into New Person…") { split() }.disabled(selection.isEmpty)
                Menu("Move to…") {
                    ForEach(model.namedPeople.filter { $0.id != person.id }) { p in Button(p.displayName) { model.assign(Array(selection), to: p.id); selection = [] } }
                }.fixedSize().disabled(selection.isEmpty)
                Button("Set as Cover") { if let f = selection.first { model.setCover(personID: person.id, faceID: f) } }
                    .disabled(selection.count != 1)
            }.padding(.horizontal, 24).padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !uncertain.isEmpty {
                        HStack {
                            Text("Uncertain — is this \(person.displayName)?").font(.headline)
                            Spacer()
                            Button("Reject All") { model.rejectAllUncertain(personID: person.id) }
                            Button { model.confirmAllUncertain(personID: person.id) } label: { Label("Confirm All \(uncertain.count)", systemImage: "checkmark") }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                            ForEach(uncertain) { f in
                                VStack(spacing: 4) {
                                    FaceBadge(faceID: f.id, size: 84, state: .suggested).hoverLift(scale: 1.07, radius: 42, glow: true)
                                    HStack(spacing: 4) {
                                        Button { model.confirm([f.id]) } label: { Image(systemName: "checkmark") }.accessibilityLabel("Yes, \(person.displayName)")
                                        Button { model.reject([f.id]) } label: { Image(systemName: "xmark") }.accessibilityLabel("Not \(person.displayName)")
                                    }.controlSize(.small)
                                }
                            }
                        }
                        Divider()
                    }
                    Text("Faces").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(faces) { f in
                            FaceImage(faceID: f.id, size: 96)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection.contains(f.id) ? Palette.safelight : .clear, lineWidth: 3))
                                .hoverLift(scale: 1.07, radius: 10, glow: true)
                                .onDrag { NSItemProvider(object: "pixora-face:\(f.id)" as NSString) }
                                .overlay(alignment: .bottomLeading) {
                                    if f.state == .confirmed { Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.confirmed).background(Circle().fill(.white)).padding(4).help("Confirmed by you") }
                                }
                                .onTapGesture { selection.formSymmetricDifference([f.id]) }
                                .accessibilityLabel(f.state == .confirmed ? "Confirmed face" : "Automatically matched face")
                                .accessibilityAddTraits(selection.contains(f.id) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }.padding(24)
            }
            }
        }
        .background(Palette.canvas)
        .task(id: "\(person.id)-\(person.faceCount)-\(person.uncertainCount)") {
            name = person.name ?? ""
            faces = (try? model.store.faces(personID: person.id)) ?? []
            uncertain = ((try? model.store.faces(personID: person.id, minState: .suggested)) ?? []).filter { $0.state == .suggested }
            selection.formIntersection(Set(faces.map(\.id)))
        }
        .sheet(isPresented: $confirmPrivate) {
            VaultDialog(icon: "lock.fill", title: "Make \(person.displayName) private?",
                        message: "Their photos move into Private Space, encrypted on this Mac.",
                        bullets: ["They disappear from the library, search, People, previews and slideshows.",
                                  "New photos where Pixora is confident it’s them go straight into Private Space.",
                                  "Uncertain matches wait in Private Space’s review queue — never in ordinary browsing.",
                                  "Works while Private Space is locked. Original files aren’t changed."],
                        confirm: "Make Private") { model.makePrivate(personID: person.id) }
        }
        .confirmationDialog("Forget \(person.displayName)?", isPresented: $confirmForget) {
            Button("Forget and Delete Face Data", role: .destructive) { model.forget(person.id) }
        } message: {
            Text("Deletes this name and all \(person.faceCount + person.uncertainCount) face templates and face thumbnails linked to it. Your photos are not touched. Re-scanning those photos would detect the faces again as unknown.")
        }
    }

    private func split() {
        let alert = NSAlert()
        alert.messageText = "Move \(selection.count) faces to a new person"
        alert.informativeText = "Leave the name empty to create an unnamed group you can name later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Split"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        model.newPerson(from: Array(selection), name: n.isEmpty ? nil : n)
        selection = []
    }
}

/// A person's photos as full frames: click to view large, Select to pick photos to share or copy.
struct PersonPhotosView: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var results: [SearchResult] = []
    @State private var soloOnly = false
    @State private var includeUncertain = false
    @State private var selecting = false
    @State private var selected: Set<Int64> = []
    @State private var inspected: Int64?
    @State private var expanded: Set<Int64> = []
    @AppStorage("personStackBursts") private var stackBursts = false

    /// burst id → frames, best first.
    private var bursts: [Int64: [SearchResult]] {
        var b: [Int64: [SearchResult]] = [:]
        for r in results { if let id = r.burstID { b[id, default: []].append(r) } }
        return b.mapValues { $0.sorted { $0.score > $1.score } }
    }

    /// Bursts stacked behind their best frame unless expanded.
    private var shown: [SearchResult] {
        let b = bursts
        guard stackBursts else { return results }   // every frame, unless stacking is switched on
        return results.filter { r in
            guard let id = r.burstID, let frames = b[id], frames.count > 1 else { return true }
            return frames.first?.id == r.id || expanded.contains(id)
        }
    }

    private func info(_ r: SearchResult) -> TileInfo {
        var t = TileInfo(matches: r.matches, isBest: best.contains(r.id), eyesClosed: r.eyesClosed, soft: r.soft)
        if let id = r.burstID, let frames = bursts[id], frames.count > 1 {
            if stackBursts, frames.first?.id == r.id {
                t.burstCount = frames.count; t.burstExpanded = expanded.contains(id)
            } else if !stackBursts {
                let order = frames.sorted { ($0.photo.takenAt ?? .distantPast, $0.photo.filename) < ($1.photo.takenAt ?? .distantPast, $1.photo.filename) }
                t.burstPosition = (order.firstIndex { $0.id == r.id } ?? 0) + 1
                t.burstSize = frames.count
            }
        }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $soloOnly) {
                    Text("All photos").tag(false)
                    Text("Only \(person.displayName)").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Include uncertain", isOn: $includeUncertain).toggleStyle(.switch).controlSize(.small).fixedSize()
                Toggle("Stack bursts", isOn: $stackBursts).toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("Off: every frame is shown. On: frames shot within 2 s are stacked behind the best one.")
                Spacer()
                EdgeLabel(Format.count(results.count, "photo") + (results.count > shown.count ? " · \(results.count - shown.count) burst frames stacked" : ""))
                Button { model.quickPick = QuickPickRequest(title: person.displayName, photos: shown.map(\.photo)) } label: {
                    Label("Quick Pick", systemImage: "hand.draw").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Capsule().fill(Palette.card)).overlay(Capsule().strokeBorder(Palette.rule)).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain).hoverLift(scale: 1.04, radius: 16).disabled(shown.isEmpty)
                .help("Go through these one at a time: keep, favorite or skip")
                SelectToggle(selecting: $selecting)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            if results.isEmpty {
                EmptyState(symbol: "photo.on.rectangle", title: soloOnly ? "No solo photos" : "No photos yet",
                           message: soloOnly ? "Every photo of \(person.displayName) has someone else in it too." : "Confirm faces in Review to see their photos here.")
            } else {
                PhotoGrid(items: shown.map { r in (r.photo, info(r)) },
                          inspected: $inspected,
                          onToggleBurst: { id in
                              guard let b = results.first(where: { $0.id == id })?.burstID else { return }
                              expanded.formSymmetricDifference([b])
                          },
                          selecting: selecting, selected: selected,
                          onToggleSelect: { selected.formSymmetricDifference([$0]) },
                          onOpen: { id in model.openViewer(shown.map(\.photo), at: id, title: person.displayName) },
                          viewerTitle: person.displayName)
            }
            if selecting {
                SelectionBar(selected: shown.map(\.photo).filter { selected.contains($0.id) }, total: shown.count, person: person,
                             title: person.displayName,
                             selectAll: { selected = Set(shown.map(\.id)) }, selectNone: { selected = [] },
                             selectFavorites: !results.contains { model.favorites.contains($0.id) } ? nil : {
                                 // A favorite stacked in a burst has to be showing to be copied.
                                 let chosen = results.filter { model.favorites.contains($0.id) }
                                 expanded.formUnion(chosen.compactMap(\.burstID))
                                 selected = Set(chosen.map(\.id))
                             },
                             done: { selecting = false; selected = [] })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: "\(person.id)-\(soloOnly)-\(includeUncertain)-\(person.faceCount)-\(person.uncertainCount)") {
            results = (try? model.store.search(people: [person.id], mode: soloOnly ? .only : .all, includeUncertain: includeUncertain)) ?? []
            selected.formIntersection(Set(results.map(\.id)))
        }
    }

    private var best: Set<Int64> {
        guard results.count >= 5 else { return [] }
        let cut = results.map(\.score).sorted(by: >)[max(0, results.count / 5 - 1)]
        return Set(results.filter { $0.score >= cut && !$0.eyesClosed && !$0.soft }.map(\.id))
    }
}
