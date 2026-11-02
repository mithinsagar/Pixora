import SwiftUI
import AppKit

/// One colour theme with a light and a dark variant. Hex order: canvas, panel, card, ink, ink2, rule, accent,
/// onAccent, confirmed.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String
    let light: [UInt32]
    let dark: [UInt32]

    var canvas: Color { c(0) }
    var panel: Color { c(1) }
    var card: Color { c(2) }
    var ink: Color { c(3) }
    var ink2: Color { c(4) }
    var rule: Color { c(5) }
    var accent: Color { c(6) }
    var onAccent: Color { c(7) }
    var confirmed: Color { c(8) }

    /// Adapts to light / dark automatically.
    private func c(_ i: Int) -> Color { Theme.dynamic(light: light[i], dark: dark[i]) }

    /// Fixed (non-adaptive) colours for previews of a specific variant.
    func swatch(_ i: Int, dark isDark: Bool) -> Color { Color(hex: isDark ? dark[i] : light[i]) }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
            return NSColor(hex: hex)
        })
    }

    static let all: [Theme] = [
        Theme(id: "darkroom", name: "Darkroom", blurb: "Warm charcoal and safelight amber. The original.",
              light: [0xF2EEE6, 0xFAF8F3, 0xFFFFFF, 0x1C1A17, 0x6A6358, 0xDCD5C8, 0xB4471A, 0xFFFFFF, 0x2F6B4F],
              dark: [0x121110, 0x1B1917, 0x25221F, 0xF2EDE4, 0xA8A095, 0x35312C, 0xF0874A, 0x1A0E06, 0x7FC8A0]),
        Theme(id: "contact", name: "Contact Sheet", blurb: "Proof-print paper and red grease pencil.",
              light: [0xF7F4EC, 0xFFFDF8, 0xFFFFFF, 0x23201B, 0x76705F, 0xE3DCCB, 0x9C2F1E, 0xFFFFFF, 0x3B6E4E],
              dark: [0x1C1B18, 0x24221E, 0x2E2B26, 0xEEE8DC, 0xACA494, 0x3C3832, 0xE06B57, 0x1A0905, 0x86C79E]),
        Theme(id: "midnight", name: "Midnight", blurb: "Deep navy with an ice-blue accent.",
              light: [0xEEF2F8, 0xF7F9FC, 0xFFFFFF, 0x141B2D, 0x5B6680, 0xD5DCE8, 0x2F5BD3, 0xFFFFFF, 0x2C7A5B],
              dark: [0x0B1020, 0x121A2E, 0x1A2440, 0xE6ECF8, 0x9AA6C2, 0x26304D, 0x7EA6FF, 0x0A1330, 0x79D3A8]),
        Theme(id: "forest", name: "Forest", blurb: "Pine greens, calm and outdoorsy.",
              light: [0xEEF2EC, 0xF7F9F5, 0xFFFFFF, 0x18231B, 0x5D6E60, 0xD4DED3, 0x2E7D4F, 0xFFFFFF, 0x1F6E8C],
              dark: [0x0F1611, 0x151F18, 0x1D2A21, 0xE5EFE6, 0x9DB2A1, 0x2A392E, 0x6FCB8F, 0x08200F, 0x7FC6E0]),
        Theme(id: "rose", name: "Rosé", blurb: "Soft blush with a berry accent.",
              light: [0xF8F0F1, 0xFDF8F8, 0xFFFFFF, 0x2A1A1E, 0x7D6268, 0xEADADD, 0xB23A63, 0xFFFFFF, 0x3C7A5A],
              dark: [0x1A1215, 0x22181C, 0x2D2025, 0xF5E9EC, 0xB99CA4, 0x3D2C32, 0xF28FB0, 0x2A0A16, 0x86C9A3]),
        Theme(id: "slate", name: "Slate", blurb: "Cool grey and electric blue. Very neutral for colour work.",
              light: [0xEFF1F4, 0xF8F9FB, 0xFFFFFF, 0x1A1D23, 0x646B78, 0xD8DCE3, 0x1F6FEB, 0xFFFFFF, 0x2F7D5B],
              dark: [0x131519, 0x1A1D22, 0x23272E, 0xE8EBF0, 0x9AA1AD, 0x30353D, 0x58A6FF, 0x06162E, 0x7CCB9F]),
        Theme(id: "cyanotype", name: "Cyanotype", blurb: "Prussian blue, like a sun print.",
              light: [0xE9F0F6, 0xF4F8FB, 0xFFFFFF, 0x0E2A47, 0x4F6B86, 0xCFDCE8, 0x0F4C81, 0xFFFFFF, 0x2C7A64],
              dark: [0x0A1E33, 0x0F2742, 0x163252, 0xE3EEF8, 0x98B4CE, 0x21405F, 0x8EC3F2, 0x06213D, 0x86D1B6]),
        Theme(id: "sepia", name: "Sepia", blurb: "Old-print browns and toasted gold.",
              light: [0xF3ECE0, 0xFAF5EC, 0xFFFDF8, 0x2E2318, 0x7A6650, 0xE2D5C0, 0x8A5A2B, 0xFFFFFF, 0x4D7A3E],
              dark: [0x1A140E, 0x221A12, 0x2C2218, 0xEFE3D0, 0xB5A086, 0x3B2F22, 0xD9A066, 0x241405, 0x9CC48A]),
        Theme(id: "noir", name: "Neon Noir", blurb: "Inky black with a hot magenta accent.",
              light: [0xF1EFF4, 0xF9F8FB, 0xFFFFFF, 0x18151F, 0x6A6478, 0xDCD8E4, 0xC2187F, 0xFFFFFF, 0x2F7D5B],
              dark: [0x0A0A0D, 0x111116, 0x18181F, 0xF0EEF6, 0xA39FB3, 0x26252F, 0xFF4FB2, 0x2A0019, 0x5EE0A8]),
        Theme(id: "mono", name: "Monochrome", blurb: "Pure greys. Nothing competes with the photos.",
              light: [0xF2F2F2, 0xFAFAFA, 0xFFFFFF, 0x161616, 0x6B6B6B, 0xDDDDDD, 0x2B2B2B, 0xFFFFFF, 0x3A3A3A],
              dark: [0x0E0E0E, 0x161616, 0x1F1F1F, 0xF2F2F2, 0xA3A3A3, 0x2E2E2E, 0xEDEDED, 0x111111, 0xCFCFCF]),
        Theme(id: "golden", name: "Golden Hour", blurb: "Late-afternoon amber and warm cream.",
              light: [0xFBF3E6, 0xFFF9F0, 0xFFFFFF, 0x2B1D0E, 0x80694D, 0xEEDFC6, 0xC46A12, 0xFFFFFF, 0x467A3F],
              dark: [0x1B130A, 0x24190D, 0x2F2112, 0xF7EAD6, 0xC2A781, 0x3E2D18, 0xFFB347, 0x2B1600, 0xA3D18B]),
        Theme(id: "ocean", name: "Ocean", blurb: "Deep teal and sea glass.",
              light: [0xEAF4F4, 0xF5FAFA, 0xFFFFFF, 0x0F2526, 0x557173, 0xD0E3E3, 0x0E7C86, 0xFFFFFF, 0x2F7D5B],
              dark: [0x0A1718, 0x0F2021, 0x152B2C, 0xE2F2F2, 0x92B5B6, 0x1F3A3B, 0x4FD1D9, 0x03282B, 0x9BE3B5]),
        Theme(id: "lavender", name: "Lavender", blurb: "Dusky violet, gentle and modern.",
              light: [0xF3F1F9, 0xFAF9FD, 0xFFFFFF, 0x1F1A2E, 0x6C6582, 0xDFDAEC, 0x6B4FD3, 0xFFFFFF, 0x2F7D5B],
              dark: [0x14111D, 0x1B1726, 0x241F33, 0xECE8F7, 0xA69FBE, 0x332D45, 0xB39DFF, 0x1A0F3A, 0x86D3AE]),
        Theme(id: "ember", name: "Ember", blurb: "Dark ash and glowing red.",
              light: [0xF7EEEC, 0xFCF7F6, 0xFFFFFF, 0x2A1512, 0x7D5D58, 0xE8D6D2, 0xC0392B, 0xFFFFFF, 0x3C7A5A],
              dark: [0x160D0C, 0x1F1311, 0x2A1A17, 0xF5E7E4, 0xB8988F, 0x3A2622, 0xFF6B57, 0x2B0600, 0x8BCBA2]),
        Theme(id: "sage", name: "Sage", blurb: "Muted herb greens, soft on the eyes.",
              light: [0xF1F3EE, 0xF8FAF6, 0xFFFFFF, 0x20251E, 0x66705F, 0xDCE2D5, 0x5E7F4F, 0xFFFFFF, 0x2E6E8C],
              dark: [0x151913, 0x1C211A, 0x252B22, 0xE8EDE3, 0xA2AE9A, 0x323A2D, 0xA8C98F, 0x14230C, 0x8EC5E0]),
        Theme(id: "citrus", name: "Citrus", blurb: "Fresh lime on dark olive. Bright and playful.",
              light: [0xF7F6EC, 0xFCFBF4, 0xFFFFFF, 0x222013, 0x6E6B52, 0xE3E0C9, 0x5B7F00, 0xFFFFFF, 0x2E7D6B],
              dark: [0x141409, 0x1C1C0F, 0x262616, 0xF1F0DE, 0xACA98A, 0x36352A, 0xD4F04A, 0x1C2400, 0x7FD3B0]),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { ["system": "System", "light": "Light", "dark": "Dark"][rawValue]! }
    var icon: String { ["system": "circle.lefthalf.filled", "light": "sun.max", "dark": "moon"][rawValue]! }
}

