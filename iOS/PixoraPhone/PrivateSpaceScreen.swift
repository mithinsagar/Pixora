import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

struct PrivateSpaceScreen: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        ZStack {
            VaultBackdrop()
            Group {
                if !model.isPrivateSetUp || model.privateSetupInProgress {
                    PrivateSetup().transition(.opacity)
                } else if !model.isPrivateUnlocked {
                    PrivateUnlock().transition(.opacity)
                } else {
                    PrivateContent()
                        .overlay { RevealOverlay(token: model.privateRevealID) }
                        .transition(.opacity)
                }
            }
            // Locking is instant (no animation); only unlocking fades in.
            .animation(model.isPrivateUnlocked ? .easeOut(duration: 0.2) : nil, value: model.isPrivateUnlocked)
        }
        .environment(\.colorScheme, .dark)
        .toolbarBackground(Vault.night, for: .tabBar)
        .sheet(isPresented: Binding(get: { model.showDeletePrivate }, set: { model.showDeletePrivate = $0 })) {
            DeletePrivateSpaceSheet(forgot: model.deleteIsForgot)
        }
    }
}

// MARK: - Password file

/// The one copy of the password outside the person's head: a text file saved only where they choose in the
/// Files save sheet. Pixora never emails, uploads or syncs it, and keeps no copy of its own.
struct PasswordDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(password: String) {
        text = """
        Pixora — Private Space password

        Password: \(password)

        Saved \(Date().formatted(date: .long, time: .shortened)).

        This is the password for Private Space in Pixora. It is not your iPhone passcode, Mac login, Apple Account
        or any other password. Anyone who has this file can open your Private Space. Keep it somewhere safe and not
        next to your photos or in a shared folder. If you change the password in Pixora, this file no longer works.

        """
    }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// "Keep a copy" panel, shared by setup and password change.
struct PasswordFilePanel: View {
    let password: String
    @State private var exporting = false
    @State private var savedName: String?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.fill").font(.title).foregroundStyle(Vault.brass)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pixora Private Space Password.txt").font(.subheadline.weight(.semibold)).foregroundStyle(Vault.ink)
                            Text("You pick where it goes in Files. Nothing is saved until you do.").font(.caption).foregroundStyle(Vault.ink2)
                        }
                    }
                    Button { exporting = true } label: { Label(savedName == nil ? "Save Password File…" : "Save Another Copy…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(VaultButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("private.savePasswordFile")
                    if let savedName { Label("Saved as “\(savedName)”", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Vault.safe) }
                    if let failed { Text(failed).font(.subheadline).foregroundStyle(Vault.errorText) }
                }
            }
            Label {
                Text("Anyone with this file can open Private Space. A password manager, an encrypted drive or a printed copy kept somewhere safe is better than a shared folder.")
                    .font(.footnote).foregroundStyle(Vault.ink2)
            } icon: { Image(systemName: "exclamationmark.shield").foregroundStyle(Vault.brass) }
        }
        .fileExporter(isPresented: $exporting, document: PasswordDocument(password: password), contentType: .plainText,
                      defaultFilename: "Pixora Private Space Password") { result in
            switch result {
            case .success(let url): savedName = url.lastPathComponent; failed = nil
            case .failure(let e): failed = e.localizedDescription
            }
        }
    }
}

// MARK: - Setup

