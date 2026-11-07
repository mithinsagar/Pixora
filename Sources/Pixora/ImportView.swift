import SwiftUI
import PixoraCore

struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    SectionHeader(title: "Cards & Folders", subtitle: "Pixora reads your photos where they are. It never moves, renames or deletes originals.")
                    Button { model.chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut("o", modifiers: .command)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Connected cards & drives").font(.headline)
                    if model.volumes.isEmpty {
                        Text("Insert an SD card or connect a drive — it will appear here automatically.").font(.callout).foregroundStyle(Palette.ink2)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                            ForEach(model.volumes) { v in volumeCard(v) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("In your library").font(.headline)
                    if model.sources.isEmpty {
                        Text("Nothing scanned yet.").font(.callout).foregroundStyle(Palette.ink2)
                    }
                    ForEach(model.sources) { s in sourceRow(s) }
                }

                if !model.imports.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import history").font(.headline)
                        ForEach(model.imports.prefix(15)) { i in
                            HStack {
                                EdgeLabel(Format.dateTime.string(from: i.startedAt))
                                Text(i.sourceName).font(.callout)
                                Spacer()
                                Text("\(i.filesNew) new · \(i.filesSkipped) unchanged · \(i.facesFound) faces\(i.errors > 0 ? " · " + Format.count(i.errors, "error") : "")")
                                    .font(.caption).foregroundStyle(Palette.ink2)
                                EdgeLabel(i.status, color: i.status == "complete" ? Palette.confirmed : Palette.safelight)
                                Button { model.recap(importRecord: i) } label: { Label("Recap", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                                    .controlSize(.small).help("Make a shareable recap card for this shoot")
                            }
                            Divider().overlay(Palette.rule)
                        }
                    }
                }
            }.padding(24)
        }
        .background(Palette.canvas)
    }

    private func volumeCard(_ v: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: v.looksLikeCameraCard ? "sdcard.fill" : "externaldrive.fill").font(.title2).foregroundStyle(Palette.safelight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.name ?? v.url.lastPathComponent).font(.system(size: 14, weight: .semibold))
                    EdgeLabel([v.looksLikeCameraCard ? "camera card" : nil, v.format].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer()
            }
            if let total = v.totalBytes, total > 0, let free = v.availableBytes {
                ProgressView(value: Double(total - free), total: Double(total)).tint(Palette.ink2)
                EdgeLabel("\(Format.size(free)) free of \(Format.size(total))")
            }
            Button(v.looksLikeCameraCard ? "Preview DCIM…" : "Preview…") { model.scanVolume(v) }
        }
        .padding(14).cardBackground()
        .accessibilityElement(children: .contain)
    }

    private func sourceRow(_ s: Source) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.isRemovable ? "sdcard" : "folder").foregroundStyle(Palette.ink2).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.name).font(.system(size: 13, weight: .medium))
                    Circle().fill(s.isOnline ? Palette.confirmed : Palette.ink2.opacity(0.5)).frame(width: 7, height: 7)
                    Text(s.isOnline ? "Connected" : "Offline").font(.caption).foregroundStyle(Palette.ink2)
                }
                EdgeLabel(s.path)
            }
            Spacer()
            if let d = s.lastScanAt { Text("Scanned \(Format.day.string(from: d))").font(.caption).foregroundStyle(Palette.ink2) }
            if s.isOnline { Button("Scan Again") { model.rescan(s) }.help("Only new or changed files are analysed") }
            else { Button("Locate…") { model.locate(s) }.help("Point Pixora at the folder’s new location") }
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }.disabled(!s.isOnline)
                Divider()
                Button("Remove from Library…", role: .destructive) { confirmRemove(s) }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12).cardBackground(radius: 10)
    }

    private func confirmRemove(_ s: Source) {
        let a = NSAlert()
        a.messageText = "Remove “\(s.name)” from the library?"
        a.informativeText = "Pixora forgets these photos and the faces found in them. The files on disk are not touched. Named people stay."
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { model.remove(s) }
    }
}

// MARK: - Scan sheet

