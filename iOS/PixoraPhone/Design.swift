import SwiftUI
import UIKit
import PixoraCore

// MARK: - Colour

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// The Mac app's "Darkroom" theme: warm charcoal and safelight amber, with paper tones in light mode.
enum Palette {
    static let canvas = Color.dynamic(light: 0xF2EEE6, dark: 0x121110)
    static let panel = Color.dynamic(light: 0xFAF8F3, dark: 0x1B1917)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x25221F)
    static let ink = Color.dynamic(light: 0x1C1A17, dark: 0xF2EDE4)
    static let ink2 = Color.dynamic(light: 0x6A6358, dark: 0xA8A095)
    static let rule = Color.dynamic(light: 0xDCD5C8, dark: 0x35312C)
    static let safelight = Color.dynamic(light: 0xB4471A, dark: 0xF0874A)
    static let onSafelight = Color.dynamic(light: 0xFFFFFF, dark: 0x1A0E06)
    static let confirmed = Color.dynamic(light: 0x2F6B4F, dark: 0x7FC8A0)
    static let warning = Color.dynamic(light: 0x9A5B00, dark: 0xF0B35A)
}

// MARK: - Type

enum Typo {
    /// Serif headings (New York), scaled with Dynamic Type.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font { .system(style, design: .serif).weight(.semibold) }
    /// Film-edge labels: counts, frame numbers, small capitals.
    static let edge = Font.system(.caption2, design: .monospaced).weight(.medium)

    /// Navigation bar titles in the same serif, so native bars still feel like Pixora.
    static func styleNavigationBars() {
        func serif(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let d = UIFont.systemFont(ofSize: base.pointSize, weight: weight).fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFont(descriptor: d, size: base.pointSize)
        }
        let a = UINavigationBarAppearance()
        a.configureWithDefaultBackground()
        a.largeTitleTextAttributes = [.font: serif(.largeTitle, weight: .semibold)]
        a.titleTextAttributes = [.font: serif(.headline, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = a
        UINavigationBar.appearance().compactAppearance = a
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = a.largeTitleTextAttributes
        edge.titleTextAttributes = a.titleTextAttributes
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}

/// Uppercase monospaced label, like the edge print on a strip of film.
struct EdgeLabel: View {
    let text: String
    var color: Color = Palette.ink2
    init(_ text: String, color: Color = Palette.ink2) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Typo.edge).tracking(1.2).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
    }
}

// MARK: - Buttons

/// Full-width capsule for the one main action on a screen. At least 50 pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.safelight
    var onTint: Color = Palette.onSafelight
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .background(Capsule().fill(tint.opacity(enabled ? 1 : 0.35)))
            .foregroundStyle(onTint)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .background(Capsule().fill(Palette.card))
            .overlay(Capsule().strokeBorder(Palette.rule))
            .foregroundStyle(Palette.ink.opacity(enabled ? 1 : 0.4))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A pill that toggles (filters, modes). The tap area is at least 44 pt tall even when the pill looks smaller.
struct Chip: View {
    let title: String
    var symbol: String? = nil
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(on ? Palette.safelight : Palette.card))
            .overlay(Capsule().strokeBorder(on ? .clear : Palette.rule))
            .foregroundStyle(on ? Palette.onSafelight : Palette.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Surfaces

extension View {
    func card(radius: CGFloat = 18, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.rule.opacity(0.7), lineWidth: 0.5))
    }

    /// Page background used by every main screen.
    func canvas() -> some View { background(Palette.canvas.ignoresSafeArea()) }
}

/// Friendly empty / permission / offline state with an optional action.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Palette.safelight.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(Palette.safelight)
            }
            .accessibilityHidden(true)
            Text(title).font(Typo.display(.title2)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 6).frame(maxWidth: 320)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A short status line under the navigation title.
struct Subtitle: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.ink2).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Formatting

enum Format {
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        f.unitsStyle = .short
        return f.string(from: max(1, seconds)) ?? ""
    }
}

// MARK: - Motion

enum Motion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension View {
    /// Light haptic for selections and confirmations.
    func selectionHaptic<T: Equatable>(_ trigger: T) -> some View { sensoryFeedback(.selection, trigger: trigger) }
}
