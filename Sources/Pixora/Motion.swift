import SwiftUI
import AppKit
import PixoraCore

/// The springs everything shares, so the app moves like one thing.
enum Motion {
    /// Photos travelling: settles quickly with no bounce.
    static let glide = Animation.spring(response: 0.36, dampingFraction: 0.92)
    /// Things landing: a little life, for hearts, cards and badges.
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.62)
    static let quick = Animation.easeOut(duration: 0.16)
}

/// A light tap from the trackpad at the moment something clicks into place. Only Force Touch trackpads can do this;
/// elsewhere it does nothing.
@MainActor
enum Haptics {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func thud() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}

/// Fine film grain. Laid over the glow it stops dark gradients from banding, and it suits the darkroom look.
struct RoomGrain: View {
    private static let tile: CGImage? = {
        let side = 192
        var state: UInt64 = 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: side * side)
        for i in bytes.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes[i] = UInt8(truncatingIfNeeded: state >> 32)
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }()

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2).resizable(resizingMode: .tile).blendMode(.overlay).opacity(0.16)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The photo's own colours, softly filling the room behind it. The glow arrives pre-blurred, so nothing is computed
/// per frame and it can crossfade during a swipe for free.
struct AmbientGlow: View {
    let image: CGImage?
    var body: some View {
        // In an overlay: the picture fills the space without its own size ever affecting the layout around it.
        Color.clear
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill() }
            }
            .clipped()
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Darkens the edges so the eye rests on the middle.
struct Vignette: View {
    var strength = 0.55
    var body: some View {
        RadialGradient(colors: [.clear, .black.opacity(strength)], center: .center, startRadius: 180, endRadius: 980)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A heart that swells up over the photo and fades as you favorite it.
struct HeartBurst: View {
    var size: CGFloat = 110
    var done: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * .pi * 2
                Circle().fill(Color.pink.opacity(0.9)).frame(width: size * 0.07, height: size * 0.07)
                    .offset(x: cos(angle) * size * 0.9 * phase, y: sin(angle) * size * 0.9 * phase)
                    .opacity(reduceMotion ? 0 : 1 - phase)
            }
            Image(systemName: "heart.fill").font(.system(size: size)).foregroundStyle(Color.pink.gradient).shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .scaleEffect(reduceMotion ? 1 : 0.4 + min(phase * 2.4, 0.75) - max(0, phase - 0.6) * 0.3)
                .opacity(phase < 0.6 ? 1 : (1 - phase) / 0.4)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.75)) { phase = 1 } completion: { done() }
        }
    }
}

extension View {
    /// Rows settle into place as they scroll in from the edges of the window.
    func scrollEntrance() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content.opacity(phase.isIdentity ? 1 : 0.5).scaleEffect(phase.isIdentity ? 1 : 0.985)
        }
    }

    /// Rolls digits up or down when `value` changes instead of swapping them.
    func rollingNumber(_ value: Int) -> some View {
        monospacedDigit().contentTransition(.numericText(value: Double(value))).animation(.snappy(duration: 0.28), value: value)
    }
}

/// The ✕ on full-window screens. It grows and brightens under the pointer, and all of the circle can be clicked.
struct CloseCircle: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.32 : 0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(hovering ? 0.4 : 0)))
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(CloseCirclePress())
        .scaleEffect(hovering && !reduceMotion ? 1.14 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.68), value: hovering)
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
        .keyboardShortcut(.cancelAction).help(help).accessibilityLabel("Close")
    }
}

private struct CloseCirclePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// For dark, full-window screens: a soft pill of frosted white.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.26 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

/// A rectangle anywhere in the view, for clipping to a region without the cost of a mask.
struct RegionShape: Shape {
    var region: CGRect
    func path(in rect: CGRect) -> Path { Path(region) }
}
