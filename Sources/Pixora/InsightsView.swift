import SwiftUI
import PixoraCore

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    enum Tab: Hashable { case together, coverage }
    @State private var tab: Tab = .together
    @State private var range: DateRangeChoice = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Insights", subtitle: tab == .together
                    ? "Who appears with whom. Thicker lines mean more photos together — click a line to see them."
                    : "How well you covered each person. Catch anyone you under-shot.")
                Picker("", selection: $range) {
                    ForEach(DateRangeChoice.allCases) { Text($0.label).tag($0) }
                }.frame(width: 160)
            }
            .padding(.horizontal, 24).padding(.top, 18)
            Picker("", selection: $tab) {
                Text("Together map").tag(Tab.together)
                Text("Coverage").tag(Tab.coverage)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 12)
            Divider().overlay(Palette.rule)
            switch tab {
            case .together: TogetherMap(range: range)
            case .coverage: CoverageView(range: range)
            }
        }
        .background(Palette.canvas)
    }
}

enum DateRangeChoice: String, CaseIterable, Identifiable {
    case all, lastImport, month, year
    var id: String { rawValue }
    var label: String { ["all": "All time", "lastImport": "Latest import day", "month": "Last 30 days", "year": "Last 12 months"][rawValue]! }
    @MainActor func interval(_ model: AppModel) -> (Date?, Date?) {
        switch self {
        case .all: return (nil, nil)
        case .month: return (Date().addingTimeInterval(-30 * 86400), nil)
        case .year: return (Date().addingTimeInterval(-365 * 86400), nil)
        case .lastImport:
            // The capture day of the most recent photos in the library.
            let last = try? model.store.db.read { try $0.query("SELECT MAX(taken_at) FROM photos WHERE scan_state = 1") { $0.optDouble(0) }.first ?? nil }
            guard let t = last else { return (nil, nil) }
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t))
            return (day, day.addingTimeInterval(86400))
        }
    }
}

/// Force-directed graph of named people; edges weighted by shared photos.
private struct TogetherMap: View {
    @Environment(AppModel.self) private var model
    let range: DateRangeChoice
    @State private var edges: [TogetherEdge] = []
    @State private var positions: [Int64: CGPoint] = [:]
    @State private var hoveredNode: Int64?
    @State private var hoveredEdge: TogetherEdge?
    @State private var dragging: Int64?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if edges.isEmpty {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No pairs yet",
                               message: "Once two named people appear in the same photo, they’re connected here.")
                }
                Canvas { ctx, _ in
                    let maxW = Double(edges.map(\.photos).max() ?? 1)
                    for e in edges {
                        guard let a = point(e.a, size), let b = point(e.b, size) else { continue }
                        let lit = hoveredEdge == e || hoveredNode == e.a || hoveredNode == e.b
                        let dim = (hoveredNode != nil || hoveredEdge != nil) && !lit
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        ctx.stroke(path, with: .color(lit ? Palette.safelight : Palette.ink2.opacity(dim ? 0.12 : 0.45)),
                                   style: StrokeStyle(lineWidth: 1.5 + 9 * Double(e.photos) / maxW, lineCap: .round))
                    }
                }
                // Edge hit targets + counts
                ForEach(edges, id: \.self) { e in
                    if let a = point(e.a, size), let b = point(e.b, size) {
                        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        Text("\(e.photos)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(hoveredEdge == e ? Palette.safelight : Palette.card))
                            .foregroundStyle(hoveredEdge == e ? Palette.onSafelight : Palette.ink)
                            .overlay(Capsule().strokeBorder(Palette.rule))
                            .scaleEffect(hoveredEdge == e ? 1.2 : 1)
                            .animation(.spring(response: 0.25), value: hoveredEdge)
                            .position(mid)
                            .onHover { hoveredEdge = $0 ? e : nil }
                            .onTapGesture { open(e) }
                            .help("\(name(e.a)) & \(name(e.b)): \(e.photos) photos together — click to see them")
                    }
                }
                ForEach(model.namedPeople) { p in
                    if let pt = point(p.id, size) {
                        let lit = hoveredNode == p.id || hoveredEdge?.a == p.id || hoveredEdge?.b == p.id
                        VStack(spacing: 4) {
                            FaceImage(faceID: p.coverFaceID, size: lit ? 64 : 54, shape: AnyShape(Circle()))
                                .overlay(Circle().strokeBorder(lit ? Palette.safelight : Palette.card, lineWidth: 3))
                                .shadow(color: lit ? Palette.safelight.opacity(0.6) : .black.opacity(0.3), radius: lit ? 12 : 4)
                            Text(p.displayName).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Palette.canvas.opacity(0.85)))
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lit)
                        .position(pt)
                        .onHover { hoveredNode = $0 ? p.id : nil }
                        .gesture(DragGesture().onChanged { v in
                            positions[p.id] = CGPoint(x: min(max(v.location.x / size.width, 0.05), 0.95), y: min(max(v.location.y / size.height, 0.06), 0.94))
                        })
                        .onTapGesture { model.selectedPeople = [p.id]; model.section = .find }
                        .help("\(p.displayName) — drag to move, click to see their photos")
                    }
                }
            }
        }
        .padding(24)
        .task(id: "\(range)-\(model.people.count)-\(model.stats.faces)") { load() }
    }

    private func name(_ id: Int64) -> String { model.person(id)?.displayName ?? "?" }
    private func point(_ id: Int64, _ size: CGSize) -> CGPoint? {
        positions[id].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }
    private func open(_ e: TogetherEdge) {
        model.selectedPeople = [e.a, e.b]; model.matchMode = .all; model.section = .find
    }

    private func load() {
        let (from, to) = range.interval(model)
        edges = (try? model.store.togetherEdges(from: from, to: to)) ?? []
        positions = Self.layout(people: model.namedPeople.map(\.id), edges: edges)
    }

    /// A small deterministic force layout in unit space: connected people attract, everyone repels.
    static func layout(people: [Int64], edges: [TogetherEdge]) -> [Int64: CGPoint] {
        guard !people.isEmpty else { return [:] }
        var pos: [Int64: CGPoint] = [:]
        for (i, id) in people.enumerated() {
            let a = Double(i) / Double(people.count) * 2 * .pi
            pos[id] = CGPoint(x: 0.5 + 0.35 * cos(a), y: 0.5 + 0.35 * sin(a))
        }
        let maxW = Double(edges.map(\.photos).max() ?? 1)
        for _ in 0..<300 {
            var force: [Int64: CGVector] = Dictionary(uniqueKeysWithValues: people.map { ($0, CGVector.zero) })
            for i in people.indices { for j in people.indices where j > i {
                let a = people[i], b = people[j]
                var dx = pos[a]!.x - pos[b]!.x, dy = pos[a]!.y - pos[b]!.y
                if dx == 0 && dy == 0 { dx = 0.01; dy = 0.01 }
                let d2 = max(dx * dx + dy * dy, 0.0025)
                let f = 0.0016 / d2
                force[a]!.dx += dx * f; force[a]!.dy += dy * f
                force[b]!.dx -= dx * f; force[b]!.dy -= dy * f
            } }
            for e in edges {
                guard let pa = pos[e.a], let pb = pos[e.b] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let k = 0.02 * (0.3 + Double(e.photos) / maxW)
                force[e.a]!.dx += dx * k; force[e.a]!.dy += dy * k
                force[e.b]!.dx -= dx * k; force[e.b]!.dy -= dy * k
            }
            for id in people {
                var p = pos[id]!
                p.x += max(-0.02, min(0.02, force[id]!.dx + (0.5 - p.x) * 0.005))
                p.y += max(-0.02, min(0.02, force[id]!.dy + (0.5 - p.y) * 0.005))
                pos[id] = CGPoint(x: min(max(p.x, 0.07), 0.93), y: min(max(p.y, 0.08), 0.92))
            }
        }
        return pos
    }
}

