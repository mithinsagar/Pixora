import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

// MARK: - Theme

/// Private Space has its own look whatever the app theme: a lens-cap darkness with brass lens markings and a
/// faint violet light leak — the feeling of stepping somewhere hidden inside the darkroom.
enum Vault {
    static let night = Color(hex: 0x09070D)
    static let plum = Color(hex: 0x1B1428)
    static let card = Color(hex: 0x15101E)
    static let cardHi = Color(hex: 0x1E1729)
    static let rule = Color(hex: 0x2D2339)
    static let ink = Color(hex: 0xF4EEE6)
    static let ink2 = Color(hex: 0xA99EB6)
    static let ink3 = Color(hex: 0x726880)
    static let brass = Color(hex: 0xE4BE7F)
    static let brassDeep = Color(hex: 0xB88A4A)
    static let onBrass = Color(hex: 0x1C130A)
    static let glow = Color(hex: 0x9E86FF)
    static let danger = Color(hex: 0xFF6B5E)
    static let safe = Color(hex: 0x86D9AE)
    static let amber = Color(hex: 0xF0A04B)
    static let errorText = Color(hex: 0xFF9A8F)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

/// Small spaced capitals above titles, like the markings on a lens barrel.
struct VaultEyebrow: View {
    let text: String
    var icon: String? = nil
    var color: Color = Vault.brass
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(2.2)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// The dark, slowly breathing backdrop. Static with Reduce Motion.
struct VaultBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Vault.night
                RadialGradient(colors: [Vault.plum, Vault.night], center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 0.75)
                Circle().fill(Vault.glow.opacity(0.13)).frame(width: 620, height: 620).blur(radius: 150)
                    .offset(x: drift ? geo.size.width * 0.22 : -geo.size.width * 0.18, y: drift ? -geo.size.height * 0.22 : -geo.size.height * 0.12)
                Circle().fill(Vault.brass.opacity(0.06)).frame(width: 520, height: 520).blur(radius: 160)
                    .offset(x: drift ? -geo.size.width * 0.25 : geo.size.width * 0.2, y: drift ? geo.size.height * 0.3 : geo.size.height * 0.18)
                FilmGrain().opacity(0.3)
                RadialGradient(colors: [.clear, .black.opacity(0.6)], center: .center,
                               startRadius: min(geo.size.width, geo.size.height) * 0.35, endRadius: max(geo.size.width, geo.size.height) * 0.85)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

// MARK: - Buttons & fields

struct VaultButton: ButtonStyle {
    enum Kind { case primary, secondary, danger, quiet }
    var kind: Kind = .primary
    var wide = false

    func makeBody(configuration: Configuration) -> some View { VaultButtonBody(configuration: configuration, kind: kind, wide: wide) }
}

private struct VaultButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: VaultButton.Kind
    let wide: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 10 : 16).padding(.vertical, 9)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(foreground)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 && enabled }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        switch kind {
        case .primary:
            shape.fill(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: Vault.brass.opacity(enabled ? (hover ? 0.45 : 0.22) : 0), radius: hover ? 14 : 8, y: 2)
        case .secondary:
            shape.fill(Vault.cardHi.opacity(hover ? 1 : 0.8)).overlay(shape.strokeBorder(Vault.brass.opacity(hover ? 0.6 : 0.32)))
        case .danger:
            shape.fill(Vault.danger.opacity(hover ? 1 : 0.88))
                .shadow(color: Vault.danger.opacity(enabled ? 0.35 : 0), radius: 10, y: 2)
        case .quiet:
            shape.fill(.white.opacity(hover ? 0.08 : 0))
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Vault.onBrass
        case .secondary: Vault.ink
        case .danger: .white
        case .quiet: Vault.ink2
        }
    }
}

/// A rounded "glass" field for passwords, with an optional trailing control.
struct VaultField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var icon = "key.fill"
    var autofocus = false
    var onSubmit: () -> Void = {}
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(focused ? Vault.brass : Vault.ink3)
                .frame(width: 16).accessibilityHidden(true)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .foregroundStyle(Vault.ink)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
            trailing
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? Vault.brass.opacity(0.7) : Vault.rule, lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? Vault.brass.opacity(0.18) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { if autofocus { focused = true } }
    }
}

extension VaultField where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>, icon: String = "key.fill", autofocus: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.init(placeholder: placeholder, text: text, icon: icon, autofocus: autofocus, onSubmit: onSubmit) { EmptyView() }
    }
}

/// Strength meter for a new password, in Private Space colours.
struct StrengthBar: View {
    let password: String
    var body: some View {
        let score = min(4, (password.count >= 10 ? 1 : 0) + (password.count >= 16 ? 1 : 0)
                        + (password.contains(" ") || password.rangeOfCharacter(from: .punctuationCharacters) != nil ? 1 : 0)
                        + (password.rangeOfCharacter(from: .decimalDigits) != nil && password.rangeOfCharacter(from: .letters) != nil ? 1 : 0))
        let colors = [Vault.danger, Vault.amber, Vault.brass, Vault.safe]
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i < score ? colors[score - 1] : Vault.rule).frame(height: 4)
            }
            Text(["Too short", "Weak", "OK", "Good", "Strong"][score]).font(.caption2.weight(.medium)).foregroundStyle(Vault.ink2)
                .frame(width: 62, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(["too short", "weak", "OK", "good", "strong"][score])")
    }
}

