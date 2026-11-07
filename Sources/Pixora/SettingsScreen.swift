import SwiftUI
import PixoraCore

/// Settings, in the main window: categories on the left, pages on the right.
struct SettingsScreen: View {
    enum Page: String, CaseIterable, Identifiable {
        case privateSpace, appearance, grid, library, scanning, search, export, privacy, shortcuts, about
        var id: String { rawValue }
        var title: String {
            ["privateSpace": "Private Space", "search": "Search", "appearance": "Appearance", "grid": "Photos & Grid", "library": "Library & Storage", "scanning": "Scanning & Recognition",
             "export": "Export", "privacy": "Privacy & Data", "shortcuts": "Keyboard Shortcuts", "about": "About"][rawValue]!
        }
        var icon: String {
            ["privateSpace": "lock.shield", "search": "magnifyingglass", "appearance": "paintpalette", "grid": "square.grid.3x2", "library": "internaldrive", "scanning": "viewfinder",
             "export": "square.and.arrow.up.on.square", "privacy": "hand.raised", "shortcuts": "keyboard", "about": "info.circle"][rawValue]!
        }
    }
    @AppStorage("settingsPage") private var pageRaw = Page.appearance.rawValue

    var body: some View {
        let page = Page(rawValue: pageRaw) ?? .appearance
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(Typography.display(24)).padding(.horizontal, 12).padding(.bottom, 12)
                ForEach(Page.allCases) { p in
                    Button { withAnimation(.easeOut(duration: 0.15)) { pageRaw = p.rawValue } } label: {
                        Label(p.title, systemImage: p.icon)
                            .font(.system(size: 13, weight: page == p ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(page == p ? Palette.safelight.opacity(0.16) : .clear))
                            .foregroundStyle(page == p ? Palette.ink : Palette.ink2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.vertical, 22).padding(.horizontal, 12)
            .frame(width: 230)
            .background(Palette.panel)
            Divider().overlay(Palette.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(page.title).font(Typography.display(28))
                    switch page {
                    case .privateSpace: PrivateSpacePage()
                    case .appearance: AppearancePage()
                    case .grid: GridPage()
                    case .library: LibraryPage()
                    case .scanning: ScanningPage()
                    case .search: SearchSettingsPage()
                    case .export: ExportDefaultsPage()
                    case .privacy: PrivacySettings().frame(minHeight: 560); CloudSettings().frame(minHeight: 380)
                    case .shortcuts: ShortcutsPage()
                    case .about: AboutPage()
                    }
                }
                .padding(28)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared pieces

struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            if let footnote { Text(footnote).font(.caption).foregroundStyle(Palette.ink2) }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: String?
    @State private var previewDark: Bool?
    private var themes: ThemeManager { ThemeManager.shared }

    var body: some View {
        @Bindable var themes = themes
        let shown = Theme.named(hovered ?? themes.themeID)
        let dark = previewDark ?? (scheme == .dark)
        VStack(alignment: .leading, spacing: 22) {
            // Live preview
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(hovered == nil ? "Preview — \(shown.name)" : "Previewing \(shown.name) (click to apply)").font(.headline)
                        .contentTransition(.opacity)
                    Spacer()
                    Picker("", selection: Binding(get: { dark }, set: { previewDark = $0 })) {
                        Label("Light", systemImage: "sun.max").tag(false)
                        Label("Dark", systemImage: "moon").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                LiveThemePreview(theme: shown, dark: dark, accentOverride: themes.customAccent)
                    .animation(.easeInOut(duration: 0.35), value: shown.id)
                    .animation(.easeInOut(duration: 0.35), value: dark)
            }

            SettingsGroup(title: "Mode") {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button { withAnimation(.easeInOut(duration: 0.3)) { themes.appearance = mode } } label: {
                            VStack(spacing: 8) {
                                ModeSwatch(mode: mode, theme: Theme.named(themes.themeID))
                                Label(mode.label, systemImage: mode.icon).font(.system(size: 12, weight: .medium))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(themes.appearance == mode ? Palette.safelight : Palette.rule, lineWidth: themes.appearance == mode ? 2 : 1))
                        }
                        .buttonStyle(.plain).hoverLift(scale: 1.03, radius: 12)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Themes").font(.headline)
                    Text("\(Theme.all.count) themes · each has a light and a dark version · hover to preview").font(.caption).foregroundStyle(Palette.ink2)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], spacing: 14) {
                    ForEach(Theme.all) { t in
                        ThemeCard(theme: t, selected: t.id == themes.themeID)
                            .onHover { hovered = $0 ? t.id : (hovered == t.id ? nil : hovered) }
                            .onTapGesture { themes.apply(t.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("\(t.name) theme\(t.id == themes.themeID ? ", selected" : "")")
                    }
                }
            }

            SettingsGroup(title: "Accent colour", footnote: "Used for selection, the main buttons and highlights. Text on it switches between light and dark automatically for contrast.") {
                HStack(spacing: 10) {
                    accentChip(nil)
                    ForEach([0xF0874A, 0xE5484D, 0xF5A524, 0x30A46C, 0x12A594, 0x0091FF, 0x6E56CF, 0xD6409F, 0x8E8C99] as [UInt32], id: \.self) { accentChip($0) }
                    Divider().frame(height: 28)
                    ColorPicker("Custom", selection: Binding(
                        get: { themes.customAccent.map { Color(hex: $0) } ?? Theme.named(themes.themeID).accent },
                        set: { c in withAnimation(.easeInOut(duration: 0.3)) { themes.customAccent = NSColor(c).hexValue } }
                    ), supportsOpacity: false)
                    .fixedSize()
                }
            }

            SettingsGroup(title: "Headings") {
                HStack(spacing: 10) {
                    ForEach(HeadingDesign.allCases) { h in
                        Button { withAnimation(.easeInOut(duration: 0.25)) { themes.headingDesign = h } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ana & Ben").font(.system(size: 22, weight: .semibold, design: h.design))
                                Text(h.label).font(.caption).foregroundStyle(Palette.ink2)
                            }
                            .padding(12).frame(width: 170, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(themes.headingDesign == h ? Palette.safelight : Palette.rule, lineWidth: themes.headingDesign == h ? 2 : 1))
                        }
                        .buttonStyle(.plain).hoverLift(scale: 1.03, radius: 10)
                    }
                }
            }
        }
    }

    private func accentChip(_ hex: UInt32?) -> some View {
        let selected = themes.customAccent == hex
        let color = hex.map { Color(hex: $0) } ?? Theme.named(themes.themeID).accent
        return Button { withAnimation(.easeInOut(duration: 0.3)) { themes.customAccent = hex } } label: {
            Circle().fill(color).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Palette.ink.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
                .overlay { if hex == nil { Image(systemName: "paintpalette").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
        }
        .buttonStyle(.plain).hoverLift(scale: 1.15, radius: 14)
        .help(hex == nil ? "Use the theme’s own accent" : "Custom accent")
    }
}

/// Little light / dark / split swatch for the mode buttons.
private struct ModeSwatch: View {
    let mode: AppearanceMode
    let theme: Theme
    var body: some View {
        ZStack {
            switch mode {
            case .light: mini(dark: false)
            case .dark: mini(dark: true)
            case .system:
                mini(dark: false).mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                mini(dark: true).mask(HStack(spacing: 0) { Color.clear; Rectangle() })
            }
        }
        .frame(width: 120, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func mini(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.swatch(1, dark: dark)).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(theme.swatch(3, dark: dark)).frame(width: 46, height: 6)
                HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(theme.swatch(5, dark: dark)).frame(width: 18, height: 18) } }
                RoundedRectangle(cornerRadius: 3).fill(theme.swatch(6, dark: dark)).frame(width: 30, height: 8)
            }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(theme.swatch(0, dark: dark))
        }
    }
}

/// A theme in the gallery: its light half and dark half side by side.
private struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) { half(dark: false); half(dark: true) }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? theme.swatch(6, dark: true) : Palette.rule, lineWidth: selected ? 3 : 1))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, theme.swatch(6, dark: true)).padding(6)
                    }
                }
            HStack(spacing: 6) {
                Circle().fill(theme.swatch(6, dark: false)).frame(width: 9, height: 9)
                Text(theme.name).font(.system(size: 13, weight: .semibold))
            }
            Text(theme.blurb).font(.caption).foregroundStyle(Palette.ink2).lineLimit(2).frame(height: 30, alignment: .top)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card.opacity(selected ? 1 : 0.6)))
        .hoverLift(scale: 1.04, radius: 14, glow: !selected)
    }

    private func half(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.swatch(1, dark: dark)).frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(theme.swatch(3, dark: dark)).frame(width: 44, height: 7)
                RoundedRectangle(cornerRadius: 2).fill(theme.swatch(4, dark: dark)).frame(width: 30, height: 4)
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [theme.swatch(5, dark: dark), theme.swatch(2, dark: dark)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 26, height: 30)
                    }
                }
                Capsule().fill(theme.swatch(6, dark: dark)).frame(width: 36, height: 10)
            }
            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.swatch(0, dark: dark))
        }
    }
}

