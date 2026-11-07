import SwiftUI
import PixoraCore

/// ⌘K: type what you want — "me + asha october solo best copy to desktop".
struct CommandBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: ParsedCommand { CommandParser.parse(text, people: model.commandPeople) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.safelight)
                TextField("me + asha, october, solo, best, copy to desktop", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .serif))
                    .focused($focused)
                    .onSubmit(run)
                Text("esc").font(Typography.edge).padding(4).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.rule))
            }
            if !text.isEmpty {
                FlowChips(understood: parsed.understood, unknown: searchesPhotos ? [] : parsed.unknown)
                Text(summary).font(.callout).foregroundStyle(Palette.ink2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(examples, id: \.self) { ex in
                        Button { text = ex } label: {
                            HStack { Image(systemName: "arrow.turn.down.right").foregroundStyle(Palette.ink2); Text(ex); Spacer() }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverLift(scale: 1.01, radius: 6, cursor: true)
                    }
                    if model.mePersonID == nil {
                        Text("Tip: open yourself in People and choose “This Is Me” to use “me”.").font(.caption).foregroundStyle(Palette.ink2)
                    }
                }.font(.system(size: 13))
            }
        }
        .padding(18)
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.rule))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .onAppear { focused = true }
        .onExitCommand { model.showCommandBar = false }
    }

    private var examples: [String] {
        let names = model.namedPeople.prefix(2).map { $0.displayName.lowercased() }
        let a = model.mePersonID != nil ? "me" : (names.first ?? "ana")
        let b = names.count > 1 ? names[1] : "ben"
        return ["\(a) + \(b) together", "\(a) solo best", "\(b) last month copy to desktop", "\(a) \(b) contact sheet"]
    }

    private var summary: String {
        let p = parsed
        if searchesPhotos { return "Press Return to search your photos for “\(searchWords)”." }
        if p.people.isEmpty { return "Type a name you’ve given someone in People." }
        var s = "Press Return to show these photos"
        switch p.action {
        case .export: s += ", then open Copy to Folder"
        case .share: s += ", then open Share"
        case .contactSheet: s += ", then make a contact sheet"
        case .none: break
        }
        return s + "."
    }

    /// Words that aren't a name, date or action describe what's in the photo, once the search model is here.
    private var searchesPhotos: Bool { model.sight.isReady && !parsed.unknown.isEmpty && parsed.action == .none }
    private var searchWords: String { text.trimmingCharacters(in: .whitespaces) }

    private func run() {
        let p = parsed
        if searchesPhotos {
            model.showCommandBar = false
            model.searchText = searchWords
            model.section = .search
            return
        }
        guard !p.people.isEmpty else { return }
        model.showCommandBar = false
        model.apply(p)
    }
}

private struct FlowChips: View {
    let understood: [String]
    let unknown: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(understood, id: \.self) { u in
                Text(u).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Palette.safelight.opacity(0.18))).foregroundStyle(Palette.ink)
            }
            ForEach(unknown, id: \.self) { u in
                Text("“\(u)”?").font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))).foregroundStyle(Palette.ink2)
                    .help("Not understood — ignored")
            }
        }
    }
}
