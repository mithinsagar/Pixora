import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

enum StudioSource { case library, privateSpace }

struct SlideshowRequest: Identifiable {
    let id = UUID()
    let title: String
    let slides: [Photo]
    let captions: [Int64: String]
    let duration: Double
    let transition: SlideshowTransition
    let showCaptions: Bool
    /// The track the person chose. The player still starts muted; music plays only after they tap the speaker.
    let music: MusicChoice?
    let volume: Float
    /// Made in Private Space: closes the moment Private Space locks.
    let isPrivate: Bool
}

/// Slideshow Studio on iPhone: where the photos come from, a style, quality filters, editable order, timing,
/// transition and opt-in music. Suggestions are simple rules (described on screen), never a claim of perfection.
struct SlideshowStudio: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: StudioSource
    var chosen: [Photo] = []
    var personID: Int64? = nil

    enum From: Hashable { case selection, person, chosen }
    @State private var from: From = .selection
    @State private var pickedPerson: Int64?
    @State private var mode: MatchMode = .all
    @State private var style: SlideStyle = .story
    @State private var candidates: [SlideCandidate] = []
    @State private var loading = false
    @State private var event: SlideEvent?
    @State private var customRange = false
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var rangeEnd = Date()
    @State private var skipEyesClosed = true
    @State private var skipSoft = true
    @State private var removed: Set<Int64> = []
    @State private var order: [Int64]?
    @State private var editing = false
    @State private var shuffle = false
    @State private var musicOn = false          // never remembered: every slideshow starts without music
    @State private var musicFile: URL?
    @State private var pickMusic = false
    @AppStorage("slideDuration") private var duration = 4.0
    @AppStorage("slideTransition") private var transitionRaw = SlideshowTransition.crossfade.rawValue
    @AppStorage("slideCaptions") private var showCaptions = true
    @AppStorage("slideVolume") private var volume = 0.35

    private var isPrivate: Bool { source == .privateSpace }
    private var accent: Color { isPrivate ? Vault.brass : Palette.safelight }
    private var people: [(id: Int64, name: String, cover: Int64?)] {
        isPrivate ? (model.privateContent?.people ?? []).map { ($0.id, $0.name, nil) } : model.namedPeople.map { ($0.id, $0.displayName, $0.coverFaceID) }
    }
    private var focusPeople: [Int64] {
        switch from {
        case .selection: isPrivate ? [] : model.selectedPeople
        case .person: pickedPerson.map { [$0] } ?? []
        case .chosen: []
        }
    }
    private var events: [SlideEvent] { SlideshowPlanner.events(candidates.map(\.photo)) }
    private var eventInterval: DateInterval? {
        customRange ? DateInterval(start: min(rangeStart, rangeEnd), end: max(rangeStart, rangeEnd).addingTimeInterval(86_399)) : event?.interval
    }
    private var picked: [SlideCandidate] {
        SlideshowPlanner.pick(style, from: candidates, people: focusPeople, event: style == .event ? eventInterval : nil,
                              skipEyesClosed: skipEyesClosed, skipSoft: skipSoft)
    }
    private var slides: [SlideCandidate] {
        let base = picked.filter { !removed.contains($0.id) }
        guard let order else { return base }
        let byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return order.compactMap { byID[$0] } + base.filter { !order.contains($0.id) }
    }
    private var sourceKey: String { "\(from)-\(pickedPerson ?? 0)-\(mode)-\(chosen.count)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceSection
                    styleSection
                    if style == .event { eventSection }
                    qualitySection
                    previewSection
                    timingSection
                    musicSection
                }
                .padding(16)
            }
            .background((isPrivate ? Vault.night : Palette.canvas).ignoresSafeArea())
            .navigationTitle(isPrivate ? "Private Slideshow" : "Slideshow Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button(action: play) { Label(slides.isEmpty ? "No Photos to Play" : "Play \(Format.count(slides.count, "Photo"))", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(tint: accent, onTint: isPrivate ? Vault.onBrass : Palette.onSafelight))
                    .disabled(slides.isEmpty)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.bar)
                    .accessibilityIdentifier("studio.play")
            }
            .task(id: sourceKey) { await load() }
            .onChange(of: style) { removed = []; order = nil }
            .sheet(isPresented: $editing) { EditSlides(slides: slides, removed: $removed, order: $order) }
            .fileImporter(isPresented: $pickMusic, allowedContentTypes: [.audio]) { r in
                if case .success(let url) = r { musicFile = copyMusic(url) }
            }
        }
        .tint(accent)
        .environment(\.colorScheme, isPrivate ? .dark : (UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light))
        .onAppear(perform: setUpDefaults)
    }

    // MARK: Sections

    private func header(_ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.display(.title3)).foregroundStyle(isPrivate ? Vault.ink : Palette.ink)
            if let detail { Text(detail).font(.footnote).foregroundStyle(isPrivate ? Vault.ink2 : Palette.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Photos from")
            Picker("Photos from", selection: $from) {
                Text(isPrivate ? "Everything" : "Selected").tag(From.selection)
                Text("One person").tag(From.person)
                if !chosen.isEmpty { Text("Chosen").tag(From.chosen) }
            }
            .pickerStyle(.segmented)
            switch from {
            case .selection:
                if isPrivate {
                    note("All photos in Private Space.")
                } else if model.selectedPeople.isEmpty {
                    note("Nobody is selected in Find Photos. Choose “One person”, or pick people in Find first.")
                } else {
                    note(ListFormatter.localizedString(byJoining: model.selectedPeople.compactMap { model.person($0)?.displayName }))
                    if model.selectedPeople.count > 1 {
                        Picker("Who must be in each photo", selection: $mode) {
                            Text("All of them").tag(MatchMode.all)
                            Text("Any of them").tag(MatchMode.any)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            case .person:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(people, id: \.id) { p in
                            Chip(title: p.name, on: pickedPerson == p.id) { pickedPerson = p.id }
                        }
                    }
                }
                if people.isEmpty { note("Name someone first.") }
            case .chosen:
                note("The \(Format.count(chosen.count, "photo")) you selected, in the order you picked them.")
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Style", style.rule)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Story (the default) first, so the selected style is always on screen.
                    ForEach([SlideStyle.story] + SlideStyle.allCases.filter { $0 != .story }) { s in
                        let n = SlideshowPlanner.pick(s, from: candidates, people: focusPeople, event: s == .event ? eventInterval : nil,
                                                      skipEyesClosed: skipEyesClosed, skipSoft: skipSoft).count
                        Button { withAnimation(Motion.quick) { style = s } } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: s.symbol).font(.title3)
                                Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(s == .event && eventInterval == nil ? "Pick dates" : Format.count(n, "photo")).font(.caption).opacity(0.75)
                            }
                            .frame(width: 112, height: 96, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(style == s ? accent : (isPrivate ? Vault.card : Palette.card)))
                            .foregroundStyle(style == s ? (isPrivate ? Vault.onBrass : Palette.onSafelight) : (isPrivate ? Vault.ink : Palette.ink))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.title), \(Format.count(n, "photo"))")
                        .accessibilityAddTraits(style == s ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Event or trip", events.isEmpty ? "Not enough dated photos to suggest events. Choose dates instead." : "Suggested from gaps in the dates. Pick one, or choose your own dates.")
            if !events.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(events) { e in
                            Chip(title: "\(Format.day(e.start)) · \(e.count)", on: !customRange && event == e) { customRange = false; event = e }
                        }
                        Chip(title: "Choose dates", symbol: "calendar", on: customRange) { customRange = true }
                    }
                }
            }
            if customRange || events.isEmpty {
                DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    .onAppear { customRange = true }
            }
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            header("Leave out", "Pixora’s guesses. They can be wrong, so check the preview.")
            Toggle("Shots where eyes may be closed", isOn: $skipEyesClosed)
            Toggle("Shots that may be soft", isOn: $skipSoft)
        }
        .foregroundStyle(isPrivate ? Vault.ink : Palette.ink)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                header("Photos", loading ? "Loading…" : "\(Format.count(slides.count, "photo"))\(removed.isEmpty ? "" : ", \(removed.count) removed by you")")
                Spacer()
                Button("Edit") { editing = true }.font(.subheadline.weight(.semibold)).disabled(slides.isEmpty).frame(minHeight: 44)
                    .accessibilityIdentifier("studio.edit")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(slides.prefix(60)) { c in
                        PhotoTile(photo: c.photo, showsOffline: false).frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(height: 72)
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Playback")
            HStack {
                Text("Each photo").foregroundStyle(isPrivate ? Vault.ink : Palette.ink)
                Spacer()
                Text("\(duration, specifier: "%.0f") s").monospacedDigit().foregroundStyle(isPrivate ? Vault.ink2 : Palette.ink2)
            }
            Slider(value: $duration, in: 2...10, step: 1).accessibilityLabel("Seconds per photo")
            Picker("Transition", selection: $transitionRaw) {
                ForEach(SlideshowTransition.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Shuffle", isOn: $shuffle)
            Toggle("Show date and names", isOn: $showCaptions)
        }
        .foregroundStyle(isPrivate ? Vault.ink : Palette.ink)
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Music", "Off unless you turn it on. Even then the slideshow starts muted: tap the speaker while it plays.")
            Toggle("Background music", isOn: $musicOn).accessibilityIdentifier("studio.music")
            if musicOn {
                Menu {
                    Button("Soft tones (made by Pixora)") { musicFile = nil }
                    Button("Choose an audio file…") { pickMusic = true }
                } label: {
                    HStack {
                        Image(systemName: "music.note")
                        Text(musicFile?.deletingPathExtension().lastPathComponent ?? "Soft tones (made by Pixora)").lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .frame(minHeight: 44)
                }
                HStack {
                    Image(systemName: "speaker.fill").accessibilityHidden(true)
                    Slider(value: $volume, in: 0...1).accessibilityLabel("Music volume")
                    Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                }
                note("Soft tones are generated on the device, so there’s nothing to license. Use only music you have the right to play.")
            }
        }
        .foregroundStyle(isPrivate ? Vault.ink : Palette.ink)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(isPrivate ? Vault.ink2 : Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Data

    private func setUpDefaults() {
        mode = model.matchMode == .any ? .any : .all
        if !chosen.isEmpty { from = .chosen; order = chosen.map(\.id) }
        else if let personID { from = .person; pickedPerson = personID }
        else if !isPrivate && model.selectedPeople.isEmpty { from = .person }
        if pickedPerson == nil { pickedPerson = model.selectedPeople.first ?? people.first?.id }
    }

    private func load() async {
        if isPrivate {
            let items = (model.privateContent?.items ?? []).filter { !$0.isPendingReview }
            let all = items.map { item in
                SlideCandidate(photo: item.photo, faces: item.faces.map { SlideFace(personID: $0.personID, certain: $0.state.isCertain, rect: $0.rect, pixelSize: $0.pixelSize) })
            }
            switch from {
            case .selection: candidates = all
            case .person: candidates = pickedPerson.map { pid in all.filter { $0.faces.contains { $0.personID == pid && $0.certain } } } ?? []
            case .chosen: candidates = all.filter { c in chosen.contains { $0.id == c.id } }
            }
            event = events.first
            return
        }
        loading = true
        defer { loading = false }
        let store = model.store, favorites = model.favorites
        let from = from, pid = pickedPerson, selection = model.selectedPeople, mode = mode, chosenIDs = chosen.map(\.id)
        candidates = await Task.detached(priority: .userInitiated) { () -> [SlideCandidate] in
            var results: [SearchResult] = []
            var photos: [Photo] = []
            switch from {
            case .selection: if !selection.isEmpty { results = (try? store.search(people: selection, mode: mode, includeUncertain: false)) ?? [] }
            case .person: if let pid { results = (try? store.search(people: [pid], mode: .all, includeUncertain: false)) ?? [] }
            case .chosen: photos = (try? store.photos(ids: chosenIDs)) ?? []
            }
            if !results.isEmpty { photos = results.map(\.photo) }
            let flags = Dictionary(results.map { ($0.photo.id, ($0.eyesClosed, $0.soft)) }, uniquingKeysWith: { a, _ in a })
            let faces = (try? store.slideFaces(photoIDs: photos.map(\.id))) ?? [:]
            return photos.map { p in
                SlideCandidate(photo: p, faces: faces[p.id] ?? [], eyesClosed: flags[p.id]?.0 ?? false, soft: flags[p.id]?.1 ?? false,
                               favorite: favorites.contains(p.id))
            }
        }.value
        if from == .chosen { order = chosenIDs }
        event = events.first
    }

    /// Keep a private copy of the chosen track inside the app, so it can play after the picker's access ends.
    private func copyMusic(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Slideshow Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { model.errorMessage = error.localizedDescription; return nil }
    }

    private func caption(_ c: SlideCandidate) -> String {
        var parts: [String] = []
        if let d = c.photo.takenAt { parts.append(d.formatted(date: .long, time: .omitted)) }
        let names = Array(Set(c.faces.filter(\.certain).compactMap(\.personID))).compactMap { id in people.first { $0.id == id }?.name }.sorted()
        if !names.isEmpty { parts.append(ListFormatter.localizedString(byJoining: names)) }
        return parts.joined(separator: " · ")
    }

    private func play() {
        var list = slides
        if shuffle { list.shuffle() }
        let title: String
        switch from {
        case .selection: title = isPrivate ? "Private Space" : model.querySentence
        case .person: title = people.first { $0.id == pickedPerson }?.name ?? "Slideshow"
        case .chosen: title = "Selected photos"
        }
        let request = SlideshowRequest(title: title, slides: list.map(\.photo), captions: Dictionary(uniqueKeysWithValues: list.map { ($0.id, caption($0)) }),
                                       duration: duration, transition: SlideshowTransition(rawValue: transitionRaw) ?? .crossfade,
                                       showCaptions: showCaptions, music: musicOn ? (musicFile.map { .file($0) } ?? .ambient) : nil,
                                       volume: Float(volume), isPrivate: isPrivate)
        dismiss()
        Task { try? await Task.sleep(for: .milliseconds(350)); model.slideshow = request }
    }
}

/// Reorder (drag the handles) and remove photos from the slideshow.
private struct EditSlides: View {
    @Environment(\.dismiss) private var dismiss
    let slides: [SlideCandidate]
    @Binding var removed: Set<Int64>
    @Binding var order: [Int64]?
    @State private var list: [SlideCandidate] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(list) { c in
                    HStack(spacing: 12) {
                        PhotoTile(photo: c.photo, showsOffline: false).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.photo.takenAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? c.photo.filename).font(.subheadline)
                            if c.eyesClosed || c.soft { Text(c.eyesClosed ? "Eyes may be closed" : "May be soft").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onMove { list.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { idx in for i in idx { removed.insert(list[i].id) }; list.remove(atOffsets: idx) }
                if !removed.isEmpty {
                    Button("Put Back \(Format.count(removed.count, "Removed Photo"))") { removed = []; dismiss() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { order = list.map(\.id); dismiss() } } }
            .onAppear { list = slides }
        }
    }
}