private struct PrivateSetup: View {
    @Environment(PhoneModel.self) private var model
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false
    @State private var keptPassword: String?
    @State private var leftovers = PrivateVault.Footprint()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Spacer(); LensEmblem(size: 110, symbol: keptPassword == nil ? "lock.fill" : "checkmark"); Spacer() }
                    .padding(.top, 8)
                if let kept = keptPassword { step2(kept) } else { step1 }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { leftovers = model.vault.hasLeftovers ? model.vault.footprint() : PrivateVault.Footprint() }
    }

    private var step1: some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultEyebrow(text: "Private Space", icon: "lock")
            Text("A hidden place for photos").font(Vault.title(.largeTitle)).foregroundStyle(Vault.ink)
            Text("Create a **password just for Pixora**. It isn’t your iPhone passcode, Face ID, Apple Account or Google password. Make up a new one you’ll remember.")
                .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            if !leftovers.isEmpty {
                Text("An earlier Private Space on this iPhone can no longer be opened. Creating a new one deletes its \(Format.count(leftovers.items, "encrypted copy", "encrypted copies")). Your originals aren’t touched.")
                    .font(.footnote).foregroundStyle(Vault.brass)
            }
            VaultPasswordField(title: "New password", text: $password, isNew: true)
                .accessibilityIdentifier("private.new")
            StrengthBar(password: password)
            VaultPasswordField(title: "Type it again", text: $confirm, isNew: true, onSubmit: create)
                .accessibilityIdentifier("private.confirm")
            if let error { Text(error).font(.subheadline).foregroundStyle(Vault.errorText) }
            Button(action: create) {
                if working { ProgressView().tint(Vault.onBrass) } else { Text("Create Private Space") }
            }
            .buttonStyle(VaultButtonStyle())
            .disabled(password.isEmpty || confirm.isEmpty || working)
            .accessibilityIdentifier("private.create")
            VStack(alignment: .leading, spacing: 12) {
                promise("lock.doc", "Encrypted on this iPhone", "Private photos become encrypted copies (AES-256 with keys protected by your password) and leave the library.")
                promise("eye.slash", "Out of sight", "Hidden from Library, Find, People, search and slideshows. It locks the moment you leave Pixora.")
                promise("wifi.slash", "Offline, no account", "Nothing is uploaded or synced. Unlocking works without internet.")
                promise("arrow.counterclockwise", "Forgot it?", "Nobody can recover the password. You can delete Private Space and start again; your originals are never touched.")
            }
            .padding(.top, 6)
        }
    }

    private func step2(_ kept: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultEyebrow(text: "Private Space is ready", icon: "checkmark.circle.fill", color: Vault.safe)
            Text("Keep a copy of your password").font(Vault.title(.largeTitle)).foregroundStyle(Vault.ink)
            Text("Pixora can’t show or recover it later. If you forget it, the only way back is to delete Private Space and start again.")
                .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            PasswordFilePanel(password: kept)
            Text("Saving a copy is optional.").font(.footnote).foregroundStyle(Vault.ink3)
            Button("Done") { keptPassword = nil; model.privateSetupInProgress = false }
                .buttonStyle(VaultButtonStyle())
                .accessibilityIdentifier("private.done")
        }
    }

    private func promise(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Vault.brass).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Vault.ink)
                Text(text).font(.footnote).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func create() {
        error = nil
        guard password == confirm else { error = "The two passwords don’t match."; return }
        do { try PrivateVault.checkStrength(password) } catch { self.error = error.localizedDescription; return }
        working = true
        let pw = password
        Task {
            do {
                model.privateSetupInProgress = true
                try await model.createPrivateSpace(password: pw)
                keptPassword = pw
                password = ""; confirm = ""
            } catch {
                model.privateSetupInProgress = false
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Unlock

private struct PrivateUnlock: View {
    @Environment(PhoneModel.self) private var model
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @State private var shake = 0
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                LensEmblem(size: 140, opening: password.isEmpty ? 0 : min(0.35, CGFloat(password.count) * 0.03))
                    .animation(.easeOut(duration: 0.25), value: password.count)
                    .padding(.top, 20)
                VStack(spacing: 8) {
                    Text("Locked away").font(Vault.title(.largeTitle)).foregroundStyle(Vault.ink)
                    Text("Enter your Private Space password.").foregroundStyle(Vault.ink2)
                }
                VaultPasswordField(title: "Password", text: $password, onSubmit: unlock)
                    .focused($focused)
                    .modifier(Shake(times: CGFloat(shake)))
                    .accessibilityIdentifier("private.password")
                if let error { Text(error).font(.subheadline).foregroundStyle(Vault.errorText).accessibilityIdentifier("private.error") }
                Button(action: unlock) {
                    if working { ProgressView().tint(Vault.onBrass) } else { Text("Unlock") }
                }
                .buttonStyle(VaultButtonStyle())
                .disabled(password.isEmpty || working)
                .accessibilityIdentifier("private.unlock")
                Button("Forgot password?") { model.deleteIsForgot = true; model.showDeletePrivate = true }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Vault.brass).frame(minHeight: 44)
                VStack(alignment: .leading, spacing: 8) {
                    footnote("person.badge.key", "Separate from your iPhone passcode and Apple Account.")
                    footnote("lock.rotation", "Locks when you leave Pixora or switch tabs.")
                    footnote("wifi.slash", "Works offline.")
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func footnote(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.footnote).foregroundStyle(Vault.ink3).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true; error = nil
        let pw = password
        Task {
            do {
                try await model.unlockPrivateSpace(password: pw)
                password = ""
            } catch {
                self.error = error.localizedDescription
                password = ""   // start fresh, like the system lock screen
                withAnimation(.linear(duration: 0.3)) { shake += 1 }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            working = false
        }
    }
}

private struct Shake: GeometryEffect {
    var times: CGFloat
    var animatableData: CGFloat { get { times } set { times = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(times * .pi * 4), y: 0))
    }
}

// MARK: - Unlocked

private struct PrivateContent: View {
    @Environment(PhoneModel.self) private var model
    enum Pane: Hashable { case photos, people, review }
    @State private var pane: Pane = .photos
    @State private var selecting = false
    @State private var selection: Set<Int64> = []
    @State private var studio = false
    @State private var changing = false

    private var content: PrivateVault.Content { model.privateContent ?? PrivateVault.Content() }
    private var photos: [Photo] { content.items.filter { !$0.isPendingReview }.map(\.photo) }
    private var pending: [PrivateVault.Item] { content.items.filter(\.isPendingReview) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        VaultEyebrow(text: "Unlocked", icon: "lock.open")
                        Text("Hidden photos").font(Vault.title(.largeTitle)).foregroundStyle(Vault.ink)
                        Text("Only visible here while unlocked. Locks when you leave Pixora, switch tabs or step away.")
                            .font(.subheadline).foregroundStyle(Vault.ink2)
                    }
                    .padding(.horizontal, 16)
                    Picker("Show", selection: $pane) {
                        Text("Photos \(photos.count)").tag(Pane.photos)
                        Text("People \(content.people.count)").tag(Pane.people)
                        Text("Review \(pending.count)").tag(Pane.review)
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    switch pane {
                    case .photos: photosPane
                    case .people: peoplePane
                    case .review: reviewPane
                    }
                }
                .padding(.vertical, 8)
            }
            .background { VaultBackdrop() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.lockPrivateSpace() } label: { Label("Lock", systemImage: "lock.fill").labelStyle(.titleAndIcon) }
                        .font(.headline).tint(Vault.brass)
                        .accessibilityIdentifier("private.lock")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if pane == .photos && !photos.isEmpty { Button(selecting ? "Done" : "Select") { selecting.toggle(); selection = [] }.tint(Vault.brass) }
                    Menu {
                        Button { studio = true } label: { Label("Private Slideshow", systemImage: "play.rectangle") }.disabled(photos.isEmpty)
                        Button { changing = true } label: { Label("Change Password", systemImage: "key") }
                        Divider()
                        Button(role: .destructive) { model.deleteIsForgot = false; model.showDeletePrivate = true } label: { Label("Delete Private Space", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .tint(Vault.brass)
                    .accessibilityLabel("Private Space options")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack(spacing: 10) {
                        Button("Move to Library") { model.moveToLibrary(photos: photos.filter { selection.contains($0.id) }); selection = []; selecting = false }
                            .buttonStyle(VaultButtonStyle(kind: .secondary))
                        Button("Share") { model.share = ShareRequest(photos: photos.filter { selection.contains($0.id) }) }
                            .buttonStyle(VaultButtonStyle())
                    }
                    .disabled(selection.isEmpty)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Vault.night.opacity(0.92))
                }
            }
            .sheet(isPresented: $studio) { SlideshowStudio(source: .privateSpace) }
            .sheet(isPresented: $changing) { ChangePasswordSheet() }
        }
        .simultaneousGesture(TapGesture().onEnded { model.restartIdleTimer() })
        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in model.restartIdleTimer() })
    }

    @ViewBuilder private var photosPane: some View {
        if photos.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "eye.slash").font(.system(size: 36)).foregroundStyle(Vault.brass)
                Text("Nothing hidden yet").font(Vault.title(.title2)).foregroundStyle(Vault.ink)
                Text("Select photos anywhere and choose Private, or open a person and choose Make Private.")
                    .font(.subheadline).foregroundStyle(Vault.ink2).multilineTextAlignment(.center)
            }
            .padding(30).frame(maxWidth: .infinity)
        } else {
            PhotoGrid(photos: photos, selection: selecting ? $selection : nil) { p in
                model.viewer = ViewerRequest(photos: photos, index: photos.firstIndex(of: p) ?? 0, title: "Private Space")
            }
        }
    }

    @ViewBuilder private var peoplePane: some View {
        if content.people.isEmpty {
            Text("No private people. Open someone in People and choose Make Private: their future confirmed matches come here too.")
                .font(.subheadline).foregroundStyle(Vault.ink2).padding(.horizontal, 16)
        } else {
            VStack(spacing: 10) {
                ForEach(content.people) { p in
                    let count = content.items.filter { $0.persons.contains(p.id) && !$0.isPendingReview }.count
                    VaultCard {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(Vault.brass.opacity(0.8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline).foregroundStyle(Vault.ink)
                                Text(Format.count(count, "photo")).font(.caption).foregroundStyle(Vault.ink2)
                            }
                            Spacer()
                            Menu {
                                Button { model.makePersonPublic(p.id) } label: { Label("Make Public Again", systemImage: "lock.open") }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.tint(Vault.brass)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var reviewPane: some View {
        if pending.isEmpty {
            Text("Nothing to check. When Pixora isn’t sure a new photo shows a private person, it waits here, out of the library, until you decide.")
                .font(.subheadline).foregroundStyle(Vault.ink2).padding(.horizontal, 16)
        } else {
            VStack(spacing: 12) {
                ForEach(pending) { item in
                    let name = content.people.first { $0.id == item.pendingPerson }?.name ?? "this person"
                    VaultCard {
                        HStack(spacing: 14) {
                            PhotoTile(photo: item.photo, showsOffline: false).frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Is this \(name)?").font(Vault.title(.title3)).foregroundStyle(Vault.ink)
                                HStack(spacing: 8) {
                                    Button("No") { model.rejectPrivateMatch(item) }.buttonStyle(VaultButtonStyle(kind: .secondary))
                                    Button("Yes") { model.confirmPrivateMatch(item) }.buttonStyle(VaultButtonStyle())
                                }
                            }
                        }
                    }
                }
                Text("“No” sends the photo back to the library.").font(.footnote).foregroundStyle(Vault.ink3)
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Change password

struct ChangePasswordSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false
    @State private var changed: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VaultBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let changed {
                            VaultEyebrow(text: "Password changed", icon: "checkmark.circle.fill", color: Vault.safe)
                            Text("Keep a copy of the new password").font(Vault.title()).foregroundStyle(Vault.ink)
                            Text("Any password file you saved before no longer works.").foregroundStyle(Vault.ink2)
                            PasswordFilePanel(password: changed)
                            Button("Done") { dismiss() }.buttonStyle(VaultButtonStyle())
                        } else {
                            Text("Change password").font(Vault.title()).foregroundStyle(Vault.ink)
                            Text("You’ll need the current password. This happens on this iPhone, offline. Nothing is sent anywhere.")
                                .foregroundStyle(Vault.ink2)
                            VaultPasswordField(title: "Current password", text: $current)
                            VaultPasswordField(title: "New password", text: $new, isNew: true)
                            StrengthBar(password: new)
                            VaultPasswordField(title: "Type the new one again", text: $confirm, isNew: true, onSubmit: change)
                            if let error { Text(error).font(.subheadline).foregroundStyle(Vault.errorText) }
                            Button(action: change) {
                                if working { ProgressView().tint(Vault.onBrass) } else { Text("Change Password") }
                            }
                            .buttonStyle(VaultButtonStyle())
                            .disabled(current.isEmpty || new.isEmpty || confirm.isEmpty || working)
                        }
                    }
                    .padding(20)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { if changed == nil { Button("Cancel") { dismiss() }.tint(Vault.brass) } } }
        }
        .environment(\.colorScheme, .dark)
    }

    private func change() {
        error = nil
        guard new == confirm else { error = "The new passwords don’t match."; return }
        do { try PrivateVault.checkStrength(new) } catch { self.error = error.localizedDescription; return }
        working = true
        let c = current, n = new
        Task {
            do { try await model.changePrivatePassword(current: c, new: n); changed = n; current = ""; new = ""; confirm = "" }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

// MARK: - Delete

/// Forgotten password or a deliberate delete: says exactly what goes and what stays, and needs a confirmation.
struct DeletePrivateSpaceSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var forgot = true
    @State private var footprint = PrivateVault.Footprint()
    @State private var understood = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            ZStack {
                VaultBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if done { finished } else { explain }
                    }
                    .padding(20)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { if !done { Button("Cancel") { dismiss() }.tint(Vault.brass) } } }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { footprint = model.vault.footprint() }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultEyebrow(text: "Private Space deleted", icon: "checkmark.circle.fill", color: Vault.safe)
            Text("You can start again").font(Vault.title()).foregroundStyle(Vault.ink)
            Text("The old Private Space is gone and can’t be recovered. Your original photos and your regular library are exactly as they were.")
                .foregroundStyle(Vault.ink2)
            Button("Create New Private Space") { dismiss() }.buttonStyle(VaultButtonStyle())
        }
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 16) {
            VaultEyebrow(text: forgot ? "Forgot your password?" : "Delete Private Space", color: Vault.danger)
            Text(forgot ? "Your password can’t be recovered" : "Delete Private Space?").font(Vault.title()).foregroundStyle(Vault.ink)
            Text(forgot
                 ? "Pixora never stored your password, so nobody, including Pixora, can recover or reset it. If you saved a password file, look for “Pixora Private Space Password” in Files. Otherwise the only way back is to delete Private Space and create a new one."
                 : "Everything in Private Space is deleted permanently. You can create a new Private Space afterwards.")
                .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            VaultCard(tint: Vault.danger) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Will be deleted", systemImage: "trash").font(.headline).foregroundStyle(Vault.danger)
                    item("\(Format.count(footprint.items, "encrypted photo copy", "encrypted photo copies")) and their previews and face crops (\(Format.size(footprint.bytes)))")
                    item("\(Format.count(footprint.people, "private person", "private people")), their hidden names and \(Format.count(footprint.faceTemplates, "face template"))")
                    item("Photos waiting in Private Space review")
                    item("The Private Space password and keys on this iPhone")
                }
            }
            VaultCard(tint: Vault.safe) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Stays untouched", systemImage: "checkmark.shield").font(.headline).foregroundStyle(Vault.safe)
                    item("Originals in your Photos library, Files, SD cards and drives. Nothing there is deleted, moved, renamed or changed.", safe: true)
                    item("Your regular library: \(Format.count(model.stats.photos, "photo")) and \(Format.count(model.namedPeople.count, "named person", "named people"))", safe: true)
                    item("Settings, favourites and everything else in Pixora", safe: true)
                }
            }
            Text("Photos that were private appear in the library again the next time you scan where they came from. The deleted copies can’t be recovered.")
                .font(.footnote).foregroundStyle(Vault.ink2)
            Toggle(isOn: $understood) { Text("I understand the old Private Space can’t be recovered").foregroundStyle(Vault.ink) }
                .tint(Vault.danger)
                .accessibilityIdentifier("private.understand")
            if let error { Text(error).foregroundStyle(Vault.errorText) }
            Button { delete() } label: { Label("Delete Private Space", systemImage: "trash.fill") }
                .buttonStyle(VaultButtonStyle(kind: .danger))
                .disabled(!understood)
                .accessibilityIdentifier("private.delete")
        }
    }

    private func item(_ text: String, safe: Bool = false) -> some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(Vault.ink).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: safe ? "checkmark" : "minus").font(.caption.weight(.bold)).foregroundStyle(safe ? Vault.safe : Vault.danger)
        }
    }

    private func delete() {
        do { try model.deletePrivateSpace(); withAnimation { done = true } }
        catch { self.error = error.localizedDescription }
    }
}