enum HeadingDesign: String, CaseIterable, Identifiable {
    case serif, sans, rounded, mono
    var id: String { rawValue }
    var label: String { ["serif": "New York (serif)", "sans": "SF Pro", "rounded": "SF Rounded", "mono": "SF Mono"][rawValue]! }
    var design: Font.Design { ["serif": .serif, "sans": .default, "rounded": .rounded, "mono": .monospaced][rawValue]! }
}

/// Theme and visual preferences, observable so the whole app re-colours (with animation) when they change.
@MainActor @Observable
final class ThemeManager {
    static let shared = ThemeManager()
    private let d = UserDefaults.standard

    var themeID: String { didSet { d.set(themeID, forKey: "themeID"); theme = Theme.named(themeID) } }
    private(set) var theme: Theme
    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    /// Custom accent (nil = the theme's own).
    var customAccent: UInt32? { didSet { if let c = customAccent { d.set(Int(c), forKey: "customAccent") } else { d.removeObject(forKey: "customAccent") } } }
    var headingDesign: HeadingDesign { didSet { d.set(headingDesign.rawValue, forKey: "headingDesign") } }
    var showFilenames: Bool { didSet { d.set(showFilenames, forKey: "showFilenames") } }
    var showFaceBadges: Bool { didSet { d.set(showFaceBadges, forKey: "showFaceBadges") } }
    var showQualityBadges: Bool { didSet { d.set(showQualityBadges, forKey: "showQualityBadges") } }
    var hoverEffects: Bool { didSet { d.set(hoverEffects, forKey: "hoverEffects") } }
    var tileCorner: Double { didSet { d.set(tileCorner, forKey: "tileCorner") } }
    var gridGap: Double { didSet { d.set(gridGap, forKey: "gridGap") } }
    var sidebarPeople: Int { didSet { d.set(sidebarPeople, forKey: "sidebarPeople") } }