/// An error line with an icon, announced to VoiceOver.
struct VaultErrorLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(Vault.errorText)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

/// A card for grouped content inside Private Space.
struct VaultCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.map { $0.opacity(0.08) } ?? Vault.card.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder((tint ?? Vault.rule).opacity(tint == nil ? 1 : 0.45)))
    }
}

/// The frame shared by every Private Space sheet: dark backdrop, generous padding, dark appearance.
struct VaultSheet<Content: View>: View {
    var width: CGFloat = 540
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(28)
            .frame(width: width)
            .background(VaultBackdrop())
            .environment(\.colorScheme, .dark)
    }
}

/// A themed confirmation, used for privacy changes (instead of the system dialog).
struct VaultDialog: View {
    let icon: String
    let title: String
    let message: String
    var bullets: [String] = []
    let confirm: String
    var destructive = false
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VaultSheet(width: 500) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle().fill((destructive ? Vault.danger : Vault.brass).opacity(0.15)).frame(width: 52, height: 52)
                    Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(destructive ? Vault.danger : Vault.brass)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(Vault.title(22)).foregroundStyle(Vault.ink).fixedSize(horizontal: false, vertical: true)
                    Text(message).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                    ForEach(bullets, id: \.self) { b in
                        Label { Text(b).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Vault.brass) }
                            .font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(VaultButton(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(confirm) { onConfirm(); dismiss() }.buttonStyle(VaultButton(kind: destructive ? .danger : .primary)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Root

struct PrivateSpaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            VaultBackdrop()
            Group {
                let _ = model.vaultEpoch
                if !model.vault.isSetUp || model.privateSetupInProgress {
                    PrivateSetup().transition(.opacity)
                } else if !model.isPrivateUnlocked {
                    PrivateUnlock().transition(.opacity)
                } else {
                    PrivateContentView()
                        .overlay { RevealOverlay(token: model.privateRevealID) }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.isPrivateUnlocked)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Lens emblem

/// Brass lens-barrel markings around the iris: tick marks and f-numbers.
private struct LensRing: View {
    var rotation: Double = 0
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r + 1, y: c.y - r + 1, width: 2 * r - 2, height: 2 * r - 2)),
                       with: .color(Vault.brass.opacity(0.18)), lineWidth: 1)
            for i in 0..<72 {
                let a = Double(i) / 72 * 2 * .pi + rotation
                let long = i % 9 == 0
                let r1 = r - (long ? 14 : 8), r2 = r - 3
                var p = Path()
                p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
                p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r2, y: c.y + CGFloat(sin(a)) * r2))
                ctx.stroke(p, with: .color(Vault.brass.opacity(long ? 0.55 : 0.22)), lineWidth: long ? 1.4 : 0.8)
            }
            let stops = ["1.4", "2", "2.8", "4", "5.6", "8", "11", "16"]
            for (i, s) in stops.enumerated() {
                let a = Double(i) / Double(stops.count) * 2 * .pi - .pi / 2 + rotation
                let rr = r - 26
                ctx.draw(Text(s).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(Vault.brass.opacity(0.6)),
                         at: CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr))
            }
        }
    }
}

/// The iris inside its lens ring, with a soft glow. Used on every Private Space entry screen.
struct LensEmblem: View {
    var size: CGFloat = 200
    var opening: CGFloat = 0
    var symbol: String? = "lock.fill"
    var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = 0.0

    var body: some View {
        ZStack {
            Circle().fill(Vault.glow.opacity(0.16)).frame(width: size * 1.2, height: size * 1.2).blur(radius: 40)
            LensRing(rotation: spin).frame(width: size * 1.62, height: size * 1.62)
            Aperture(progress: opening).frame(width: size, height: size)
                .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Vault.brass.opacity(0.5), radius: 8)
            }
        }
        .frame(width: size * 1.62, height: size * 1.62)
        .accessibilityHidden(true)
        .onChange(of: turning) { _, on in
            guard !reduceMotion else { return }
            withAnimation(on ? .linear(duration: 6).repeatForever(autoreverses: false) : .easeOut(duration: 0.4)) { spin = on ? .pi * 2 : 0 }
        }
    }
}

// MARK: - Aperture

