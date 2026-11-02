import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PixoraCore

struct ExportEveryoneRequest: Identifiable {
    let id = UUID()
    let preselected: Set<Int64>
}

extension AppModel {
    // MARK: Files for sharing

    /// Original files for photos whose card/drive is connected.
    func fileURLs(for photos: [Photo]) -> [URL] {
        photos.compactMap { p in
            guard let s = source(p.sourceID), s.isOnline else { return nil }
            return s.url.appendingPathComponent(p.relPath)
        }
    }

    var exportablePhotos: [Photo] { visibleResults.filter { !excludedFromExport.contains($0.id) }.map(\.photo) }

    /// AirDrop / Messages / Mail … via the standard macOS share picker.
    func share(_ photos: [Photo], from view: NSView?) {
        let urls = fileURLs(for: photos)
        guard !urls.isEmpty else { errorMessage = "Connect the card or drive these photos are on to share them."; return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = view ?? NSApp.keyWindow?.contentView
        if let anchor { picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
    }

    /// Send straight to a linked contact: Messages or Mail pre-addressed, or AirDrop.
    func send(_ photos: [Photo], to person: Person, via service: NSSharingService.Name) {
        let urls = fileURLs(for: photos)
        guard !urls.isEmpty else { errorMessage = "Connect the card or drive these photos are on to send them."; return }
        guard let svc = NSSharingService(named: service) else { return }
        if service == .composeMessage { svc.recipients = person.contactHandles.filter { !$0.contains("@") } }
        if service == .composeEmail {
            svc.recipients = person.contactHandles.filter { $0.contains("@") }
            svc.subject = "Photos of you"
        }
        guard svc.canPerform(withItems: urls) else { errorMessage = "\(svc.title) can’t send these files."; return }
        svc.perform(withItems: urls)
    }

    /// Named people confidently in a photo (written into exported copies).
    func namesInPhoto(_ photoID: Int64) -> [String] {
        ((try? store.faces(photoID: photoID)) ?? []).compactMap { f in
            guard f.state.isCertain, let p = person(f.personID), p.isNamed else { return nil }
            return p.displayName
        }
    }

    // MARK: Contact sheet

    func makeContactSheet(_ photos: [Photo], title: String) {
        guard !photos.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title) — contact sheet.pdf"
        let watermark = NSTextField(string: "")
        watermark.placeholderString = "Optional watermark, e.g. PROOF"
        watermark.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        panel.accessoryView = watermark
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
        let frames = photos.map { p -> ContactSheet.Frame in
            let ppl = ((try? store.faces(photoID: p.id)) ?? []).compactMap { f -> String? in
                guard f.state.isCertain, let pid = f.personID, let n = names[pid], person(pid)?.isNamed == true else { return nil }
                return n
            }
            let date = p.takenAt.map { Format.day.string(from: $0) } ?? ""
            return ContactSheet.Frame(photo: p, caption: ([date] + [ppl.joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " · "))
        }
        do {
            let roots = Dictionary(uniqueKeysWithValues: sources.filter(\.isOnline).map { ($0.id, $0.url) })
            try ContactSheet.render(frames, title: title, subtitle: "\(Format.count(photos.count, "photo")) · Pixora", watermark: watermark.stringValue, to: url,
                                    original: { p in roots[p.sourceID].flatMap { ImageLoader.image(at: $0.appendingPathComponent(p.relPath), maxPixel: 640) } })
            NSWorkspace.shared.open(url)
        } catch { errorMessage = "Could not make the contact sheet: \(error)" }
    }

    // MARK: Card inserted

    func checkInsertedCard(_ url: URL) {
        guard AppSettings.cardPrompt else { return }
        let info = VolumeInfo(for: url)
        guard info.looksLikeCameraCard || info.isRemovable else { return }
        let known = sources.first { s in s.volumeUUID != nil && s.volumeUUID == info.uuid }
        let store = store
        Task {
            let count: Int = await Task.detached(priority: .utility) {
                if let known { return store.newFileCount(sourceID: known.id, root: known.url) }
                let dcim = info.url.appendingPathComponent("DCIM", isDirectory: true)
                return FileScanner.preview(root: FileManager.default.fileExists(atPath: dcim.path) ? dcim : info.url).files.count
            }.value
            guard count > 0 else { return }
            cardPrompt = CardPrompt(volume: info, source: known, newPhotos: count)
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func acceptCardPrompt() {
        guard let prompt = cardPrompt else { return }
        cardPrompt = nil
        if let s = prompt.source, let fresh = sources.first(where: { $0.id == s.id }), fresh.isOnline { rescan(fresh) } else { scanVolume(prompt.volume) }
    }

    // MARK: People conveniences

    func setMe(_ id: Int64?) { mePersonID = id }

    func confirmAllUncertain(personID: Int64? = nil) {
        change(personID.flatMap { person($0)?.displayName }.map { "Accept all for \($0)" } ?? "Accept all suggestions") {
            try store.confirmAllUncertain(personID: personID)
        }
    }
    func rejectAllUncertain(personID: Int64) {
        change("Reject all for \(person(personID)?.displayName ?? "person")") { try store.rejectAllUncertain(personID: personID) }
    }
    func setCover(personID: Int64, faceID: Int64) { change("Change cover photo") { try store.setCover(personID: personID, faceID: faceID) } }
    func setContact(personID: Int64, contactID: String?, handles: [String]) {
        change(contactID == nil ? "Unlink contact" : "Link contact") { try store.setContact(personID: personID, contactID: contactID, handles: handles) }
    }

    /// Drag a face onto a person.
    func dropFace(_ payload: String, on personID: Int64) -> Bool {
        guard payload.hasPrefix("pixora-face:"), let id = Int64(payload.dropFirst("pixora-face:".count)) else { return false }
        assign([id], to: personID)
        return true
    }

    // MARK: ⌘K

    var commandPeople: [(id: Int64, name: String)] {
        var list = namedPeople.map { ($0.id, $0.displayName) }
        if let me = mePersonID { list.append((me, "me")) }
        return list
    }

    func apply(_ cmd: ParsedCommand) {
        section = .find
        clearSearchChoices()
        if !cmd.people.isEmpty { selectedPeople = Array(NSOrderedSet(array: cmd.people)) as? [Int64] ?? cmd.people }
        matchMode = cmd.mode ?? (cmd.people.count > 1 ? .all : .all)
        includeUncertain = cmd.includeUncertain
        var f = PhotoFilter(); f.from = cmd.from; f.to = cmd.to
        filter = f
        bestOnly = cmd.bestOnly
        separateWeaker = true
        if cmd.hideWeaker { setExportAll(true); for r in presentation.weaker { toggleExport(r.id) } }
        switch cmd.action {
        case .none: break
        case let .export(destination):
            requestExport()
            if let d = destination { exportDestinationHint = d }
        case .share: share(exportablePhotos, from: nil)
        case .contactSheet: makeContactSheet(exportablePhotos, title: querySentence)
        }
    }
}

/// Where ⌘K asked to export to ("desktop", "downloads"…), picked up by the export sheet.
@MainActor var exportDestinationHint: String?