struct ScanSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: ScanSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: session.source.isRemovable ? "sdcard.fill" : "folder.fill").foregroundStyle(Palette.safelight).font(.title2)
                VStack(alignment: .leading) {
                    Text(session.source.name).font(Typography.display(22))
                    EdgeLabel(session.source.path)
                }
                Spacer()
                processingBadge
            }
            switch session.stage {
            case .previewing:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking through folders…").foregroundStyle(Palette.ink2) }
                    .frame(maxWidth: .infinity, minHeight: 240)
                HStack { Spacer(); Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction) }
            case .ready: previewBody
            case .scanning: progressBody
            case .done: summaryBody
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(Palette.panel)
    }

    private var processingBadge: some View {
        Label(model.isBasicMode ? "Local · Basic" : "Local · on this Mac", systemImage: "lock.laptopcomputer")
            .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Palette.confirmed.opacity(0.15))).foregroundStyle(Palette.confirmed)
            .help("Faces are detected and recognised on this Mac. Nothing is uploaded.")
    }

    @ViewBuilder private var previewBody: some View {
        if let p = session.preview {
            let selected = session.selectedFiles
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                stat("\(p.files.count)", "photos")
                stat(Format.size(p.totalBytes), "on disk")
                if p.rawPairs > 0 { stat("\(p.rawPairs)", "RAW+JPEG pairs") }
                if let free = VolumeInfo(for: session.source.url).availableBytes { stat(Format.size(free), "free on volume") }
            }
            HStack(spacing: 6) {
                ForEach(p.formats.sorted { $0.value > $1.value }, id: \.key) { k, v in
                    Text("\(k) \(v)").font(Typography.edge).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().strokeBorder(Palette.rule))
                }
            }
            if p.rawPairs > 0 {
                Text("RAW+JPEG pairs are treated as one photo: the JPEG is analysed (faster) and the RAW can be included when you export.")
                    .font(.caption).foregroundStyle(Palette.ink2)
            }
            Text("Folders").font(.headline)
            List {
                ForEach(p.folders) { f in
                    Toggle(isOn: Binding(get: { !session.excludedFolders.contains(f.path) },
                                         set: { on in if on { session.excludedFolders.remove(f.path) } else { session.excludedFolders.insert(f.path) } })) {
                        HStack {
                            Text(f.path.isEmpty ? "(top level)" : f.path).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text("\(f.photos) · \(Format.size(f.bytes))").font(.caption).foregroundStyle(Palette.ink2)
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 200).scrollContentBackground(.hidden).background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                if session.alreadyScanned > 0 { note("checkmark.circle", "\(session.alreadyScanned) unchanged photos are already in the library and will be skipped.") }
                if !p.unsupported.isEmpty { note("exclamationmark.triangle", "\(p.unsupported.count) image files can’t be decoded by macOS on this Mac and will be skipped: \(p.unsupported.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))\(p.unsupported.count > 3 ? "…" : "")") }
                if p.videosSkipped > 0 { note("video.slash", "\(p.videosSkipped) videos skipped (photos only).") }
                if !p.unreadable.isEmpty { note("lock", "\(p.unreadable.count) items couldn’t be read (permissions).") }
            }
            scanKind(photos: selected.count)
            HStack {
                Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Scan \(Format.count(selected.count, "Photo"))") { session.start() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }
    }

    /// General is today's face scan. Deep also learns what's in each photo, which takes longer, so it's a choice each time.
    private func scanKind(photos: Int) -> some View {
        let sight = model.sight
        let extra = sight.estimate(photos: max(0, photos - session.alreadyScanned) + sight.pending)
        let detail = sight.isReady ? "Also makes photos searchable, like “cat” or “sunset”. Adds about \(Format.duration(extra)) in the background, and the card can come out once faces are done."
            : "Also makes photos searchable, like “cat” or “sunset”. Needs a one-time \(Format.size(Sight.downloadBytes)) download, then about \(Format.duration(extra)) in the background."
        return HStack(alignment: .top, spacing: 10) {
            scanKindCard("General Scan", "person.2", "Finds and groups faces.", selected: !session.deep) { session.deep = false }
            scanKindCard("Deep Scan", "sparkle.magnifyingglass", detail, selected: session.deep) { session.deep = true }
        }
    }

    private func scanKindCard(_ title: String, _ icon: String, _ detail: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(Palette.ink2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.safelight.opacity(0.14) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Palette.safelight : Palette.rule, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var progressBody: some View {
        let pr = session.progress
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.phase == .grouping ? "Grouping faces…" : session.isPaused ? "Paused" : "Scanning \(min(pr.processed + 1, pr.total)) of \(pr.total)")
                    .font(Typography.display(20))
                Spacer()
                if let s = pr.secondsRemaining, !session.isPaused, pr.phase == .scanning { EdgeLabel("about \(Format.duration(s)) left") }
            }
            if pr.phase == .grouping { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: pr.fraction).tint(Palette.safelight) }
            HStack(spacing: 28) {
                stat("\(pr.facesFound)", "faces found")
                stat("\(pr.newPhotos)", "analysed")
                stat("\(pr.skippedUnchanged)", "unchanged")
                stat("\(pr.errors.count)", "problems")
            }
            // The developing tray: faces appear like prints coming up in the developer.
            DevelopingTray(thumbs: pr.recentFaceThumbs, serial: pr.thumbSerial, facesFound: pr.facesFound)
            EdgeLabel(pr.currentFile)
            Text("Each photo is decoded at reduced size, faces are located (whole photo plus tiles, so small faces in group shots are found), aligned, and turned into a face template on this Mac (\(model.embedder.displayName)). Originals are only read. You can pause, or cancel and keep what’s done — scanning again resumes where it left off.")
                .font(.caption).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { session.cancel() }.disabled(pr.phase == .grouping)
                Spacer()
                Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                    .keyboardShortcut(.space, modifiers: []).disabled(pr.phase == .grouping)
            }
        }
    }

    @ViewBuilder private var summaryBody: some View {
        let pr = session.progress
        VStack(alignment: .leading, spacing: 14) {
            Text(pr.phase == .cancelled ? "Scan cancelled — progress kept" : "Scan complete").font(Typography.display(20))
            HStack(spacing: 28) {
                stat("\(pr.newPhotos)", "photos analysed")
                stat("\(pr.facesFound)", "faces found")
                stat("\(pr.skippedUnchanged)", "unchanged, skipped")
                stat("\(model.unnamedGroups.count)", "groups to name")
            }
            if !pr.errors.isEmpty {
                DisclosureGroup("\(pr.errors.count) files had problems") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(pr.errors.enumerated()), id: \.offset) { _, e in
                                Text("\(e.file) — \(e.message)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }
            }
            HStack {
                Button("Close") { model.scan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review People") { model.scan = nil; model.section = .review }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .serif)).monospacedDigit()
            EdgeLabel(label)
        }.accessibilityElement(children: .combine)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(Palette.ink2)
    }
}

/// A darkroom tray under a safelight. Each new face develops from a dark, flat, colourless print to full colour.
struct DevelopingTray: View {
    let thumbs: [Data]
    let serial: Int
    let facesFound: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Palette.safelight).frame(width: 7, height: 7).shadow(color: Palette.safelight, radius: 4)
                EdgeLabel(facesFound == 0 ? "Developing… waiting for the first faces" : "Developing · \(facesFound) faces", color: Palette.safelight)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 7), count: 12), spacing: 7) {
                // Newest first; id = serial − index stays the same for a face as more arrive.
                ForEach(Array(thumbs.prefix(24).enumerated()).map { (key: serial - $0.offset, data: $0.element) }, id: \.key) { item in
                    DevelopingPrint(data: item.data)
                }
            }
            .frame(height: 100, alignment: .top)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.06, blue: 0.03), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.safelight.opacity(0.25)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(facesFound) faces found so far")
    }
}

private struct DevelopingPrint: View {
    let data: Data
    @State private var developed = false
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: 46, height: 46)
        .saturation(developed ? 1 : 0)
        .brightness(developed ? 0 : -0.55)
        .contrast(developed ? 1 : 0.5)
        .overlay(Rectangle().fill(Palette.safelight.opacity(developed ? 0 : 0.35)).blendMode(BlendMode.multiply))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(developed ? 0.12 : 0)))
        .onAppear {
            image = NSImage(data: data)
            if reduceMotion { developed = true } else { withAnimation(.easeOut(duration: 1.4)) { developed = true } }
        }
    }
}