/// A camera iris: seven blades whose inner edges form a polygon that widens and turns as it opens.
struct Aperture: View, Animatable {
    var progress: CGFloat   // 0 closed … 1 fully open
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let lens = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(lens, with: .color(Color(hex: 0x050408)))
            var inner = ctx
            inner.clip(to: Path(ellipseIn: CGRect(x: c.x - r * 0.93, y: c.y - r * 0.93, width: r * 1.86, height: r * 1.86)))
            let n = 7
            let apothem = progress * r * 1.12
            let twist = Double(progress) * .pi / 4.5
            for i in 0..<n {
                let a = Double(i) * 2 * .pi / Double(n) + twist
                let nx = CGFloat(cos(a)), ny = CGFloat(sin(a))
                let tx = -ny, ty = nx
                let p = CGPoint(x: c.x + nx * apothem, y: c.y + ny * apothem)
                let big = r * 3
                var blade = Path()
                blade.move(to: CGPoint(x: p.x + tx * big, y: p.y + ty * big))
                blade.addLine(to: CGPoint(x: p.x - tx * big, y: p.y - ty * big))
                blade.addLine(to: CGPoint(x: p.x - tx * big + nx * big, y: p.y - ty * big + ny * big))
                blade.addLine(to: CGPoint(x: p.x + tx * big + nx * big, y: p.y + ty * big + ny * big))
                blade.closeSubpath()
                let shade = 0.13 + 0.045 * Double(i % 3)
                inner.fill(blade, with: .linearGradient(Gradient(colors: [Color(white: shade + 0.07), Color(white: shade - 0.06)]),
                                                        startPoint: p, endPoint: CGPoint(x: p.x + nx * r, y: p.y + ny * r)))
                var edge = Path()
                edge.move(to: CGPoint(x: p.x + tx * big, y: p.y + ty * big))
                edge.addLine(to: CGPoint(x: p.x - tx * big, y: p.y - ty * big))
                inner.stroke(edge, with: .color(Vault.glow.opacity(0.3 + 0.4 * Double(progress))), lineWidth: 1)
            }
            ctx.stroke(lens, with: .linearGradient(Gradient(colors: [Vault.brass.opacity(0.85), Vault.brassDeep.opacity(0.4)]),
                                                   startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)), lineWidth: 2.5)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * 0.93, y: c.y - r * 0.93, width: r * 1.86, height: r * 1.86)), with: .color(.white.opacity(0.1)), lineWidth: 1)
        }
    }
}

/// After a correct password: the iris opens across the window while the photos are already there behind it.
/// Purely decorative — no hit testing, and it never delays access. Skipped with Reduce Motion.
private struct RevealOverlay: View {
    let token: UUID?
    @State private var progress: CGFloat = 0
    @State private var visible = false
    @State private var shown: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if visible {
                let d = hypot(geo.size.width, geo.size.height)
                ZStack {
                    Aperture(progress: progress)
                        .frame(width: d * (0.35 + 0.9 * progress), height: d * (0.35 + 0.9 * progress))
                    LensRing(rotation: Double(progress) * .pi / 3)
                        .frame(width: d * (0.5 + 1.1 * progress), height: d * (0.5 + 1.1 * progress))
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .opacity(Double(1 - progress * 0.95))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { play() }
        .onChange(of: token) { play() }
    }

    private func play() {
        guard let token, token != shown else { return }
        shown = token
        if reduceMotion { return }
        progress = 0; visible = true
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9)) { progress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { visible = false }
    }
}

/// Static film grain so the dark backdrop has texture.
private struct FilmGrain: View {
    var body: some View {
        Canvas { ctx, size in
            var g = SeededGrain(seed: 7)
            for _ in 0..<Int(size.width * size.height / 900) {
                let x = CGFloat(g.next() % UInt64(max(1, size.width))), y = CGFloat(g.next() % UInt64(max(1, size.height)))
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(Double(g.next() % 30) / 400)))
            }
        }
    }
}