/// A miniature Pixora window in any theme, using your real photos and faces.
struct LiveThemePreview: View {
    @Environment(AppModel.self) private var model
    let theme: Theme
    let dark: Bool
    var accentOverride: UInt32?
    @State private var thumbs: [CGImage] = []

    private func c(_ i: Int) -> Color {
        if (i == 6), let a = accentOverride { return Color(hex: a) }
        if (i == 7), let a = accentOverride { return NSColor(hex: a).luminance > 0.55 ? Color(hex: 0x111111) : .white }
        return theme.swatch(i, dark: dark)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(["Find Photos", "Review", "People", "All Photos"].enumerated()), id: \.offset) { i, item in
                    Text(item).font(.system(size: 11, weight: i == 0 ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(i == 0 ? c(6).opacity(0.22) : .clear))
                        .foregroundStyle(c(3))
                }
                Text("PEOPLE").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(c(4)).padding(.top, 6).padding(.leading, 8)
                ForEach(model.namedPeople.prefix(4)) { p in
                    HStack(spacing: 6) {
                        FaceImage(faceID: p.coverFaceID, size: 14, shape: AnyShape(Circle()))
                        Text(p.displayName).font(.system(size: 10)).foregroundStyle(c(3)).lineLimit(1)
                    }.padding(.leading, 8)
                }
                Spacer()
            }
            .padding(10).frame(width: 140).background(c(1))
            // Content
            VStack(alignment: .leading, spacing: 10) {
                Text("Photos where Ana and Ben both appear")
                    .font(.system(size: 17, weight: .semibold, design: ThemeManager.shared.headingDesign.design)).foregroundStyle(c(3)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(["Ana", "Ben"], id: \.self) { n in
                        Text(n).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(c(6).opacity(0.18))).overlay(Capsule().strokeBorder(c(6).opacity(0.7))).foregroundStyle(c(3))
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        Text("Together").padding(.horizontal, 7).padding(.vertical, 3).background(c(6)).foregroundStyle(c(7))
                        Text("Any").padding(.horizontal, 7).padding(.vertical, 3).foregroundStyle(c(3))
                    }.font(.system(size: 9, weight: .medium)).background(c(5)).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            ZStack {
                                Rectangle().fill(c(5))
                                if i < thumbs.count { Image(decorative: thumbs[i], scale: 1).resizable().scaledToFill() }
                            }
                            .frame(height: 70).clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(alignment: .topTrailing) {
                                if i == 1 { Text("★ Best").font(.system(size: 7, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(c(6))).foregroundStyle(c(7)).padding(3) }
                            }
                            Text(String(format: "▸%04d", i + 1)).font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(c(6))
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("6 OF 6 SELECTED").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(c(4))
                    Spacer()
                    Text("Copy 6 Photos to Folder…").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(c(6))).foregroundStyle(c(7))
                }
                .padding(8).background(c(1)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity).background(c(0))
        }
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rule))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .task {
            let photos = (try? model.store.photos(limit: 6)) ?? []
            var out: [CGImage] = []
            for p in photos {
                if let img = await ImageCache.shared.photoThumb(p, sourceRoot: model.source(p.sourceID)?.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { out.append(img) }
            }
            thumbs = out
        }
    }
}