private struct CoverageView: View {
    @Environment(AppModel.self) private var model
    let range: DateRangeChoice
    @State private var rows: [CoverageRow] = []

    var body: some View {
        let maxPhotos = max(rows.map(\.photos).max() ?? 1, 1)
        let median = rows.isEmpty ? 0 : rows.map(\.photos).sorted()[rows.count / 2]
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let low = rows.filter { Double($0.photos) < Double(median) * 0.25 }
                if !low.isEmpty {
                    Notice(symbol: "exclamationmark.triangle",
                           text: "Under-covered: \(low.compactMap { model.person($0.personID)?.displayName }.joined(separator: ", ")) — fewer than a quarter of the typical \(median) photos.")
                }
                if rows.isEmpty {
                    EmptyState(symbol: "chart.bar.xaxis", title: "Nothing to show", message: "Name people in Review to see how well each one is covered.")
                }
                ForEach(rows) { r in
                    if let p = model.person(r.personID) {
                        HStack(spacing: 12) {
                            FaceImage(faceID: p.coverFaceID, size: 40, shape: AnyShape(Circle()))
                            Text(p.displayName).font(.system(size: 14, weight: .semibold)).frame(width: 150, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.rule.opacity(0.5))
                                    Capsule().fill(Double(r.photos) < Double(median) * 0.25 ? Palette.safelight : Palette.ink2.opacity(0.7))
                                        .frame(width: max(6, g.size.width * CGFloat(r.photos) / CGFloat(maxPhotos)))
                                    Capsule().fill(Palette.confirmed)
                                        .frame(width: max(0, g.size.width * CGFloat(r.solo) / CGFloat(maxPhotos)))
                                }
                            }.frame(height: 12)
                            Text("\(r.photos)").font(Typography.edgeLarge).frame(width: 44, alignment: .trailing)
                            Text("\(r.solo) solo").font(.caption).foregroundStyle(Palette.confirmed).frame(width: 56, alignment: .trailing)
                            if r.uncertain > 0 { Text("\(r.uncertain) to review").font(.caption).foregroundStyle(Palette.safelight).frame(width: 80, alignment: .trailing) }
                            else { Spacer().frame(width: 80) }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                        .hoverLift(scale: 1.01, radius: 10, glow: true)
                        .onTapGesture { model.selectedPeople = [p.id]; model.section = .find }
                        .help("Click to see \(p.displayName)’s photos")
                    }
                }
                HStack(spacing: 14) {
                    Label("All photos", systemImage: "circle.fill").foregroundStyle(Palette.ink2)
                    Label("Solo", systemImage: "circle.fill").foregroundStyle(Palette.confirmed)
                    Label("Under-covered", systemImage: "circle.fill").foregroundStyle(Palette.safelight)
                }.font(.caption).padding(.top, 6)
            }.padding(24)
        }
        .task(id: "\(range)-\(model.people.count)-\(model.stats.faces)") {
            let (from, to) = range.interval(model)
            rows = (try? model.store.coverage(from: from, to: to)) ?? []
        }
    }
}
