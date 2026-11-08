import SwiftUI

/// Private Space has its own look whatever the system appearance: lens-cap darkness, brass lens markings and a
/// faint violet light leak. The same palette as the Mac app, sized for a phone.
enum Vault {
    static let night = Color(hex: 0x09070D)
    static let plum = Color(hex: 0x1B1428)
    static let card = Color(hex: 0x15101E)
    static let cardHi = Color(hex: 0x1E1729)
    static let rule = Color(hex: 0x2D2339)
    static let ink = Color(hex: 0xF4EEE6)
    static let ink2 = Color(hex: 0xA99EB6)
    static let ink3 = Color(hex: 0x8A7F99)
    static let brass = Color(hex: 0xE4BE7F)
    static let brassDeep = Color(hex: 0xB88A4A)
    static let onBrass = Color(hex: 0x1C130A)
    static let glow = Color(hex: 0x9E86FF)
    static let danger = Color(hex: 0xFF6B5E)
    static let safe = Color(hex: 0x86D9AE)
    static let errorText = Color(hex: 0xFF9A8F)

    static func title(_ style: Font.TextStyle = .title) -> Font { .system(style, design: .serif).weight(.semibold) }
}

struct VaultEyebrow: View {
    let text: String
    var icon: String? = nil
    var color: Color = Vault.brass
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(2)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// The dark, slowly drifting backdrop. Still with Reduce Motion.
struct VaultBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Vault.night
                RadialGradient(colors: [Vault.plum, Vault.night], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0,
                               endRadius: max(geo.size.width, geo.size.height) * 0.8)
                Circle().fill(Vault.glow.opacity(0.14)).frame(width: 360, height: 360).blur(radius: 90)
                    .offset(x: drift ? geo.size.width * 0.25 : -geo.size.width * 0.2, y: drift ? -geo.size.height * 0.2 : -geo.size.height * 0.1)
                Circle().fill(Vault.brass.opacity(0.07)).frame(width: 300, height: 300).blur(radius: 100)
                    .offset(x: drift ? -geo.size.width * 0.25 : geo.size.width * 0.2, y: drift ? geo.size.height * 0.3 : geo.size.height * 0.15)
                FilmGrain().opacity(0.3)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

struct VaultButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        return configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .foregroundStyle(kind == .primary ? Vault.onBrass : (kind == .danger ? .white : Vault.ink))
            .background {
                switch kind {
                case .primary:
                    shape.fill(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: Vault.brass.opacity(enabled ? 0.3 : 0), radius: 12, y: 3)
                case .secondary:
                    shape.fill(Vault.cardHi).overlay(shape.strokeBorder(Vault.brass.opacity(0.35)))
                case .danger:
                    shape.fill(Vault.danger)
                }
            }
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }
}

/// A password field with a show / hide control. Never autofilled from or saved to iCloud Keychain: Private Space
/// has its own password.
struct VaultPasswordField: View {
    let title: String
    @Binding var text: String
    var isNew = false
    var onSubmit: () -> Void = {}
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(Vault.brass.opacity(0.8)).accessibilityHidden(true)
            Group {
                if reveal { TextField(title, text: $text) } else { SecureField(title, text: $text) }
            }
            .textContentType(isNew ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(onSubmit)
            .foregroundStyle(Vault.ink)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(Vault.ink2).frame(width: 44, height: 44)
            }
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .padding(.leading, 16)
        .frame(minHeight: 54)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Vault.card.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Vault.brass.opacity(0.28)))
    }
}

struct StrengthBar: View {
    let password: String
    private var score: Int {
        var s = 0
        if password.count >= 10 { s += 1 }
        if password.count >= 14 { s += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil || password.contains(" ") { s += 1 }
        if Set(password).count >= 8 { s += 1 }
        return s
    }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { i in
                Capsule().fill(i < score ? (score >= 3 ? Vault.safe : Vault.brass) : Vault.rule).frame(height: 5)
            }
            Text(password.isEmpty ? "" : (password.count < 10 ? "Too short" : ["Weak", "Fair", "Good", "Strong", "Strong"][score]))
                .font(.caption.weight(.semibold)).foregroundStyle(Vault.ink2).frame(width: 70, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(password.count < 10 ? "too short" : ["weak", "fair", "good", "strong", "strong"][score])")
    }
}

struct VaultCard<Content: View>: View {
    var tint: Color = Vault.brass
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Vault.card.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}

// MARK: - Lens emblem and iris

/// Brass lens-barrel markings: tick marks and f-numbers.
struct LensRing: View {
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
                let r1 = r - (long ? 12 : 7), r2 = r - 3
                var p = Path()
                p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
                p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r2, y: c.y + CGFloat(sin(a)) * r2))
                ctx.stroke(p, with: .color(Vault.brass.opacity(long ? 0.55 : 0.22)), lineWidth: long ? 1.3 : 0.7)
            }
            let stops = ["1.4", "2", "2.8", "4", "5.6", "8", "11", "16"]
            for (i, s) in stops.enumerated() {
                let a = Double(i) / Double(stops.count) * 2 * .pi - .pi / 2 + rotation
                let rr = r - 22
                ctx.draw(Text(s).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(Vault.brass.opacity(0.6)),
                         at: CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr))
            }
        }
    }
}

struct LensEmblem: View {
    var size: CGFloat = 150
    var opening: CGFloat = 0
    var symbol: String? = "lock.fill"
    var body: some View {
        ZStack {
            Circle().fill(Vault.glow.opacity(0.16)).frame(width: size * 1.2, height: size * 1.2).blur(radius: 30)
            LensRing().frame(width: size * 1.55, height: size * 1.55)
            Aperture(progress: opening).frame(width: size, height: size).shadow(color: .black.opacity(0.6), radius: 16, y: 6)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Vault.brass, Vault.brassDeep], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Vault.brass.opacity(0.5), radius: 8)
            }
        }
        .frame(width: size * 1.55, height: size * 1.55)
        .accessibilityHidden(true)
    }
}

/// A camera iris: seven blades whose inner edges widen and turn as it opens.
struct Aperture: View, Animatable {
    var progress: CGFloat
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
        }
    }
}

/// After a correct password the iris opens across the screen while the photos are already there behind it.
/// Decorative only: no hit testing, never delays access, skipped with Reduce Motion.
struct RevealOverlay: View {
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
                    Aperture(progress: progress).frame(width: d * (0.35 + 0.9 * progress), height: d * (0.35 + 0.9 * progress))
                    LensRing(rotation: Double(progress) * .pi / 3).frame(width: d * (0.5 + 1.1 * progress), height: d * (0.5 + 1.1 * progress))
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .opacity(Double(1 - progress * 0.95))
            }
        }
        .ignoresSafeArea()
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
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.8)) { progress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { visible = false }
    }
}

private struct FilmGrain: View {
    var body: some View {
        Canvas { ctx, size in
            var s: UInt64 = 7
            func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
            for _ in 0..<Int(size.width * size.height / 700) {
                let x = CGFloat(next() % UInt64(max(1, size.width))), y = CGFloat(next() % UInt64(max(1, size.height)))
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(Double(next() % 30) / 400)))
            }
        }
        .drawingGroup()
    }
}