// MARK: - Photos & Grid

private struct GridPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tileSize") private var tileSize: Double = 190
    @AppStorage("defaultIncludeUncertain") private var defaultUncertain = false
    @AppStorage("viewerGlow") private var viewerGlow = true

    var body: some View {
        @Bindable var themes = ThemeManager.shared
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Layout") {
                SettingRow(title: "Row height", detail: "⌘+ and ⌘− change it anywhere.") {
                    Slider(value: $tileSize, in: 110...360, step: 10).frame(width: 220)
                    Text("\(Int(tileSize)) pt").font(Typography.edgeLarge).frame(width: 52, alignment: .trailing)
                }
                SettingRow(title: "Spacing between photos") {
                    Slider(value: $themes.gridGap, in: 2...24, step: 1).frame(width: 220)
                    Text("\(Int(themes.gridGap)) pt").font(Typography.edgeLarge).frame(width: 52, alignment: .trailing)
                }
                SettingRow(title: "Photo corners") {
                    Picker("", selection: $themes.tileCorner) {
                        Text("Square").tag(0.0); Text("Subtle").tag(3.0); Text("Soft").tag(8.0); Text("Round").tag(14.0)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
            }
            SettingsGroup(title: "On each photo") {
                SettingRow(title: "Frame number and filename", detail: "The film-edge label under each photo.") { Toggle("", isOn: $themes.showFilenames).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Faces of the people in it") { Toggle("", isOn: $themes.showFaceBadges).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Quality badges", detail: "★ Best, Burst 2/4, Eyes, Soft.") { Toggle("", isOn: $themes.showQualityBadges).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Hover effects", detail: "Lift, glow and quick actions when the pointer is over a photo or face.") { Toggle("", isOn: $themes.hoverEffects).labelsHidden().toggleStyle(.switch) }
            }
            SettingsGroup(title: "Full photo view") {
                SettingRow(title: "Colour glow", detail: "The background softly takes on the colours of the photo.") { Toggle("", isOn: $viewerGlow).labelsHidden().toggleStyle(.switch) }
            }
            SettingsGroup(title: "Find results") {
                SettingRow(title: "Stack bursts behind the best frame", detail: "Off shows every frame.") { Toggle("", isOn: $model.stackBursts).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Separate shots to check", detail: "Eyes may be closed or soft focus go in their own section, out of the export until ticked.") { Toggle("", isOn: $model.separateWeaker).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Include uncertain matches by default") { Toggle("", isOn: $defaultUncertain).labelsHidden().toggleStyle(.switch) }
            }
            SettingsGroup(title: "Sidebar") {
                SettingRow(title: "People shown in the sidebar", detail: "0 hides the section.") {
                    Stepper("\(themes.sidebarPeople)", value: $themes.sidebarPeople, in: 0...50, step: 5).fixedSize()
                }
            }
        }
    }
}