private struct SeededGrain { var s: UInt64; init(seed: UInt64) { s = seed }; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

// MARK: - Password file

/// Saves the password the user just chose to a text file *they* pick, only when they ask. This is the one
/// copy of the password outside their head; Pixora keeps no other.
enum PasswordFile {
    @MainActor static func save(_ password: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Private Space Password"
        panel.message = "Anyone who gets this file can open your Private Space. Choose somewhere safe."
        panel.prompt = "Save Password File"
        panel.nameFieldStringValue = "Pixora Private Space Password.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let text = """
        Pixora — Private Space password

        Password: \(password)

        Saved \(Date().formatted(date: .long, time: .shortened)).

        This is the password for Private Space in Pixora. It is not your Mac, Apple Account or any other password.
        Anyone who has this file can open your Private Space. Keep it somewhere safe — a password manager, an
        encrypted drive, or printed and put away — and not next to your photos or in a shared folder.
        If you change the password in Pixora, this file no longer works.

        """
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}

/// "Keep a copy" panel: save button, where it went, and the warning. Shared by setup and password change.
struct PasswordFilePanel: View {
    let password: String
    @Binding var savedTo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultCard {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Vault.cardHi).frame(width: 52, height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Vault.brass.opacity(0.4)))
                        VStack(spacing: 4) {
                            Image(systemName: "key.horizontal.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Vault.brass)
                            Text("TXT").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Vault.ink3)
                        }
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pixora Private Space Password.txt").font(.system(size: 14, weight: .semibold)).foregroundStyle(Vault.ink)
                        Text("A plain text file with the password you just chose. Nothing is saved until you pick where it goes — Pixora never e-mails, uploads or syncs it.")
                            .font(.callout).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button { if let u = PasswordFile.save(password) { savedTo = u } } label: {
                                Label(savedTo == nil ? "Save Password File…" : "Save Another Copy…", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(VaultButton(kind: savedTo == nil ? .primary : .secondary))
                            if let savedTo {
                                Label("Saved in “\(savedTo.deletingLastPathComponent().lastPathComponent)”", systemImage: "checkmark.circle.fill")
                                    .font(.callout.weight(.medium)).foregroundStyle(Vault.safe)
                                    .help(savedTo.path)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedTo]) }
                                    .buttonStyle(VaultButton(kind: .quiet))
                            }
                        }.padding(.top, 4)
                    }
                }
            }
            VaultCard(tint: Vault.danger) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anyone who gets this file can open your Private Space.").font(.callout.weight(.semibold)).foregroundStyle(Vault.ink)
                        Text("Keep it away from your photos and shared folders — a password manager, an encrypted drive, or a printed copy put somewhere safe is better.")
                            .font(.callout).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Vault.danger) }
            }
        }
    }
}

// MARK: - Setup

private struct PrivateSetup: View {
    @Environment(AppModel.self) private var model
    enum Step { case create, keepCopy }
    @State private var step: Step = .create
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var savedTo: URL?
    @State private var leftovers = PrivateVault.Footprint()

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                LensEmblem(size: 130, opening: step == .create ? 0.06 : 0.3, symbol: step == .create ? "sparkles" : "key.horizontal.fill", turning: working)
                    .animation(.easeInOut(duration: 0.6), value: step)
                StepDots(step: step == .create ? 0 : 1, labels: ["Create password", "Keep a copy"])
                Group {
                    switch step {
                    case .create: createStep
                    case .keepCopy: keepCopyStep
                    }
                }
                .frame(maxWidth: 560)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 30)), removal: .opacity.combined(with: .offset(x: -30))))
            }
            .padding(.vertical, 44).padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { leftovers = model.vault.isSetUp ? .init() : model.vault.footprint() }
        .onDisappear {
            // Leaving mid-setup: forget the password from memory; Private Space itself is already created.
            password = ""; confirm = ""
            if model.privateSetupInProgress { model.privateSetupInProgress = false; model.vaultEpoch += 1 }
        }
    }

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                VaultEyebrow(text: "New Private Space", icon: "lock.shield")
                Text("Create a password for Private Space").font(Vault.title(32)).foregroundStyle(Vault.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is a **separate password just for Pixora’s Private Space**. It isn’t your Mac login, your Apple Account or any other password — make up a new one you’ll remember.")
                    .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if !leftovers.isEmpty {
                VaultCard(tint: Vault.amber) {
                    Label {
                        Text("An earlier Private Space on this Mac can no longer be opened — this version can’t read its key. Creating a new one deletes its \(Format.count(leftovers.items, "encrypted copy", "encrypted copies")). Your original photos on cards and drives aren’t touched.")
                            .font(.callout).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(Vault.amber) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                VaultField(placeholder: "New Private Space password (10+ characters)", text: $password, autofocus: true)
                VaultField(placeholder: "Type it again", text: $confirm, icon: "checkmark.shield", onSubmit: create)
                HStack(spacing: 12) {
                    StrengthBar(password: password)
                    if !confirm.isEmpty {
                        Label(password == confirm ? "Matches" : "Doesn’t match", systemImage: password == confirm ? "checkmark" : "xmark")
                            .font(.caption.weight(.semibold)).foregroundStyle(password == confirm ? Vault.safe : Vault.errorText)
                            .fixedSize()
                    }
                }
                if let error { VaultErrorLine(text: error) }
                Button(action: create) {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Creating…" : "Create Private Space")
                    }
                }
                .buttonStyle(VaultButton(wide: true)).keyboardShortcut(.defaultAction)
                .disabled(working || password.isEmpty || password != confirm)
                .padding(.top, 4)
            }
            VaultCard {
                VStack(alignment: .leading, spacing: 12) {
                    promise("lock.doc.fill", "Encrypted on this Mac", "Private photos’ previews, faces and details are sealed with AES-256 and leave the regular library.")
                    promise("key.slash", "Your password is never stored", "It unlocks the key to Private Space through PBKDF2 (600,000 rounds). Pixora can’t show it to you later.")
                    promise("sdcard", "Originals stay where they are", "Pixora never changes, moves or deletes files on your cards and drives.")
                    promise("wifi.slash", "No account, no internet", "Everything happens on this Mac, offline.")
                }
            }
        }
    }

    private var keepCopyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                VaultEyebrow(text: "Private Space created", icon: "checkmark.seal.fill", color: Vault.safe)
                Text("Keep a copy of your password").font(Vault.title(32)).foregroundStyle(Vault.ink)
                Text("Pixora can’t show or recover this password later. If you forget it, the only way back is to delete Private Space and start again — so a copy somewhere safe is worth having.")
                    .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            }
            PasswordFilePanel(password: password, savedTo: $savedTo)
            HStack {
                if savedTo == nil {
                    Text("Saving a copy is optional.").font(.callout).foregroundStyle(Vault.ink3)
                }
                Spacer()
                Button { enter() } label: { Label("Enter Private Space", systemImage: "arrow.right") }
                    .buttonStyle(VaultButton()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func promise(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Vault.brass).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Vault.ink)
                Text(text).font(.callout).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func create() {
        guard password == confirm else { error = "The two passwords don’t match."; return }
        do { try PrivateVault.checkStrength(password) } catch { self.error = error.localizedDescription; return }
        working = true; error = nil
        model.privateSetupInProgress = true
        let vault = model.vault, pw = password
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try vault.setUp(password: pw) }.value
                confirm = ""
                model.refreshAll()   // leftovers from an unreadable earlier Private Space may have been cleared
                withAnimation(.easeInOut(duration: 0.35)) { step = .keepCopy }
            } catch {
                model.privateSetupInProgress = false
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func enter() {
        password = ""
        model.privateSetupInProgress = false
        model.reloadPrivateContent()
        model.restartIdleTimer()
        model.vaultEpoch += 1
        model.privateRevealID = UUID()
    }
}

private struct StepDots: View {
    let step: Int
    let labels: [String]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(labels.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(i <= step ? Vault.brass : Vault.rule).frame(width: 22, height: 22)
                        if i < step { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Vault.onBrass) }
                        else { Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(i == step ? Vault.onBrass : Vault.ink3) }
                    }
                    Text(labels[i]).font(.system(size: 12, weight: i == step ? .semibold : .regular)).foregroundStyle(i == step ? Vault.ink : Vault.ink3)
                }
                if i < labels.count - 1 { Capsule().fill(i < step ? Vault.brass : Vault.rule).frame(width: 36, height: 2) }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(labels.count): \(labels[step])")
    }
}

// MARK: - Locked

private struct PrivateUnlock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var shake: CGFloat = 0
    @State private var showForgot = false
    @State private var showChange = false
    @AppStorage("privateIdleMinutes") private var idleMinutes = 5

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            LensEmblem(size: 190, opening: working ? 0.1 : 0, turning: working)
                .animation(.easeInOut(duration: 0.4), value: working)
            VStack(spacing: 10) {
                VaultEyebrow(text: "Private Space", icon: "lock.fill")
                Text("Locked away").font(Vault.title(38)).foregroundStyle(Vault.ink)
                Text("Enter your Private Space password to step inside.").foregroundStyle(Vault.ink2)
            }
            .padding(.top, 22)
            VStack(alignment: .leading, spacing: 10) {
                VaultField(placeholder: "Private Space password", text: $password, autofocus: true, onSubmit: unlock) {
                    Button(action: unlock) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom))
                            if working { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Vault.onBrass) }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain).disabled(password.isEmpty || working).opacity(password.isEmpty ? 0.45 : 1)
                    .accessibilityLabel("Unlock")
                }
                .offset(x: shake)
                if let error { VaultErrorLine(text: error) }
            }
            .frame(width: 340)
            .padding(.top, 24)
            HStack(spacing: 6) {
                Button("Forgot password?") { showForgot = true }.buttonStyle(VaultButton(kind: .quiet))
                Text("·").foregroundStyle(Vault.ink3)
                Button("Change password…") { showChange = true }.buttonStyle(VaultButton(kind: .quiet))
            }
            .padding(.top, 14)
            Spacer(minLength: 24)
            HStack(spacing: 18) {
                footnote("lock.doc", "Encrypted on this Mac")
                footnote("wifi.slash", "Works offline")
                footnote("moon.zzz", idleMinutes > 0 ? "Locks after \(idleMinutes) min idle, on sleep and screen lock" : "Locks on sleep and screen lock")
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showForgot) { DeletePrivateSpaceSheet(forgot: true) }
        .sheet(isPresented: $showChange) { ChangePasswordSheet() }
    }

    private func footnote(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(Vault.ink3)
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
                withAnimation(.easeOut(duration: 0.2)) { self.error = error.localizedDescription }
                if !reduceMotion {
                    withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) { shake = 12 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring()) { shake = 0 } }
                }
            }
            working = false
        }
    }
}

// MARK: - Unlocked

private struct PrivateContentView: View {
    @Environment(AppModel.self) private var model
    enum Tab: Hashable { case photos, people, review }
    @State private var tab: Tab = .photos
    @State private var selecting = false
    @State private var selected: Set<Int64> = []
    @State private var personFilter: Int64?
    @State private var inspected: Int64?
    @State private var showChange = false
    @State private var showDelete = false
    @State private var showStudio = false
    @Namespace private var tabs

    var body: some View {
        let content = model.privateContent ?? PrivateVault.Content()
        let all = content.items.filter { !$0.isPendingReview }
            .sorted { ($0.photo.takenAt ?? .distantPast, $0.photo.filename) > ($1.photo.takenAt ?? .distantPast, $1.photo.filename) }
        let shown = personFilter.map { pid in all.filter { $0.persons.contains(pid) } } ?? all
        let pending = content.items.filter(\.isPendingReview)
        VStack(spacing: 0) {
            header(all: all.count, people: content.people.count, pending: pending.count)
            Rectangle().fill(LinearGradient(colors: [.clear, Vault.brass.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)

            switch tab {
            case .photos:
                if let pid = personFilter, let name = content.people.first(where: { $0.id == pid })?.name {
                    HStack(spacing: 10) {
                        Label("Showing \(name)", systemImage: "person.fill").foregroundStyle(Vault.ink)
                        Button("Show everyone") { personFilter = nil }.buttonStyle(VaultButton(kind: .quiet))
                        Spacer()
                    }
                    .font(.callout).padding(.horizontal, 28).padding(.top, 12)
                }
                if shown.isEmpty {
                    EmptyPrivate(icon: "photo.on.rectangle.angled", title: "Nothing hidden yet",
                                 text: "Choose Make Private in a photo’s viewer, its details or a selection — or make a whole person private from their page in People.")
                } else {
                    PhotoGrid(items: shown.map { ($0.photo, TileInfo(matches: $0.faces.compactMap { f in f.personID.map { PersonMatch(personID: $0, faceID: f.id, state: f.state, score: f.score) } })) },
                              inspected: $inspected, selecting: selecting, selected: selected,
                              onToggleSelect: { selected.formSymmetricDifference([$0]) },
                              onOpen: { id in model.openViewer(shown.map(\.photo), at: id, title: "Private Space") },
                              viewerTitle: "Private Space", headerBackground: Vault.night.opacity(0.92))
                }
                if selecting {
                    PrivateSelectionBar(selected: shown.map(\.photo).filter { selected.contains($0.id) }, total: shown.count,
                                        selectAll: { selected = Set(shown.map(\.photo.id)) }, selectNone: { selected = [] },
                                        done: { selecting = false; selected = [] })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .people:
                PrivatePeopleGrid(content: content) { pid in personFilter = pid; withAnimation { tab = .photos } }
            case .review:
                PrivateReview(items: pending, people: content.people)
            }
        }
        .animation(.easeOut(duration: 0.2), value: selecting)
        .sheet(isPresented: $showChange) { ChangePasswordSheet() }
        .sheet(isPresented: $showDelete) { DeletePrivateSpaceSheet(forgot: false) }
        .sheet(isPresented: $showStudio) {
            SlideshowStudioSheet(source: .privateSpace(
                shown.map { item in
                    SlideCandidate(photo: item.photo, faces: item.faces.map { SlideFace(personID: $0.personID, certain: $0.state.isCertain, rect: $0.rect, pixelSize: $0.pixelSize) })
                },
                people: content.people.map { SlidePerson(id: $0.id, name: $0.name) }))
        }
    }

    private func header(all: Int, people: Int, pending: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                VaultEyebrow(text: "Private Space · Unlocked", icon: "lock.open.fill")
                Text("Hidden photos").font(Vault.title(30)).foregroundStyle(Vault.ink)
                Text("Only visible here, while unlocked. Locks when you leave, sleep the Mac or step away.")
                    .font(.caption).foregroundStyle(Vault.ink2).lineLimit(2)
            }
            Spacer(minLength: 12)
            VaultTabs(selection: $tab, items: [(.photos, "Photos", all), (.people, "People", people), (.review, "Review", pending)], namespace: tabs)
            Spacer(minLength: 12)
            if tab == .photos {
                Button { showStudio = true } label: { Label("Slideshow", systemImage: "play.rectangle.fill") }
                    .buttonStyle(VaultButton(kind: .secondary)).disabled(all == 0).fixedSize()
                    .help("Make a private slideshow of these photos — it stays in Private Space")
                Button { withAnimation { selecting.toggle(); if !selecting { selected = [] } } } label: {
                    Label(selecting ? "Done" : "Select", systemImage: selecting ? "checkmark" : "checkmark.circle")
                }
                .buttonStyle(VaultButton(kind: .secondary)).disabled(all == 0).fixedSize()
            }
            Menu {
                Button("Change Password…") { showChange = true }
                Divider()
                Button("Delete Private Space…", role: .destructive) { showDelete = true }
            } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More Private Space actions")
            Button { model.lockPrivateSpace() } label: { Label("Lock", systemImage: "lock.fill") }
                .buttonStyle(VaultButton()).keyboardShortcut("l", modifiers: .command).help("Lock now (⌘L)").fixedSize()
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }
}

/// Segmented control with a sliding brass pill.
private struct VaultTabs<T: Hashable>: View {
    @Binding var selection: T
    let items: [(T, String, Int)]
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (tag, title, count) = items[i]
                let on = tag == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { selection = tag }
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: on ? .semibold : .medium))
                        Text("\(count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(on ? Vault.onBrass.opacity(0.15) : Vault.rule))
                    }
                    .foregroundStyle(on ? Vault.onBrass : Vault.ink2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background {
                        if on { Capsule().fill(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom)).matchedGeometryEffect(id: "pill", in: namespace) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Vault.rule))
        .fixedSize()
    }
}

private struct EmptyPrivate: View {
    let icon: String, title: String, text: String
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Vault.brass.opacity(0.08)).frame(width: 96, height: 96)
                Circle().strokeBorder(Vault.brass.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(width: 96, height: 96)
                Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Vault.brass)
            }.accessibilityHidden(true)
            Text(title).font(Vault.title(24)).foregroundStyle(Vault.ink)
            Text(text).multilineTextAlignment(.center).foregroundStyle(Vault.ink2).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct PrivateSelectionBar: View {
    @Environment(AppModel.self) private var model
    let selected: [Photo]
    let total: Int
    let selectAll: () -> Void, selectNone: () -> Void, done: () -> Void
    @State private var anchor: NSView?
    var body: some View {
        HStack(spacing: 10) {
            Text("\(selected.count)").font(Vault.title(22)).foregroundStyle(Vault.ink).monospacedDigit()
                .contentTransition(.numericText()).animation(.snappy, value: selected.count)
            Text("of \(total) selected").font(.caption).foregroundStyle(Vault.ink2)
            Button("All", action: selectAll).buttonStyle(VaultButton(kind: .quiet))
            Button("None", action: selectNone).buttonStyle(VaultButton(kind: .quiet))
            Spacer()
            Button { model.share(selected, from: anchor) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(VaultButton(kind: .secondary)).background(ShareAnchor(view: $anchor)).disabled(selected.isEmpty)
            Button { model.requestExport(photos: selected) } label: { Label("Copy to Folder…", systemImage: "square.and.arrow.down.on.square") }
                .buttonStyle(VaultButton(kind: .secondary)).disabled(selected.isEmpty)
            Button { model.moveToLibrary(photos: selected); selectNone() } label: { Label("Move to Library", systemImage: "arrow.uturn.backward.circle.fill") }
                .buttonStyle(VaultButton()).disabled(selected.isEmpty)
                .help("Put these photos back in the regular library")
            Button("Done", action: done).buttonStyle(VaultButton(kind: .quiet)).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Vault.card.opacity(0.95))
        .overlay(alignment: .top) { Rectangle().fill(Vault.brass.opacity(0.6)).frame(height: 1) }
    }
}

private struct PrivatePeopleGrid: View {
    @Environment(AppModel.self) private var model
    let content: PrivateVault.Content
    let open: (Int64) -> Void
    @State private var confirmPublic: PrivateVault.Person?
    var body: some View {
        if content.people.isEmpty {
            EmptyPrivate(icon: "person.crop.circle.badge.questionmark", title: "No private people",
                         text: "Open someone in People and choose Make Private… Their future confident matches will come straight here.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20)], spacing: 20) {
                    ForEach(content.people) { p in
                        let items = content.items.filter { $0.persons.contains(p.id) }
                        let face = items.lazy.flatMap(\.faces).first { $0.personID == p.id }
                        VStack(alignment: .leading, spacing: 10) {
                            Button { open(p.id) } label: {
                                FaceImage(faceID: face?.id, size: 172, shape: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Vault.brass.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(p.name)’s photos")
                            Text(p.name).font(Vault.title(18)).foregroundStyle(Vault.ink)
                            HStack {
                                Text(Format.count(items.count, "photo")).font(.caption).foregroundStyle(Vault.ink2)
                                Spacer()
                                Button("Make Public…") { confirmPublic = p }.buttonStyle(VaultButton(kind: .quiet))
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Vault.card.opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Vault.rule))
                        .hoverLift(scale: 1.03, radius: 18)
                    }
                }.padding(28)
            }
            .sheet(item: $confirmPublic) { p in
                VaultDialog(icon: "lock.open.fill", title: "Make \(p.name) public again?",
                            message: "They come back to People and search.",
                            bullets: ["Photos that are private only because of them go back to the library.",
                                      "Photos you made private by hand stay private.",
                                      "New photos of them are no longer routed here."],
                            confirm: "Make Public") { model.makePersonPublic(p.id) }
            }
        }
    }
}

private struct PrivateReview: View {
    @Environment(AppModel.self) private var model
    let items: [PrivateVault.Item]
    let people: [PrivateVault.Person]
    var body: some View {
        if items.isEmpty {
            EmptyPrivate(icon: "checkmark.seal", title: "Nothing to review",
                         text: "When a new photo might show a private person but Pixora isn’t sure, it waits here — out of the regular library and search — until you decide.")
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        let pid = item.pendingPerson
                        let name = people.first { $0.id == pid }?.name ?? "this person"
                        let face = item.faces.first { $0.personID == pid }
                        HStack(spacing: 18) {
                            FaceImage(faceID: face?.id, size: 92, shape: AnyShape(Circle()))
                                .overlay(Circle().strokeBorder(Vault.brass.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            PhotoTile(photo: item.photo, index: 0, info: TileInfo(), imageSize: CGSize(width: 200, height: 130))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Is this \(name)?").font(Vault.title(20)).foregroundStyle(Vault.ink)
                                Text("Pixora isn’t sure. It stays out of the library until you decide.").font(.callout).foregroundStyle(Vault.ink2)
                                HStack {
                                    Button { model.rejectPrivateMatch(item) } label: { Label("No — return to library", systemImage: "xmark") }
                                        .buttonStyle(VaultButton(kind: .secondary))
                                    Button { model.confirmPrivateMatch(item) } label: { Label("Yes, keep private", systemImage: "checkmark") }
                                        .buttonStyle(VaultButton())
                                }
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Vault.card.opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Vault.rule))
                    }
                }.padding(28)
            }
        }
    }
}

// MARK: - Change password

/// Change the password with the current one. Local and offline; works locked or unlocked. Afterwards offers to
/// save the new password to a file (the old file stops working).
struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var changed: String?   // the new password, held only until this sheet closes
    @State private var savedTo: URL?

    var body: some View {
        VaultSheet(width: 560) {
            if let changed {
                VaultEyebrow(text: "Password changed", icon: "checkmark.seal.fill", color: Vault.safe)
                Text("Keep a copy of the new password").font(Vault.title(26)).foregroundStyle(Vault.ink)
                Text("Any password file you saved before no longer works.").foregroundStyle(Vault.ink2)
                PasswordFilePanel(password: changed, savedTo: $savedTo)
                HStack { Spacer(); Button("Done") { self.changed = nil; dismiss() }.buttonStyle(VaultButton()).keyboardShortcut(.defaultAction) }
            } else {
                VaultEyebrow(text: "Private Space", icon: "key.fill")
                Text("Change password").font(Vault.title(26)).foregroundStyle(Vault.ink)
                Text("You’ll need the current password. Nothing is sent anywhere — this happens on this Mac, offline.")
                    .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                VaultField(placeholder: "Current password", text: $current, icon: "lock.fill", autofocus: true)
                VaultField(placeholder: "New password (10+ characters)", text: $newPassword)
                VaultField(placeholder: "Type the new password again", text: $confirm, icon: "checkmark.shield", onSubmit: change)
                StrengthBar(password: newPassword)
                if let error { VaultErrorLine(text: error) }
                HStack {
                    Button("Forgot the current password?") { dismiss(); DispatchQueue.main.async { model.showDeletePrivateSpace = true } }
                        .buttonStyle(VaultButton(kind: .quiet))
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(VaultButton(kind: .secondary)).keyboardShortcut(.cancelAction)
                    Button(action: change) {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? "Changing…" : "Change Password")
                        }
                    }
                    .buttonStyle(VaultButton()).keyboardShortcut(.defaultAction)
                    .disabled(working || current.isEmpty || newPassword.isEmpty || newPassword != confirm)
                }
            }
        }
    }

    private func change() {
        guard newPassword == confirm else { error = "The new passwords don’t match."; return }
        guard newPassword != current else { error = "The new password is the same as the current one."; return }
        working = true; error = nil
        let vault = model.vault, cur = current, new = newPassword
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try vault.changePassword(current: cur, new: new) }.value
                current = ""; newPassword = ""; confirm = ""
                withAnimation { changed = new }
            } catch { withAnimation { self.error = error.localizedDescription } }
            working = false
        }
    }
}

// MARK: - Forgotten password: delete and recreate

/// The only way back from a forgotten password. Lists exactly what goes and what stays, needs an explicit
/// acknowledgement, and then deletes Private Space — never source photos or the ordinary library.
struct DeletePrivateSpaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var forgot = true
    @State private var footprint = PrivateVault.Footprint()
    @State private var understood = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VaultSheet(width: 660) {
            if done {
                VaultEyebrow(text: "Private Space deleted", icon: "checkmark.circle.fill", color: Vault.safe)
                Text("You can start again").font(Vault.title(28)).foregroundStyle(Vault.ink)
                Text("The old Private Space is gone and can’t be recovered. Your original photos and your regular library are exactly as they were.")
                    .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Not Now") { dismiss() }.buttonStyle(VaultButton(kind: .secondary)).keyboardShortcut(.cancelAction)
                    Button { model.section = .privateSpace; dismiss() } label: { Label("Create New Private Space", systemImage: "plus") }
                        .buttonStyle(VaultButton()).keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        Circle().fill(Vault.danger.opacity(0.15)).frame(width: 56, height: 56)
                        Image(systemName: forgot ? "questionmark.key.filled" : "trash.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Vault.danger)
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        VaultEyebrow(text: forgot ? "Forgot your password?" : "Delete Private Space", color: Vault.danger)
                        Text(forgot ? "Your password can’t be recovered" : "Delete Private Space?").font(Vault.title(28)).foregroundStyle(Vault.ink)
                        Text(forgot
                             ? "Pixora never stored your password, so nobody — including Pixora — can recover or reset it. If you saved a password file, look for “Pixora Private Space Password.txt”. Otherwise the only way back is to delete Private Space and create a new one."
                             : "Everything in Private Space is deleted permanently. You can create a new Private Space afterwards.")
                            .foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    VaultCard(tint: Vault.danger) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Will be deleted", systemImage: "trash").font(.system(size: 13, weight: .bold)).foregroundStyle(Vault.danger)
                            item("\(Format.count(footprint.items, "encrypted photo copy", "encrypted photo copies")) — previews, face crops and details (\(ByteCountFormatter.string(fromByteCount: footprint.bytes, countStyle: .file)))")
                            item("\(Format.count(footprint.people, "private person", "private people")), their hidden names and \(Format.count(footprint.faceTemplates, "face template"))")
                            item("Photos waiting in Private Space review")
                            item("The indexes that keep private photos out of the library")
                            item("The Private Space password and keys")
                        }
                    }
                    VaultCard(tint: Vault.safe) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Stays untouched", systemImage: "checkmark.shield").font(.system(size: 13, weight: .bold)).foregroundStyle(Vault.safe)
                            item("Original photos on SD cards, drives and folders — nothing is deleted, moved, renamed or changed", safe: true)
                            item("Your regular library: \(Format.count(model.stats.photos, "photo")) and \(Format.count(model.namedPeople.count, "named person", "named people"))", safe: true)
                            item("Settings, favourites and everything else in Pixora", safe: true)
                        }
                    }
                }
                Text("Photos that were private appear in the library again the next time you scan their folders. The deleted copies can’t be recovered.")
                    .font(.callout).foregroundStyle(Vault.ink2).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $understood) {
                    Text("I understand Private Space can’t be recovered after this").foregroundStyle(Vault.ink)
                }
                .toggleStyle(.checkbox)
                if let error { VaultErrorLine(text: error) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(VaultButton(kind: .secondary)).keyboardShortcut(.cancelAction)
                    Button { delete() } label: { Label("Delete Private Space", systemImage: "trash.fill") }
                        .buttonStyle(VaultButton(kind: .danger)).disabled(!understood)
                }
            }
        }
        .onAppear { footprint = model.vault.footprint() }
    }

    private func item(_ text: String, safe: Bool = false) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(Vault.ink).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: safe ? "checkmark" : "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(safe ? Vault.safe : Vault.danger)
        }
    }

    private func delete() {
        do {
            try model.deletePrivateSpace()
            withAnimation { done = true }
        } catch { self.error = error.localizedDescription }
    }
}
