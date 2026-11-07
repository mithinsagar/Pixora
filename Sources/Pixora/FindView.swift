import SwiftUI
import PixoraCore

struct FindView: View {
    @Environment(AppModel.self) private var model
    @State private var personQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var cameras: [String] = []
    @State private var lenses: [String] = []
    @State private var shareAnchor: NSView?
    @State private var showStudio = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.rule)
            if model.people.isEmpty {
                EmptyState(symbol: "person.2.crop.square.stack", title: "No people yet",
                           message: "Scan a card or folder first. Pixora finds faces, groups them, and you name the people you care about.",
                           action: ("Import Photos…", { model.section = .importer }))
            } else if model.selectedPeople.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(Palette.safelight)
                            Text("Pick one person or several above to find their photos. “Together” shows photos where everyone you picked appears; “Only them” shows photos with nobody else. Tip: ⌘K and type “me + asha october”.")
                                .font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panel))
                        MemoryCard()
                        AutoSlideshows()
                    }
                    .padding(24)
                    .frame(maxWidth: 2400, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else if model.visibleResults.isEmpty {
                VStack(spacing: 14) {
                    if model.uncertainExtra > 0 { uncertainNotice.padding(.horizontal, 24).padding(.top, 16) }
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "No photos found",
                               message: emptyMessage)
                }
            } else {
                if model.uncertainExtra > 0 || model.isMatching {
                    VStack(spacing: 8) {
                        if model.uncertainExtra > 0 { uncertainNotice }
                        if model.isMatching { Notice(symbol: "arrow.triangle.2.circlepath", text: "Updating matches with your corrections…") }
                    }.padding(.horizontal, 24).padding(.top, 12)
                }
                PhotoGrid(items: model.presentation.strong.map { ($0.photo, info($0)) },
                          weaker: model.presentation.weaker.map { ($0.photo, info($0), model.presentation.reason($0, stacked: model.stackBursts) ?? "") },
                          inspected: $model.inspectedPhotoID,
                          excluded: model.excludedFromExport,
                          onToggleExport: { model.toggleExport($0) },
                          onToggleBurst: { id in
                              guard let b = model.results.first(where: { $0.id == id })?.burstID else { return }
                              model.expandedBursts.formSymmetricDifference([b])
                          },
                          selecting: model.findSelecting,
                          viewerTitle: model.querySentence)
                    .padding(.top, 8)
                exportBar
            }
        }
        .background(Palette.canvas)
        .sheet(isPresented: $showStudio) { SlideshowStudioSheet(source: .library) }
        .task {
            cameras = (try? model.store.distinctValues("camera")) ?? []
            lenses = (try? model.store.distinctValues("lens")) ?? []
        }
    }

    private var emptyMessage: String {
        switch model.matchMode {
        case .only: return "No photo has just them in it. Try “Together” to include photos with other people too."
        case .all where model.selectedPeople.count > 1: return "No photo has all of them as certain matches. Try “Any”, include uncertain matches, or review suggestions."
        default: return model.bestOnly ? "No ★ Best shots under these filters — turn off “Best only”." : "There are no certain matches yet. Review suggestions to teach Pixora."
        }
    }

    private func info(_ r: SearchResult) -> TileInfo {
        var t = TileInfo(matches: r.matches, isBest: model.presentation.best.contains(r.id), eyesClosed: r.eyesClosed, soft: r.soft)
        if let b = r.burstID, let frames = model.presentation.bursts[b], frames.count > 1 {
            if model.stackBursts, frames.first?.id == r.id {
                t.burstCount = frames.count
                t.burstExpanded = model.expandedBursts.contains(b)
            } else {
                let order = frames.sorted { ($0.photo.takenAt ?? .distantPast, $0.photo.filename) < ($1.photo.takenAt ?? .distantPast, $1.photo.filename) }
                t.burstPosition = (order.firstIndex { $0.id == r.id } ?? 0) + 1
                t.burstSize = frames.count
            }
        }
        return t
    }

    private var header: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            UpgradeNotice()
            SectionHeader(title: model.querySentence, subtitle: subtitle)
                .animation(nil, value: model.querySentence)

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.selectedPeople, id: \.self) { id in
                            if let p = model.person(id) { PersonChip(person: p) { model.toggle(id) } }
                        }
                        addPersonField
                    }.padding(.vertical, 2)
                }
                Spacer(minLength: 12)
                modePicker
                Toggle("Include uncertain", isOn: $model.includeUncertain)
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("Also show photos where Pixora thinks a person might appear but isn’t sure. They’re marked with a dashed “?” ring.")
                viewMenu
            }

            peopleStrip
            if !model.selectedPeople.isEmpty {
                FilterBar(filter: $model.filter, cameras: cameras, lenses: lenses, imports: model.imports)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
        .background(Palette.panel)
    }

    private var subtitle: String? {
        guard !model.selectedPeople.isEmpty else { return nil }
        var parts = [Format.count(model.presentation.strong.count, "photo")]
        if !model.presentation.weaker.isEmpty { parts.append("\(model.presentation.weaker.count) to check") }
        let stacked = model.results.count - model.visibleResults.count
        if stacked > 0 && model.stackBursts { parts.append("\(stacked) burst frames stacked") }
        parts.append(model.includeUncertain ? "including uncertain matches" : "certain matches only")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var modePicker: some View {
        @Bindable var model = model
        if model.selectedPeople.count == 1 {
            Picker("Match", selection: $model.matchMode) {
                Text("All photos").tag(MatchMode.all)
                Text("Only them").tag(MatchMode.only)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Only them: solo photos — nobody else in the frame (tiny faces far in the background don’t count).")
        } else if model.selectedPeople.count > 1 {
            Picker("Match", selection: $model.matchMode) {
                Text("Together").tag(MatchMode.all)
                Text("Any").tag(MatchMode.any)
                Text("Only them").tag(MatchMode.only)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Together: every chosen person appears.\nAny: at least one of them.\nOnly them: all of them and nobody else.")
        }
    }

    private var viewMenu: some View {
        @Bindable var model = model
        return Menu {
            Toggle("Stack bursts behind the best frame (off: show every frame)", isOn: $model.stackBursts)
            Toggle("Separate shots to check (eyes may be closed, soft focus)", isOn: $model.separateWeaker)
            Divider()
            Toggle("★ Best shots only", isOn: $model.bestOnly)
            Picker("Sort", selection: $model.sortBestFirst) {
                Text("Newest first").tag(false)
                Text("Best first").tag(true)
            }
        } label: {
            Label("View", systemImage: "slider.horizontal.3")
        }
        .fixedSize()
        .help("How results are arranged")
    }

    private var addPersonField: some View {
        let matches = model.namedPeople.filter {
            !model.selectedPeople.contains($0.id) && (personQuery.isEmpty || $0.displayName.localizedCaseInsensitiveContains(personQuery))
        }
        return TextField("Add person…", text: $personQuery)
            .textFieldStyle(.roundedBorder).frame(width: 160)
            .focused($searchFocused)
            .onSubmit {
                if let first = matches.first { model.toggle(first.id); personQuery = "" }
            }
            .popover(isPresented: .constant(searchFocused && !personQuery.isEmpty && !matches.isEmpty), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches.prefix(8)) { p in
                        Button { model.toggle(p.id); personQuery = "" } label: {
                            HStack { FaceImage(faceID: p.coverFaceID, size: 22, shape: AnyShape(Circle())); Text(p.displayName); Spacer() }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }.padding(6).frame(width: 220)
            }
            .accessibilityLabel("Add a person to the selection")
    }

    /// Everyone named, as a strip of portraits; click to add or remove without losing results.
    private var peopleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.namedPeople) { p in
                    PersonTile(person: p, selected: model.selectedPeople.contains(p.id), size: 64)
                        .overlay(alignment: .topLeading) {
                            if p.id == model.mePersonID { ShotBadge(icon: "person.fill", text: "Me", tint: Palette.confirmed).offset(x: -4, y: -4) }
                        }
                        .onTapGesture { model.toggle(p.id) }
                        .accessibilityAction { model.toggle(p.id) }
                }
                if !model.unnamedGroups.isEmpty {
                    Button { model.section = .review } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .frame(width: 64, height: 64)
                                .overlay(Text("+\(model.unnamedGroups.count)").font(Typography.edgeLarge).foregroundStyle(Palette.ink2))
                            Text("Unnamed").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                        }
                    }.buttonStyle(.plain).hoverLift(scale: 1.05, radius: 14).help("Name more people in Review")
                }
            }.padding(.vertical, 8).padding(.horizontal, 4)
        }
    }

    private var uncertainNotice: some View {
        Notice(symbol: "questionmark.circle",
               text: model.includeUncertain
                   ? "\(Format.count(model.uncertainExtra, "photo")) shown here \(model.uncertainExtra == 1 ? "is an uncertain match" : "are uncertain matches") (dashed “?” ring). Check them before sending."
                   : "\(Format.count(model.uncertainExtra, "more photo")) might match, but Pixora isn’t sure.",
               actions: model.includeUncertain ? [("Review…", { model.section = .review })]
                   : [("Show them", { model.includeUncertain = true }), ("Review…", { model.section = .review })])
    }

    private var exportBar: some View {
        let included = model.exportablePhotos.count
        let single = model.selectedPeople.count == 1 ? model.person(model.selectedPeople.first) : nil
        @Bindable var model = model
        return HStack(spacing: 12) {
            SelectToggle(selecting: $model.findSelecting).fixedSize()
            if model.findSelecting {
                Text("\(included)").font(.system(size: 20, weight: .semibold, design: .serif)).monospacedDigit()
                    .contentTransition(.numericText()).animation(.snappy, value: included)
                EdgeLabel("selected").fixedSize()
            } else {
                Text("\(included) of \(model.visibleResults.count) selected".uppercased()).font(Typography.edge).tracking(1.1).foregroundStyle(Palette.ink2)
                    .lineLimit(1).fixedSize().rollingNumber(included)
            }
            Button("All") { model.setExportAll(true) }.controlSize(.small).fixedSize()
            Button("None") { model.setExportAll(false) }.controlSize(.small).fixedSize()
            if model.favoriteResultCount > 0 {
                Button { model.selectFavorites() } label: { Label("Favorites (\(model.favoriteResultCount))", systemImage: "heart.fill") }
                    .controlSize(.small).fixedSize().help("Select only your favorites, ready to copy")
            }
            Spacer()
            if model.findSelecting {
                Button { model.toggleFavorite(model.exportablePhotos) } label: { Label("Favorite", systemImage: "heart") }
                    .fixedSize().disabled(included == 0).help("Add these to your favorites, or remove them if they all are already")
            }
            DragOutHandle(urls: { model.fileURLs(for: model.exportablePhotos) }, label: "Drag \(included)")
                .fixedSize()
            Button { model.share(model.exportablePhotos, from: shareAnchor) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .background(ShareAnchor(view: $shareAnchor)).fixedSize()
                .help("AirDrop, Messages, Mail…").disabled(included == 0)
            if let single, !single.contactHandles.isEmpty {
                Menu {
                    if single.contactHandles.contains(where: { !$0.contains("@") }) {
                        Button("Messages") { model.send(model.exportablePhotos, to: single, via: .composeMessage) }
                    }
                    if single.contactHandles.contains(where: { $0.contains("@") }) {
                        Button("Mail") { model.send(model.exportablePhotos, to: single, via: .composeEmail) }
                    }
                    Button("AirDrop") { model.send(model.exportablePhotos, to: single, via: .sendViaAirDrop) }
                } label: { Label("Send to \(single.displayName)", systemImage: "paperplane") }
                .fixedSize().disabled(included == 0)
            }
            Menu {
                Button { model.quickPick = QuickPickRequest(title: model.querySentence, photos: model.visibleResults.map(\.photo)) } label: {
                    Label("Quick Pick", systemImage: "hand.draw")
                }
                if let single {
                    Button { model.faceTime = FaceTimeRequest(personID: single.id, name: single.displayName) } label: {
                        Label("\(single.displayName) Through Time", systemImage: "clock.arrow.circlepath")
                    }
                }
                Divider()
                Button { showStudio = true } label: { Label("Slideshow", systemImage: "play.rectangle") }
                Button { model.makeContactSheet(model.exportablePhotos, title: model.querySentence) } label: { Label("Contact Sheet", systemImage: "doc.richtext") }
                    .disabled(included == 0)
                Button { model.recapRequest = RecapRequest(title: model.querySentence, photos: model.visibleResults.map(\.photo)) } label: {
                    Label("Recap", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .fixedSize().help("Quick Pick, Through Time, slideshow, contact sheet and recap card")
            Button { model.requestExport() } label: {
                Label(model.findSelecting ? "Copy to Folder…" : "Copy \(Format.count(included, "Photo")) to Folder…", systemImage: "square.and.arrow.down.on.square")
                    .lineLimit(1)
            }
            .buttonStyle(PrimaryButtonStyle()).fixedSize()
            .keyboardShortcut("e", modifiers: .command)
            .disabled(included == 0)
            if model.findSelecting { Button("Done") { model.findSelecting = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Palette.panel)
        .overlay(alignment: .top) {
            if model.findSelecting { Rectangle().fill(Palette.safelight).frame(height: 2) } else { Divider().overlay(Palette.rule) }
        }
    }
}

// MARK: - Inspector

struct PhotoInspector: View {
    @Environment(AppModel.self) private var model
    let photoID: Int64?
    @State private var photo: Photo?
    @State private var faces: [Face] = []
    @State private var preview: NSImage?
    @State private var highlighted: Int64?
    @State private var burst: [Photo] = []

    var body: some View {
        Group {
            if let photo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewView(photo)
                            .onTapGesture(count: 2) { openViewer(photo) }
                        HStack {
                            Button { openViewer(photo) } label: { Label("View Full Photo", systemImage: "arrow.up.left.and.arrow.down.right") }
                                .keyboardShortcut(.space, modifiers: [])
                                .help("Open large with ← → to move between photos (Space)")
                            Button { model.toggleFavorite([photo]) } label: {
                                Label(model.favorites.contains(photo.id) ? "Favorite" : "Favorite", systemImage: model.favorites.contains(photo.id) ? "heart.fill" : "heart")
                            }
                            .help(model.favorites.contains(photo.id) ? "Remove from favorites" : "Mark as a favorite (used by Favorites slideshows)")
                            if model.canMakePrivate {
                                Button { model.makePrivate(photos: [photo]); model.inspectedPhotoID = nil } label: { Label("Make Private", systemImage: "lock") }
                                    .help("Hide it from the library; it will only show in Private Space")
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.filename).font(Typography.display(18)).textSelection(.enabled)
                            if !photo.siblings.isEmpty { EdgeLabel("with " + photo.siblings.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
                        }
                        metadata(photo)
                        if burst.count > 1 { burstStrip }
                        Divider()
                        Text("People in this photo").font(.headline)
                        if faces.isEmpty { Text("No faces found.").foregroundStyle(Palette.ink2).font(.callout) }
                        ForEach(faces) { face in faceRow(face) }
                    }.padding(16)
                }
            } else {
                Text("Select a photo to see its details and the people in it.").font(.callout).foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.panel)
        .task(id: "\(photoID ?? -1)-\(model.people.count)-\(model.stats.reviewItems)") { await load() }
    }

    private func openViewer(_ photo: Photo) {
        let list = model.section == .find ? model.visibleResults.map(\.photo) : [photo]
        model.openViewer(list.contains { $0.id == photo.id } ? list : [photo], at: photo.id, title: model.section == .find ? model.querySentence : "Photo")
    }

    private func load() async {
        guard let photoID, let p = try? model.store.photos(ids: [photoID]).first else { photo = nil; faces = []; return }
        photo = p
        faces = (try? model.store.faces(photoID: photoID)) ?? []
        burst = (try? model.store.db.read { try $0.query("SELECT burst_id FROM photos WHERE id = ?", [photoID]) { $0.optInt(0) } }.first ?? nil)
            .flatMap { try? model.store.burstPhotos($0) } ?? []
        let root = model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil }
        preview = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let root, let cg = ImageLoader.image(at: root.appendingPathComponent(p.relPath), maxPixel: 1400) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return NSImage(contentsOf: AppPaths.thumbnail(photoID: p.id))
        }.value
    }

    private func previewView(_ photo: Photo) -> some View {
        ZStack {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            ForEach(faces) { f in
                                let r = CGRect(x: f.rect.minX * geo.size.width, y: f.rect.minY * geo.size.height,
                                               width: f.rect.width * geo.size.width, height: f.rect.height * geo.size.height)
                                Rectangle()
                                    .strokeBorder(f.state.isCertain ? Color.white : Color.yellow,
                                                  style: StrokeStyle(lineWidth: highlighted == f.id ? 3 : 1.5, dash: f.state.isCertain ? [] : [4, 3]))
                                    .frame(width: r.width, height: r.height)
                                    .position(x: r.midX, y: r.midY)
                                    .shadow(color: .black.opacity(0.5), radius: 1)
                            }
                        }
                    }
            } else {
                Rectangle().fill(Palette.rule).aspectRatio(1.5, contentMode: .fit).overlay(ProgressView())
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.source(photo.sourceID)?.isOnline == false {
                EdgeLabel("Original offline", color: .white).padding(6).background(.black.opacity(0.6)).padding(6)
            }
        }
        .accessibilityLabel("Preview of \(photo.filename)")
    }

    private var burstStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Burst · \(burst.count) frames", systemImage: "square.stack.3d.up").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(burst) { b in
                        BurstThumb(photo: b, selected: b.id == photoID)
                            .onTapGesture { model.inspectedPhotoID = b.id }
                    }
                }.padding(4)
            }
        }
    }

    private func metadata(_ p: Photo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Taken", p.takenAt.map { Format.dateTime.string(from: $0) } ?? "Unknown")
            row("Camera", p.camera ?? "—")
            row("Lens", p.lens ?? "—")
            if let w = p.width, let h = p.height { row("Size", "\(w) × \(h) · \(Format.size(p.fileSize))") }
            if let r = p.rating, r > 0 { row("Rating", String(repeating: "★", count: r)) }
            row("Location", (model.source(p.sourceID)?.name ?? "?") + "/" + p.relPath)
        }.font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Palette.ink2)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }

    private func faceRow(_ face: Face) -> some View {
        let person = model.person(face.personID)
        return HStack(spacing: 10) {
            FaceBadge(faceID: face.id, size: 40, state: face.personID == nil ? .confirmed : face.state)
                .hoverLift(scale: 1.12, radius: 20, glow: true)
                .onDrag { NSItemProvider(object: "pixora-face:\(face.id)" as NSString) }
                .help("Drag onto a person in the sidebar to assign")
            VStack(alignment: .leading, spacing: 2) {
                Text(person?.displayName ?? (face.hasEmbedding ? "Unknown" : "Too small or blurry to recognise"))
                    .font(.system(size: 13, weight: .medium))
                Text(statusText(face)).font(.caption).foregroundStyle(Palette.ink2)
            }
            Spacer()
            Menu {
                if face.personID != nil, face.state != .confirmed { Button("Confirm \(person?.displayName ?? "")") { model.confirm([face.id]) } }
                if face.personID != nil { Button("Not \(person?.displayName ?? "this person")") { model.reject([face.id]) } }
                if face.hasEmbedding {
                    Menu("This is…") {
                        ForEach(model.namedPeople.filter { $0.id != face.personID }) { p in Button(p.displayName) { model.assign([face.id], to: p.id) } }
                    }
                    Button("New person…") { promptNewPerson(face) }
                }
                if face.personID != nil { Divider(); Button("Use as cover photo") { model.setCover(personID: face.personID!, faceID: face.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Actions for this face")
        }
        .onHover { highlighted = $0 ? face.id : nil }
    }

    private func statusText(_ f: Face) -> String {
        guard f.personID != nil else { return f.hasEmbedding ? "Not matched to anyone" : "Not used for recognition" }
        switch f.state {
        case .confirmed: return "Confirmed by you"
        case .auto: return "Matched automatically"
        case .suggested: return "Uncertain — please check"
        case .unassigned: return ""
        }
    }

    private func promptNewPerson(_ face: Face) {
        let alert = NSAlert()
        alert.messageText = "Who is this?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            if let existing = try? model.store.person(named: field.stringValue) { model.assign([face.id], to: existing) }
            else { model.newPerson(from: [face.id], name: field.stringValue) }
        }
    }
}

private struct BurstThumb: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let selected: Bool
    @State private var image: NSImage?
    var body: some View {
        ZStack { Palette.rule; if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Palette.safelight : .clear, lineWidth: 2))
            .hoverLift(scale: 1.08, radius: 4)
            .task(id: photo.id) { image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url) }
            .help(photo.filename)
    }
}