// MARK: - Library & Storage

private struct LibraryPage: View {
    @Environment(AppModel.self) private var model
    @State private var keepPreviews = AppSettings.keepPreviews
    @State private var cardPrompt = AppSettings.cardPrompt
    @State private var previewBytes: Int64 = 0
    @State private var cropBytes: Int64 = 0
    @State private var askDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Photo previews",
                          footnote: "Previews are small copies (at most 640 px) kept only on this Mac, inside Pixora’s library. Your originals are never changed either way.") {
                SettingRow(title: "Keep small preview copies",
                           detail: keepPreviews ? "On: browse, search and plan exports even with the card ejected." : "Off: nothing is copied. Photos appear only while their card or drive is connected.") {
                    Toggle("", isOn: $keepPreviews).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(title: "Stored previews", detail: Format.size(previewBytes)) {
                    Button("Delete Previews…", role: .destructive) { askDelete = true }.disabled(previewBytes == 0)
                }
                SettingRow(title: "Sharp face crops for covers", detail: "\(Format.size(cropBytes)) · re-made from originals when the card is connected") {
                    Button("Delete") { StorageInfo.deleteFaceCrops(); ImageCache.shared.invalidateFaces(); measure() }.disabled(cropBytes == 0)
                }
            }
            SettingsGroup(title: "Cards") {
                SettingRow(title: "Offer to scan when a card is inserted", detail: "Shows a banner with the number of new photos.") {
                    Toggle("", isOn: $cardPrompt).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "Library location") {
                SettingRow(title: AppPaths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                           detail: "People database \(Format.size(model.stats.databaseBytes)) · names, face templates and small face crops") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database]) }
                }
            }
        }
        .onAppear(perform: measure)
        .onChange(of: keepPreviews) { _, on in
            AppSettings.keepPreviews = on
            if !on && previewBytes > 0 { askDelete = true }
        }
        .onChange(of: cardPrompt) { _, on in AppSettings.cardPrompt = on }
        .confirmationDialog("Delete the \(Format.size(previewBytes)) of stored previews?", isPresented: $askDelete) {
            Button("Delete Previews", role: .destructive) { StorageInfo.deletePreviews(); measure(); model.refreshAll() }
            Button("Keep Them", role: .cancel) {}
        } message: {
            Text("People, names and faces stay. Photos on cards that aren’t connected will show as placeholders until you plug them in again.")
        }
    }

    private func measure() {
        Task.detached(priority: .utility) {
            let p = StorageInfo.size(of: AppPaths.thumbnails), c = StorageInfo.size(of: AppPaths.faceCrops)
            await MainActor.run { previewBytes = p; cropBytes = c }
        }
    }
}

