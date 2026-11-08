import SwiftUI
import PhotosUI
import PixoraCore

enum PhoneTab: Hashable { case find, people, library, review, privateSpace }

struct ViewerRequest: Identifiable {
    let id = UUID()
    let photos: [Photo]
    let index: Int
    let title: String
    var isPrivate: Bool { photos.first.map { $0.id < 0 } ?? false }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let photos: [Photo]
}

struct UndoOffer: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let snapshot: UndoSnapshot?
    static func == (a: UndoOffer, b: UndoOffer) -> Bool { a.id == b.id }
}

/// The iPhone app's state. Everything that decides *what* happens (matching, corrections, Private Space,
/// export) is PixoraCore, shared with the Mac; this class only connects it to the touch interface.
@MainActor @Observable
final class PhoneModel {
    let store: LibraryStore
    let vault: PrivateVault
    @ObservationIgnored let access = SourceAccess()
    private(set) var embedder: FaceEmbedder
    var isBasicMode: Bool { embedder is VisionFeaturePrintEmbedder }

    var tab: PhoneTab = .find {
        didSet {
            if oldValue == .privateSpace && tab != .privateSpace && (UserDefaults.standard.object(forKey: "lockOnLeave") as? Bool ?? true) {
                lockPrivateSpace()
            }
        }
    }

    // Library
    var people: [Person] = []
    var sources: [Source] = []
    var stats = LibraryStats()
    var favorites: Set<Int64> = []
    var errorMessage: String?
    var undo: UndoOffer?
    var isMatching = false
    var strictness: Double = UserDefaults.standard.double(forKey: "strictness") {
        didSet { UserDefaults.standard.set(strictness, forKey: "strictness"); scheduleRematch() }
    }
    var thresholds: MatchThresholds { embedder.thresholds.adjusted(by: Float(strictness)) }

    // Find
    var selectedPeople: [Int64] = [] { didSet { if selectedPeople != oldValue { runSearch() } } }
    var matchMode: MatchMode = .all { didSet { if matchMode != oldValue { runSearch() } } }
    var includeUncertain = false { didSet { if includeUncertain != oldValue { runSearch() } } }
    var results: [SearchResult] = []
    var uncertainExtra = 0
    var isSearching = false
    @ObservationIgnored private var searchGeneration = 0

    // Screens shown over everything
    var viewer: ViewerRequest?
    var share: ShareRequest?
    var exportPhotos: [Photo]?
    var slideshow: SlideshowRequest?
    var scan: PhoneScan?
    /// What to do once the Add Photos sheet has finished closing (iOS drops a sheet presented mid-dismiss).
    @ObservationIgnored var afterAddPhotos: (() -> Void)?
    func runAfterAddPhotos() { let next = afterAddPhotos; afterAddPhotos = nil; next?() }

    // Private Space
    var privateContent: PrivateVault.Content?
    var privateRevealID: UUID?
    var vaultEpoch = 0
    var privateSetupInProgress = false
    /// The delete-and-recreate sheet. Shown from the Private tab's root so it survives the vault disappearing.
    var showDeletePrivate = false
    var deleteIsForgot = true
    @ObservationIgnored var idleTimer: Timer?

    init() {
        do { store = try LibraryStore.openDefault() } catch {
            fatalError("Pixora could not open its library at \(AppPaths.database.path): \(error)")
        }
        vault = PrivateVault(store: store)
        embedder = Embedders.makeDefault()
        strictness = UserDefaults.standard.double(forKey: "strictness")
        access.reconnectAll(store: store)
        refreshAll()
        TestHooks.apply(to: self)
    }

    // MARK: Refresh

    func refreshAll() {
        do {
            sources = try store.reconnectSources()
            people = try store.people()
            stats = try store.stats(currentEmbedder: embedder.id)
            favorites = try store.favoriteIDs()
        } catch { errorMessage = error.localizedDescription }
        selectedPeople.removeAll { id in !people.contains { $0.id == id } }
        runSearch()
    }

    /// Called when the app comes back to the foreground: a card reader may have been plugged in or removed.
    func reconnectSources() {
        access.reconnectAll(store: store)
        sources = (try? store.reconnectSources()) ?? sources
    }

    func person(_ id: Int64?) -> Person? {
        if let p = people.first(where: { $0.id == id }) { return p }
        guard let id, let pp = privateContent?.people.first(where: { $0.id == id }) else { return nil }
        return Person(id: pp.id, name: pp.name, coverFaceID: nil, photoCount: 0, faceCount: 0, uncertainCount: 0, lastSeen: nil)
    }
    func source(_ id: Int64) -> Source? { sources.first { $0.id == id } }
    var namedPeople: [Person] { people.filter(\.isNamed) }
    var unnamedGroups: [Person] { people.filter { !$0.isNamed && $0.photoCount > 0 } }

