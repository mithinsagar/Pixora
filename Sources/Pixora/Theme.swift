import SwiftUI
import AppKit
import PixoraCore

/// The app's colours, always from the current theme (and accent override). Views that read these re-render
/// automatically when the theme changes, because ThemeManager is observable.
@MainActor
enum Palette {
    private static var t: ThemeManager { ThemeManager.shared }
    static var canvas: Color { t.theme.canvas }
    static var panel: Color { t.theme.panel }
    static var card: Color { t.theme.card }
    static var ink: Color { t.theme.ink }
    static var ink2: Color { t.theme.ink2 }
    static var rule: Color { t.theme.rule }
    static var safelight: Color { t.accent }
    static var onSafelight: Color { t.onAccent }
    static var confirmed: Color { t.theme.confirmed }
}

@MainActor
enum Typography {
    /// Headings: New York serif by default, or the face chosen in Settings → Appearance.
    static func display(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: ThemeManager.shared.headingDesign.design) }
    /// Film-rebate style labels: frame numbers, filenames, counts.
    static let edge = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let edgeLarge = Font.system(size: 12, weight: .medium, design: .monospaced)
}

/// Uppercase monospaced label, like the edge print on a strip of film.
struct EdgeLabel: View {
    let text: String
    var color: Color?
    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Typography.edge).tracking(1.1).foregroundStyle(color ?? Palette.ink2).lineLimit(1)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typography.display()).foregroundStyle(Palette.ink)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(Palette.ink2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.safelight.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .foregroundStyle(Palette.onSafelight)
    }
}

extension View {
    func cardBackground(radius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    static func size(_ b: Int64) -> String { bytes.string(fromByteCount: b) }
    static let day: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    static func duration(_ s: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Who made Pixora — shown in the sidebar footer, Settings → About and the About panel.
enum Credits {
    static let author = "Mithin Sagar"
    static let email = "mithinsagarofficial@gmail.com"
}