// MARK: - Scanning & Recognition

private struct ScanningPage: View {
    @State private var detail = AppSettings.analysisLongEdge
    @State private var tiles = AppSettings.tiledDetection
    @State private var workers = AppSettings.scanWorkers
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Scanning", footnote: "Changes apply to the next scan. Photos already scanned aren’t re-analysed unless you scan them again.") {
                SettingRow(title: "Detail", detail: "Detailed finds more tiny faces in very large group photos, and takes longer.") {
                    Picker("", selection: $detail) { Text("Fast").tag(2400); Text("Standard").tag(3200); Text("Detailed").tag(4800) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                SettingRow(title: "Look for small faces in tiles", detail: "Scans each large photo whole and in four overlapping parts.") {
                    Toggle("", isOn: $tiles).labelsHidden().toggleStyle(.switch)
                }
                SettingRow(title: "Photos analysed at once", detail: "Higher is faster on a cool Mac; lower keeps it quieter.") {
                    Stepper("\(workers)", value: $workers, in: 1...6).fixedSize()
                }
            }
            RecognitionSettings().frame(minHeight: 420)
        }
        .onChange(of: detail) { _, v in AppSettings.analysisLongEdge = v }
        .onChange(of: tiles) { _, v in AppSettings.tiledDetection = v }
        .onChange(of: workers) { _, v in AppSettings.scanWorkers = v }
    }
}

// MARK: - Export defaults