    /// The original isn't reachable on this iPhone right now (drive unplugged, folder moved).
    func isOffline(_ photo: Photo) -> Bool {
        guard photo.id > 0, let s = source(photo.sourceID) else { return false }
        return !s.isOnline
    }

    /// VoiceOver description of a photo: date and who is in it.
    func describe(_ photo: Photo) -> String {
        var parts = ["Photo"]
        if let d = photo.takenAt { parts.append(d.formatted(date: .long, time: .shortened)) }
        if favorites.contains(photo.id) { parts.append("favourite") }
        if isOffline(photo) { parts.append("original not connected") }
        return parts.joined(separator: ", ")
    }

    func namesInPhoto(_ photoID: Int64) -> [String] {
        let faces = photoID < 0 ? (privateContent?.items.first { $0.photo.id == photoID }?.faces ?? []) : ((try? store.faces(photoID: photoID)) ?? [])
        return Array(Set(faces.filter { $0.state.isCertain }.compactMap { person($0.personID)?.name })).sorted()
    }

    // MARK: Find

    func toggle(_ personID: Int64) {
        if let i = selectedPeople.firstIndex(of: personID) { selectedPeople.remove(at: i) } else { selectedPeople.append(personID) }
    }

    /// Search runs off the main thread so typing, selecting and scrolling never wait on the database.
    func runSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        guard !selectedPeople.isEmpty else { results = []; uncertainExtra = 0; isSearching = false; return }
        let store = store, ids = selectedPeople, mode = matchMode, uncertain = includeUncertain
        isSearching = true
        Task {
            let (found, other) = await Task.detached(priority: .userInitiated) { () -> ([SearchResult], Int) in
                let found = (try? store.search(people: ids, mode: mode, includeUncertain: uncertain)) ?? []
                let other = (try? store.search(people: ids, mode: mode, includeUncertain: !uncertain).count) ?? found.count
                return (found, other)
            }.value
            guard generation == searchGeneration else { return }
            results = found
            uncertainExtra = uncertain ? found.count - other : other - found.count
            isSearching = false
        }
    }

    var strongResults: [SearchResult] { results.filter { !$0.eyesClosed && !$0.soft } }
    var weakerResults: [SearchResult] { results.filter { $0.eyesClosed || $0.soft } }

    /// Plain-language description of the current query.
    var querySentence: String {
        let names = selectedPeople.compactMap { person($0)?.displayName }
        switch names.count {
        case 0: return "Choose people to find the photos they’re in."
        case 1: return matchMode == .only ? "Solo photos of \(names[0])" : "Photos of \(names[0])"
        default:
            let list = ListFormatter.localizedString(byJoining: names)
            switch matchMode {
            case .all: return "Photos where \(list) \(names.count == 2 ? "both" : "all") appear"
            case .any: return "Photos with \(list.replacingOccurrences(of: " and ", with: " or "))"
            case .only: return "Photos of just \(list), nobody else"
            }
        }
    }

    // MARK: Corrections (each one re-runs matching so the library learns from it)

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
        refreshAll()
        scheduleRematch()
    }

    /// An undoable correction: snapshot, apply, and offer Undo for a few seconds.
    func change(_ label: String, fragile: [Int64] = [], _ action: () throws -> Void) {
        let snapshot = try? store.captureUndo(label, fragileFaceIDs: fragile)
        perform(action)
        PhotoImages.shared.invalidateFaces()
        undo = UndoOffer(text: label, snapshot: snapshot)
    }

    func applyUndo(_ offer: UndoOffer) {
        guard let snapshot = offer.snapshot else { return }
        do { try store.restore(snapshot) } catch { errorMessage = "Couldn’t undo: \(error.localizedDescription)" }
        PhotoImages.shared.invalidateFaces()
        undo = nil
        refreshAll()
    }

    @ObservationIgnored private var rematchTask: Task<Void, Never>?
    func scheduleRematch() {
        rematchTask?.cancel()
        let store = store, id = embedder.id, t = thresholds, vault = vault
        rematchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isMatching = true
            await Task.detached(priority: .userInitiated) {
                if vault.isSetUp { try? vault.matchAndRoute(embedderID: id, thresholds: t) }
                else { try? store.runMatching(embedderID: id, thresholds: t) }
            }.value
            self?.reloadPrivateContent()
            self?.isMatching = false
            self?.refreshAll()
        }
    }

    func name(personID: Int64, as name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change("Named “\(clean)”") { _ = try store.name(personID: personID, as: clean) }
    }
    func confirm(_ faceIDs: [Int64]) { change(faceIDs.count == 1 ? "Confirmed" : "Confirmed \(faceIDs.count) faces") { try store.confirm(faceIDs: faceIDs) } }
    func reject(_ faceIDs: [Int64]) { change(faceIDs.count == 1 ? "Removed from person" : "Removed \(faceIDs.count) faces") { try store.reject(faceIDs: faceIDs) } }
    func assign(_ faceIDs: [Int64], to personID: Int64) {
        change("Moved to \(person(personID)?.displayName ?? "person")") { try store.assign(faceIDs: faceIDs, to: personID) }
    }
    func ignore(_ faceIDs: [Int64]) { change("Ignored \(Format.count(faceIDs.count, "face"))", fragile: faceIDs) { try store.ignore(faceIDs: faceIDs) } }
    func merge(_ source: Int64, into target: Int64) {
        let label = "Merged \(person(source)?.displayName ?? "") into \(person(target)?.displayName ?? "")"
        change(label) { try store.merge(source, into: target) }
        selectedPeople = selectedPeople.map { $0 == source ? target : $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    func forget(_ personID: Int64) {
        selectedPeople.removeAll { $0 == personID }
        let faceIDs = (try? store.db.read { try $0.query("SELECT id FROM faces WHERE person_id = ?", [personID]) { $0.int(0) } }) ?? []
        change("Forgot \(person(personID)?.displayName ?? "person")", fragile: faceIDs) { try store.forget(personID: personID) }
    }
    @discardableResult
    func split(_ faceIDs: [Int64], name: String?) -> Int64? {
        var id: Int64?
        change(name.map { "New person “\($0)”" } ?? "Split off \(Format.count(faceIDs.count, "face"))") { id = try store.moveToNewPerson(faceIDs: faceIDs, name: name) }
        return id
    }
    func setCover(personID: Int64, faceID: Int64) { perform { try store.setCover(personID: personID, faceID: faceID) } }

    func toggleFavorite(_ photos: [Photo]) {
        let ids = photos.map(\.id).filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        let on = !ids.allSatisfy(favorites.contains)
        do { try store.setFavorite(ids, on) } catch { errorMessage = error.localizedDescription; return }
        if on { favorites.formUnion(ids) } else { favorites.subtract(ids) }
    }

    // MARK: Sources and importing

    func makeEngine() -> ScanEngine {
        let e = ScanEngine(store: store, embedder: embedder, thresholds: thresholds)
        // Phones have fewer cores to spare and must stay cool and responsive while scanning.
        e.workers = min(e.workers, 2)
        if vault.isSetUp { e.vault = vault }
        return e
    }

    func addFolder(_ url: URL) {
        do {
            let source = try access.addPickedFolder(url, store: store)
            sources = try store.sources()
            scan = PhoneScan(model: self, source: source)
        } catch { errorMessage = "Pixora couldn’t open that folder: \(error.localizedDescription)" }
    }

    /// Photos and single files are copied into Pixora's folder first, then scanned like any folder.
    func scanManagedFolder(_ folder: URL) {
        do {
            let source = try store.addSource(url: folder)
            sources = try store.sources()
            scan = PhoneScan(model: self, source: source)
        } catch { errorMessage = error.localizedDescription }
    }

    func rescan(_ source: Source) {
        guard source.isOnline else { errorMessage = "“\(source.name)” isn’t connected. Plug it in, then reconnect it here."; return }
        scan = PhoneScan(model: self, source: source)
    }

    /// Reconnect a source to the folder the person picked, after checking it really holds the same photos.
    func reconnect(_ source: Source, to url: URL) -> (checked: Int, matched: Int)? {
        _ = url.startAccessingSecurityScopedResource()
        let check = try? store.verifyRelocation(sourceID: source.id, to: url)
        if let check, check.checked > 0, check.matched * 2 < check.checked { return check }
        do { try access.reconnect(source, to: url, store: store) } catch { errorMessage = error.localizedDescription }
        refreshAll()
        return nil
    }

    func forceReconnect(_ source: Source, to url: URL) {
        do { try access.reconnect(source, to: url, store: store) } catch { errorMessage = error.localizedDescription }
        refreshAll()
    }

    /// Remove a source from the library. Pixora's own copies (from Photos or Files) are deleted only when asked;
    /// folders the person picked are never touched.
    func remove(_ source: Source, deleteCopies: Bool) {
        access.forget(source)
        perform { try store.removeSource(source.id) }
        if deleteCopies && SourceAccess.isManaged(source) { try? FileManager.default.removeItem(at: source.url) }
    }

    // MARK: Export

    func exportItems(_ photos: [Photo]) -> [ExportItem] {
        photos.compactMap { p in
            guard let s = source(p.sourceID) else { return nil }
            return ExportItem(photo: p, sourceRoot: s.url, people: namesInPhoto(p.id))
        }
    }

    func openViewer(_ photos: [Photo], at id: Int64, title: String) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        viewer = ViewerRequest(photos: photos, index: i, title: title)
    }
}