    var accent: Color { customAccent.map { Color(hex: $0) } ?? theme.accent }
    var onAccent: Color {
        guard let c = customAccent else { return theme.onAccent }
        return NSColor(hex: c).luminance > 0.55 ? Color(hex: 0x111111) : .white
    }

    private init() {
        let id = d.string(forKey: "themeID") ?? "darkroom"
        themeID = id
        theme = Theme.named(id)
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        customAccent = (d.object(forKey: "customAccent") as? Int).map { UInt32($0) }
        headingDesign = HeadingDesign(rawValue: d.string(forKey: "headingDesign") ?? "") ?? .serif
        showFilenames = d.object(forKey: "showFilenames") as? Bool ?? true
        showFaceBadges = d.object(forKey: "showFaceBadges") as? Bool ?? true
        showQualityBadges = d.object(forKey: "showQualityBadges") as? Bool ?? true
        hoverEffects = d.object(forKey: "hoverEffects") as? Bool ?? true
        tileCorner = d.object(forKey: "tileCorner") as? Double ?? 3
        gridGap = d.object(forKey: "gridGap") as? Double ?? 10
        sidebarPeople = d.object(forKey: "sidebarPeople") as? Int ?? 20
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Testing/screenshot hook: show a theme without changing the saved preference.
    func showWithoutSaving(_ id: String) { theme = Theme.named(id) }

    /// Switch theme with a smooth crossfade of every colour in the app.
    func apply(_ id: String) { withAnimation(.easeInOut(duration: 0.45)) { themeID = id } }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    var hexValue: UInt32 {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
    }
}
