import SwiftUI
import PixoraCore

struct SettingsScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lockOnLeave") private var lockOnLeave = true
    @AppStorage("privateIdleMinutes") private var idleMinutes = 5
    @State private var keepPreviews = AppSettings.keepPreviews
    @State private var librarySize: Int64 = 0
    @State private var copiesSize: Int64 = 0

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Matching")
                            Spacer()
                            Text(model.strictness < -0.01 ? "Looser" : (model.strictness > 0.01 ? "Stricter" : "Balanced")).foregroundStyle(Palette.ink2)
                        }
                        Slider(value: $model.strictness, in: -0.08...0.08, step: 0.02) { Text("Matching strictness") }
                    }
                } header: { Text("Faces") } footer: {
                    Text("Stricter puts fewer faces in a person automatically and sends more to Review. Face model: \(model.embedder.displayName).")
                }

                Section {
                    Toggle("Lock when switching tabs", isOn: $lockOnLeave)
                    Picker("Lock after inactivity", selection: $idleMinutes) {
                        Text("1 minute").tag(1); Text("2 minutes").tag(2); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("Never").tag(0)
                    }
                } header: { Text("Private Space") } footer: {
                    Text("Private Space always locks when Pixora leaves the screen, and the app-switcher preview never shows photos. Its password is separate from your passcode, Face ID and Apple Account.")
                }

                Section {
                    LabeledContent("Library on this iPhone", value: Format.size(librarySize))
                    LabeledContent("Copies from Photos and Files", value: Format.size(copiesSize))
                    Toggle("Keep small previews", isOn: $keepPreviews).onChange(of: keepPreviews) { _, on in AppSettings.keepPreviews = on }
                } header: { Text("Storage") } footer: {
                    Text("Previews let you browse people and photos while a card or drive is unplugged. Photos picked from Photos or as single files are copied into Pixora; your originals stay where they are.")
                }

                Section {
                    info("wifi.slash", "Works offline", "Scanning, face matching, people, Find Photos, Private Space and slideshows all run on this iPhone without internet.")
                    info("icloud.slash", "No account, no cloud", "No sign-in. No photos, faces or names are uploaded. Pixora has no AI-provider setting; every feature is processed on the device.")
                    info("magnifyingglass", "Search by what’s in a photo", "Available on the Mac only for now: its 1.7 GB model is too large to run comfortably on a phone.")
                } header: { Text("Privacy") }

                Section {
                    info("laptopcomputer.and.iphone", "Each device has its own library", "Your Mac and this iPhone don’t share people or matches yet. A photo on your Mac’s SD card isn’t available here unless you import it on this iPhone too.")
                    info("arrow.left.arrow.right", "Planned: optional transfer", "A “people pack” you send yourself by AirDrop or Files: names and face templates only, no photos, with private people left out unless you choose otherwise. Not built yet.")
                } header: { Text("Mac and iPhone") }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text("Made by Mithin Sagar. MIT License. The bundled face models (SCRFD and ArcFace from InsightFace) are for non-commercial use.")
                        .font(.footnote).foregroundStyle(Palette.ink2)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                let (a, b) = await Task.detached(priority: .utility) {
                    (StorageInfo.size(of: AppPaths.root), StorageInfo.size(of: SourceAccess.importedRoot))
                }.value
                librarySize = a; copiesSize = b
            }
        }
    }

    private func info(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Palette.safelight).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(Palette.ink2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