private struct ExportDefaultsPage: View {
    @AppStorage("exportPreset") private var presetRaw = ExportOptions.Preset.originals.rawValue
    @AppStorage("exportOrganization") private var organizationRaw = ExportOptions.Organization.flat.rawValue
    @AppStorage("exportLongEdge") private var longEdge = 2048
    @AppStorage("exportVerify") private var verify = true
    @AppStorage("exportNames") private var writeNames = true
    @AppStorage("exportZip") private var zip = false
    var body: some View {
        SettingsGroup(title: "Defaults for Copy to Folder", footnote: "You can still change these each time you export.") {
            SettingRow(title: "Files") {
                Picker("", selection: $presetRaw) {
                    Text("Originals").tag(ExportOptions.Preset.originals.rawValue)
                    Text("Originals + RAW").tag(ExportOptions.Preset.originalsWithRAW.rawValue)
                    Text("JPEG only").tag(ExportOptions.Preset.jpegOnly.rawValue)
                    Text("Resized for sharing").tag(ExportOptions.Preset.resizedForSharing.rawValue)
                }.labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Resized long edge") {
                Picker("", selection: $longEdge) { ForEach([1280, 2048, 3072, 4096], id: \.self) { Text("\($0) px").tag($0) } }.labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Folders") {
                Picker("", selection: $organizationRaw) {
                    Text("None").tag(ExportOptions.Organization.flat.rawValue)
                    Text("By person").tag(ExportOptions.Organization.byPerson.rawValue)
                    Text("By date").tag(ExportOptions.Organization.byDate.rawValue)
                    Text("By event").tag(ExportOptions.Organization.byEvent.rawValue)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
            }
            SettingRow(title: "Verify every copy", detail: "Re-reads each file and compares checksums.") { Toggle("", isOn: $verify).labelsHidden().toggleStyle(.switch) }
            SettingRow(title: "Write people’s names into copies", detail: "Lightroom, Photos and Google Photos can read them. Originals are never changed.") { Toggle("", isOn: $writeNames).labelsHidden().toggleStyle(.switch) }
            SettingRow(title: "Make a .zip of each folder") { Toggle("", isOn: $zip).labelsHidden().toggleStyle(.switch) }
        }
    }
}

// MARK: - Shortcuts & About

private struct ShortcutsPage: View {
    private let rows: [(String, String)] = [
        ("⌘K", "Command bar — type “me + asha october solo”"), ("⌘1 … ⌘6", "Find, Review, People, All Photos, Insights, Cards & Folders"), ("⌘7", "Places"), ("⌘8", "Search"),
        ("⌘,", "Settings"), ("⌘O", "Choose a folder to scan"), ("⌘E", "Copy results to a folder"), ("⇧⌘S", "Select mode"),
        ("⌘Z / ⇧⌘Z", "Undo / redo a correction"), ("⌘+ / ⌘−", "Bigger / smaller photos"), ("⌥⌘I", "Show / hide the details panel"),
        ("Space", "View the selected photo large · close the viewer"), ("← →", "Previous / next photo in the viewer"),
        ("F / I", "Viewer: face boxes / info"), ("Y / N / →", "Review: yes / no / skip"), ("Esc", "Close · leave Select mode"),
    ]
    var body: some View {
        SettingsGroup(title: "Shortcuts") {
            ForEach(rows, id: \.0) { k, v in
                HStack {
                    Text(k).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Palette.rule.opacity(0.6)))
                        .frame(width: 130, alignment: .leading)
                    Text(v).font(.system(size: 13))
                    Spacer()
                }
            }
        }
    }
}

