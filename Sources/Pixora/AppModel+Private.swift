import SwiftUI
import AppKit
import PixoraCore

extension AppModel {
    var isPrivateUnlocked: Bool { privateContent != nil }
    /// Photos and people can be made private once Private Space exists — locked or not (new items are
    /// encrypted to its public key).
    /// Asked by every photo tile as it scrolls past, and answering means a Keychain lookup, so it's remembered until
    /// Private Space is created or erased.
    var canMakePrivate: Bool {
        if let known = vaultSetUpCache, known.epoch == vaultEpoch { return known.isSetUp }
        let isSetUp = vault.isSetUp
        vaultSetUpCache = (vaultEpoch, isSetUp)
        return isSetUp
    }

    func toggleFavorite(_ photos: [Photo]) {
        let ids = photos.map(\.id).filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        let on = !ids.allSatisfy(favorites.contains)
        do { try store.setFavorite(ids, on) } catch { errorMessage = error.localizedDescription; return }
        if on { favorites.formUnion(ids) } else { favorites.subtract(ids) }
    }

    /// Delete Private Space (forgotten password). Source files and the ordinary library are untouched.
    func deletePrivateSpace() throws {
        lockPrivateSpace()
        if slideshow?.isPrivate == true { slideshow = nil }
        try vault.destroy()
        privateContent = nil
        ImageCache.shared.purgePrivate(); ViewerCache.shared.purge()
        vaultEpoch += 1
        refreshAll()
    }

    // MARK: Lock / unlock

    /// Unlock with the password. Key derivation (PBKDF2, 600k rounds) runs off the main thread.
    func unlockPrivateSpace(password: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.unlock(password: password) }.value
        reloadPrivateContent()
        privateRevealID = UUID()
        restartIdleTimer()
    }

    /// Lock immediately: forget the key, drop decrypted content, purge every in-memory private image.
    func lockPrivateSpace() {
        guard privateContent != nil || vault.isUnlocked else { return }
        vault.lockNow()
        privateContent = nil
        ImageCache.shared.purgePrivate()
        ViewerCache.shared.purge()
        if let v = viewer, v.photos.contains(where: { $0.id < 0 }) { viewer = nil }
        if slideshow?.isPrivate == true { slideshow = nil }
        idleTimer?.invalidate()
    }

    func reloadPrivateContent() {
        guard vault.isUnlocked else { privateContent = nil; return }
        do {
            let content = try vault.loadContent()
            ImageCache.shared.purgePrivate()
            for item in content.items { ImageCache.shared.registerPrivate(photoID: item.photo.id, jpeg: item.preview, faces: item.faces.map { ($0.id, $0.thumb) }) }
            privateContent = content
        } catch { errorMessage = error.localizedDescription }
    }

    func privateFaces(_ photoID: Int64) -> [Face] { privateContent?.items.first { $0.photo.id == photoID }?.faces ?? [] }
    func privateItem(photoID: Int64) -> PrivateVault.Item? { privateContent?.items.first { $0.photo.id == photoID } }

    // MARK: Moving things in and out

    func makePrivate(photos: [Photo]) {
        let ids = photos.map(\.id).filter { $0 > 0 }
        guard canMakePrivate, !ids.isEmpty else { return }
        do { try vault.makePhotosPrivate(ids) } catch { errorMessage = error.localizedDescription }
        ImageCache.shared.forget(photoIDs: ids)
        ViewerCache.shared.purge()
        refreshAll(); reloadPrivateContent()
        toast = Toast(text: "\(Format.count(ids.count, "photo")) moved to Private Space", offersUndo: false)
    }

    func makePrivate(personID: Int64) {
        guard canMakePrivate else { return }
        let name = person(personID)?.displayName ?? "This person"
        do { try vault.makePersonPrivate(personID) } catch { errorMessage = error.localizedDescription }
        ImageCache.shared.invalidateFaces(); ViewerCache.shared.purge()
        selectedPeople.removeAll { $0 == personID }
        if openPersonID == personID { openPersonID = nil }
        refreshAll(); reloadPrivateContent()
        toast = Toast(text: "\(name) is now private", offersUndo: false)
    }

    func moveToLibrary(photos: [Photo]) {
        let items = photos.compactMap { privateItem(photoID: $0.id)?.id }
        guard !items.isEmpty else { return }
        do { try vault.moveToLibrary(items) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
        toast = Toast(text: "\(Format.count(items.count, "photo")) moved back to the library", offersUndo: false)
    }

    func confirmPrivateMatch(_ item: PrivateVault.Item) {
        do { try vault.confirmPending(item.id) } catch { errorMessage = error.localizedDescription }
        reloadPrivateContent()
    }

    func rejectPrivateMatch(_ item: PrivateVault.Item) {
        do { try vault.rejectPending(item.id) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
    }

    func makePersonPublic(_ personID: Int64) {
        do { try vault.makePersonPublic(personID) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
    }

    // MARK: Auto-lock

    /// Lock on sleep, on screen lock, and after inactivity (Settings → Private Space).
    func startPrivateSpaceGuards() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockPrivateSpace() }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockPrivateSpace() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockPrivateSpace() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel, .mouseMoved]) { [weak self] e in
            MainActor.assumeIsolated { if self?.isPrivateUnlocked == true { self?.restartIdleTimer() } }
            return e
        }
    }

    func restartIdleTimer() {
        idleTimer?.invalidate()
        let minutes = UserDefaults.standard.object(forKey: "privateIdleMinutes") as? Int ?? 5
        guard minutes > 0, isPrivateUnlocked else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockPrivateSpace() }
        }
    }
}
