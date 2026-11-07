import SwiftUI
import AppKit
import PixoraCore

@main
struct PixoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        Self.migrateSettingsFromRollcall()
        _model = State(initialValue: AppModel())
    }

    /// The app used to be called Rollcall (bundle id local.rollcall.Rollcall); carry its preferences over once.
    private static func migrateSettingsFromRollcall() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromRollcall"), let old = UserDefaults(suiteName: "local.rollcall.Rollcall") else { return }
        let keys = ["strictness", "tileSize", "stackBursts", "separateWeaker", "mePersonID", "uncertainMode",
                    "exportPreset", "exportOrganization", "exportLongEdge", "exportVerify", "exportNames", "exportZip",
                    "everyoneSolo", "everyoneUncertain", "everyoneSkipWeaker", "everyoneZip"]
        for k in keys where defaults.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { defaults.set(v, forKey: k) }
        }
        defaults.set(true, forKey: "migratedFromRollcall")
    }

    var body: some Scene {
        Window("Pixora", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 660)
                .tint(Palette.safelight)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.section = .settings }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder to Scan…") { model.chooseFolder() }.keyboardShortcut("o")
            }
            CommandMenu("Go") {
                Button("Command Bar…") { model.showCommandBar.toggle() }.keyboardShortcut("k")
                Divider()
                Button("Find Photos") { model.section = .find }.keyboardShortcut("1")
                Button("Review") { model.section = .review }.keyboardShortcut("2")
                Button("People") { model.section = .people; model.openPersonID = nil }.keyboardShortcut("3")
                Button("All Photos") { model.section = .allPhotos }.keyboardShortcut("4")
                Button("Insights") { model.section = .insights }.keyboardShortcut("5")
                Button("Cards & Folders") { model.section = .importer }.keyboardShortcut("6")
                Button("Places") { model.section = .places }.keyboardShortcut("7")
                Button("Search") { model.section = .search }.keyboardShortcut("8")
            }
            CommandGroup(after: .toolbar) {
                Button("Larger Thumbnails") { UserDefaults.standard.set(min(UserDefaults.standard.double(forKey: "tileSize").nonZero(190) + 30, 360), forKey: "tileSize") }
                    .keyboardShortcut("+")
                Button("Smaller Thumbnails") { UserDefaults.standard.set(max(UserDefaults.standard.double(forKey: "tileSize").nonZero(190) - 30, 110), forKey: "tileSize") }
                    .keyboardShortcut("-")
                Button("Show/Hide Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        // Settings live in the sidebar (⌘, goes there).
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle; make sure we still get a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { ThemeManager.shared.applyAppearance() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private extension Double {
    func nonZero(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