private struct AboutPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pixora").font(Typography.display(30))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · everything runs on this Mac").font(.callout).foregroundStyle(Palette.ink2)
                }
            }
            HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Palette.safelight)
                    .frame(width: 44, height: 44).background(Circle().fill(Palette.safelight.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Made by \(Credits.author)").font(Typography.display(20))
                    Link(Credits.email, destination: URL(string: "mailto:\(Credits.email)")!)
                        .font(.callout).help("Questions, ideas or bug reports")
                }
                Spacer()
                Link(destination: URL(string: "mailto:\(Credits.email)?subject=Pixora")!) { Label("Contact", systemImage: "envelope") }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.rule))
            .accessibilityElement(children: .contain)
            SettingsGroup(title: "License", footnote: "Pixora’s own code is MIT-licensed. The bundled face models are InsightFace’s, released for non-commercial research use only — so Pixora as distributed is for personal, non-commercial use.") {
                SettingRow(title: "Pixora", detail: "MIT License · © 2026 \(Credits.author)") { EmptyView() }
                SettingRow(title: "SCRFD and ArcFace models", detail: "InsightFace (buffalo_l) · non-commercial research use") { EmptyView() }
            }
            SettingsGroup(title: "Models", footnote: "InsightFace code is MIT; its pretrained buffalo_l models are released for non-commercial research use — fine for personal use.") {
                SettingRow(title: "Face detection", detail: Detectors.makeDefault().name) { EmptyView() }
                SettingRow(title: "Face recognition", detail: model.embedder.displayName) { EmptyView() }
            }
        }
    }
}

// MARK: - Private Space

private struct PrivateSpacePage: View {
    @Environment(AppModel.self) private var model
    @State private var showChange = false
    @State private var showDelete = false
    @AppStorage("lockOnLeave") private var lockOnLeave = true
    @AppStorage("privateIdleMinutes") private var idleMinutes = 5

    var body: some View {
        let _ = model.vaultEpoch
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Private Space",
                          footnote: "No account and no internet needed — Private Space works entirely on this Mac.") {
                SettingRow(title: status, detail: detail) {
                    if model.isPrivateUnlocked { Button("Lock Now") { model.lockPrivateSpace() } }
                    Button(model.vault.isSetUp ? "Open" : "Set Up…") { model.section = .privateSpace }
                }
                SettingRow(title: "Lock when leaving Private Space") { Toggle("", isOn: $lockOnLeave).labelsHidden().toggleStyle(.switch) }
                SettingRow(title: "Lock after inactivity", detail: "Private Space always locks when the Mac sleeps or the screen locks.") {
                    Picker("", selection: $idleMinutes) {
                        Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("Never").tag(0)
                    }.labelsHidden().frame(width: 140)
                }
            }

            if model.vault.isSetUp {
                SettingsGroup(title: "Password", footnote: "Your Private Space password is separate from your Mac, Apple Account or any other password. Pixora never stores it.") {
                    SettingRow(title: "Change password", detail: "You’ll need the current one. Works offline.") {
                        Button("Change Password…") { showChange = true }
                    }
                    SettingRow(title: "Forgot the password?", detail: "It can’t be recovered. You can delete Private Space and create a new one — your original photos on cards and drives aren’t touched.") {
                        Button("Delete Private Space…", role: .destructive) { showDelete = true }
                    }
                }
            }

            SettingsGroup(title: "How Private Space is protected") {
                Text("""
                • Each private photo’s preview, face crops, face templates and details are encrypted together (X25519 + AES-256-GCM) into one file, and removed from the regular library and its caches.
                • The key that opens them is stored only wrapped by your password (PBKDF2-HMAC-SHA256, 600,000 rounds) in the macOS Keychain on this Mac. The password itself is never stored — not in the library, logs or settings.
                • The only copy of your password is a file you choose to save yourself during setup or after changing it.
                • While locked, Pixora can still add new private photos (it encrypts them to a public key) but can’t read any.
                • Your original files are never changed, moved or encrypted — a photo you make private stays on its card or drive.
                """).font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showChange) { ChangePasswordSheet() }
        .sheet(isPresented: $showDelete) { DeletePrivateSpaceSheet() }
    }

    private var status: String {
        guard model.vault.isSetUp else { return "Not set up" }
        return model.isPrivateUnlocked ? "Unlocked" : "Locked"
    }

    private var detail: String {
        guard model.vault.isSetUp else { return "Create a password just for Private Space to start hiding photos." }
        var parts = ["Encrypted on this Mac"]
        if let d = model.vault.createdAt { parts.append("created \(d.formatted(date: .abbreviated, time: .omitted))") }
        if let d = model.vault.passwordChangedAt { parts.append("password changed \(d.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ") + "."
    }
}
