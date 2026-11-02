import SwiftUI
import AppKit
import PixoraCore

// MARK: - Hover

/// Lift on hover: a gentle scale, a soft shadow and an optional safelight glow. Calm with Reduce Motion
/// (no scaling; the shadow and glow still show so the hover is visible).
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.035
    var radius: CGFloat = 12
    var glow = false
    var cursor = true
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = ThemeManager.shared.hoverEffects && hovering   // Settings → Photos & Grid → Hover effects
        content
            // Shadow and glow are drawn on plain shapes behind/over the content. A shadow applied to the content
            // itself makes every tile re-render offscreen on each frame while scrolling, even when invisible.
            .background {
                if on {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.001))
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
                }
            }
            .overlay {
                if glow && on {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Palette.safelight.opacity(0.9), lineWidth: 2)
                        .shadow(color: Palette.safelight.opacity(0.6), radius: 8)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(on && !reduceMotion ? scale : 1)
            .zIndex(on ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.72), value: hovering)
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if cursor { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .onDisappear { if hovering && cursor { NSCursor.pop() }; hovering = false }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.035, radius: CGFloat = 12, glow: Bool = false, cursor: Bool = true) -> some View {
        modifier(HoverLift(scale: scale, radius: radius, glow: glow, cursor: cursor))
    }
}

// MARK: - Filter pills

/// A chunky, legible filter control: icon, label, current value, chevron. Tinted when a filter is active.
struct FilterPill<Value: Hashable>: View {
    let icon: String
    let title: String
    @Binding var selection: Value?
    let options: [(Value, String)]
    @State private var hovering = false

    private var label: String { options.first { $0.0 == selection }?.1 ?? title }

    var body: some View {
        Menu {
            Button("Any \(title.lowercased())") { selection = nil }
            Divider()
            ForEach(options, id: \.0) { value, text in
                Button { selection = value } label: {
                    if value == selection { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(selection == nil ? Palette.ink : Palette.onSafelight)
            .background(Capsule().fill(selection == nil ? Palette.card : Palette.safelight))
            .overlay(Capsule().strokeBorder(selection == nil ? Palette.rule : .clear, lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 6, y: 3)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title): \(label)")
    }
}

struct SearchPill: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink2)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 150)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.ink2)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Capsule().fill(Palette.card))
        .overlay(Capsule().strokeBorder(text.isEmpty ? Palette.rule : Palette.safelight, lineWidth: 1))
    }
}

/// The shared filter row for All Photos and Find.
struct FilterBar: View {
    @Binding var filter: PhotoFilter
    let cameras: [String]
    let lenses: [String]
    let imports: [ImportRecord]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                SearchPill(placeholder: "Filename", text: $filter.text)
                FilterPill(icon: "doc", title: "Type", selection: $filter.fileType,
                           options: [("jpg", "JPEG"), ("heic", "HEIC"), ("raw", "Has RAW"), ("png", "PNG")])
                if !cameras.isEmpty {
                    FilterPill(icon: "camera", title: "Camera", selection: $filter.camera, options: cameras.map { ($0, $0) })
                }
                if !lenses.isEmpty {
                    FilterPill(icon: "camera.aperture", title: "Lens", selection: $filter.lens, options: lenses.map { ($0, $0) })
                }
                FilterPill(icon: "star", title: "Rating", selection: $filter.minRating,
                           options: (1...5).map { ($0, String(repeating: "★", count: $0) + " & up") })
                if !imports.isEmpty {
                    FilterPill(icon: "tray.and.arrow.down", title: "Import", selection: $filter.importID,
                               options: imports.map { ($0.id, "\($0.sourceName) · \(Format.day.string(from: $0.startedAt))") })
                }
                if filter.from != nil || filter.to != nil {
                    Button { filter.from = nil; filter.to = nil } label: {
                        Label(dateRangeLabel, systemImage: "calendar").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(Capsule().fill(Palette.safelight)).foregroundStyle(Palette.onSafelight)
                    }.buttonStyle(.plain).help("Clear date range")
                }
                if !filter.isEmpty {
                    Button("Clear all") { filter = PhotoFilter() }.buttonStyle(.plain).foregroundStyle(Palette.safelight)
                        .font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                }
            }.padding(.vertical, 4)
        }
    }

    private var dateRangeLabel: String {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        switch (filter.from, filter.to) {
        case let (a?, b?): return "\(f.string(from: a)) – \(f.string(from: b.addingTimeInterval(-1)))"
        case let (a?, nil): return "From \(f.string(from: a))"
        case let (nil, b?): return "Until \(f.string(from: b))"
        default: return ""
        }
    }
}

// MARK: - Drag out (many files at once)

/// A handle that drags every given file into Finder, Messages, Mail, WhatsApp… SwiftUI's drag API carries one
/// item per gesture, so this uses AppKit's dragging session to carry them all.
struct DragOutHandle: NSViewRepresentable {
    let urls: () -> [URL]
    let label: String

    func makeNSView(context: Context) -> DragView { DragView(urls: urls, label: label) }
    func updateNSView(_ v: DragView, context: Context) { v.urls = urls; v.label = label; v.needsDisplay = true }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL]
        var label: String
        private var hovering = false { didSet { needsDisplay = true } }
        init(urls: @escaping () -> [URL], label: String) {
            self.urls = urls; self.label = label
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
            setAccessibilityRole(.button)
            setAccessibilityLabel(label)
            toolTip = "Drag these photos into Finder, Messages, Mail or any app"
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize {
            let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            return NSSize(width: w + 46, height: 32)
        }
        override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.openHand.push() }
        override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.pop() }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.clear).setFill(); path.fill()
            NSColor.secondaryLabelColor.withAlphaComponent(hovering ? 0.9 : 0.5).setStroke()
            path.setLineDash([4, 3], count: 2, phase: 0); path.lineWidth = 1.2; path.stroke()
            let icon = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon?.draw(in: NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16))
            (label as NSString).draw(at: NSPoint(x: 34, y: (bounds.height - 16) / 2),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        }
        override func mouseDown(with event: NSEvent) {
            let files = urls()
            guard !files.isEmpty else { NSSound.beep(); return }
            let items = files.prefix(500).enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(i, 4)) * 4
                item.setDraggingFrame(NSRect(x: offset, y: offset, width: 48, height: 48), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}

/// Anchor view for share pickers launched from SwiftUI buttons.
struct ShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { view = v }; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Photo badges

struct ShotBadge: View {
    let icon: String
    let text: String
    var tint: Color = .black.opacity(0.62)
    var fg: Color = .white
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(tint)).foregroundStyle(fg)
    }
}
