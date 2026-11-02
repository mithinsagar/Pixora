import SwiftUI
import AppKit
import AVFoundation
import PixoraCore

// MARK: - Request & settings

enum SlideTransition: String, CaseIterable, Identifiable {
    case crossfade, zoom, slide, cut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .crossfade: "Crossfade"
        case .zoom: "Gentle zoom"
        case .slide: "Drift"
        case .cut: "Cut"
        }
    }
}

enum MusicChoice: Equatable {
    /// Soft chords Pixora synthesises itself while playing — no recording, so nothing to license.
    case ambient
    /// An audio file the user picked.
    case file(URL)
}

struct SlideshowRequest: Identifiable {
    let id = UUID()
    let title: String
    let slides: [Photo]
    /// Shown at the bottom-left: date and names. Keyed by photo id.
    let captions: [Int64: String]
    let duration: Double
    let transition: SlideTransition
    let showCaptions: Bool
    /// nil = muted (the default).
    let music: MusicChoice?
    let volume: Float
    /// Made inside Private Space: closes the moment Private Space locks.
    let isPrivate: Bool
}

// MARK: - Music

/// Background music for slideshows. Off unless the user turns it on, and it only plays while a slideshow
/// they started is playing (or while they press Listen in the studio).
@MainActor
final class SlideshowMusic {
    static let shared = SlideshowMusic()
    private var engine: AVAudioEngine?
    private var synth: AmbientSynth?
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false

    func start(_ choice: MusicChoice, volume: Float) {
        stop()
        switch choice {
        case .ambient:
            let s = AmbientSynth()
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let node = AVAudioSourceNode(format: format) { _, _, frames, abl in s.render(frames: Int(frames), into: abl); return noErr }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = volume
            do { try engine.start(); self.engine = engine; self.synth = s; isPlaying = true } catch { NSLog("Pixora: music engine failed: \(error)") }
        case .file(let url):
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            p.setVolume(volume, fadeDuration: 1.5)
            player = p; isPlaying = true
        }
    }

    func setVolume(_ v: Float) {
        engine?.mainMixerNode.outputVolume = v
        player?.volume = v
    }

    func pause() { engine?.pause(); player?.pause() }
    func resume() { try? engine?.start(); player?.play() }

    func stop() {
        engine?.stop(); engine = nil; synth = nil
        player?.stop(); player = nil
        isPlaying = false
    }
}

/// A slow, quiet pad: four seventh chords, eight seconds each, overlapping with long fades. Generated sample
/// by sample, so there is no recording involved.
final class AmbientSynth: @unchecked Sendable {
    private var t: Double = 0
    private var gain: Double = 0          // fades in over ~3 s
    private let rate = 44_100.0
    private let chords: [[Double]] = [
        [130.81, 164.81, 196.00, 246.94],   // Cmaj7
        [110.00, 130.81, 164.81, 196.00],   // Am7
        [87.31, 110.00, 130.81, 164.81],    // Fmaj7
        [98.00, 123.47, 146.83, 164.81],    // G6
    ]

    func render(frames: Int, into abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let span = 8.0, fade = 3.0
        for f in 0..<frames {
            let k = Int(floor(t / span))
            var v = 0.0
            for j in [k - 1, k] where j >= 0 {
                let local = t - Double(j) * span
                var env = 0.0
                if local < fade { env = local / fade } else if local < span { env = 1 } else if local < span + fade { env = 1 - (local - span) / fade }
                env = env * env * (3 - 2 * env)   // smoothstep
                guard env > 0 else { continue }
                for freq in chords[j % chords.count] {
                    let w = 2 * Double.pi * freq * t
                    v += env * (sin(w) + 0.25 * sin(2.003 * w) + 0.12 * sin(0.5 * w))
                }
            }
            let tremolo = 0.85 + 0.15 * sin(2 * .pi * 0.11 * t)
            gain = min(1, gain + 1 / (3 * rate))
            let sample = Float(v * 0.035 * tremolo * gain)
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[f] = sample
            }
            t += 1 / rate
        }
    }
}

// MARK: - Player

/// Full-screen playback over the whole window (the window goes full screen while it plays). Space plays or
/// pauses, ← → step, Esc exits. Transitions are short and quiet; with Reduce Motion every transition is a
/// plain crossfade and nothing zooms or moves.
struct SlideshowPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: SlideshowRequest
    @State private var index = 0
    @State private var playing = true
    @State private var images: [Int: NSImage] = [:]
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var finished = false
    @State private var enteredFullScreen = false
    @State private var musicOn = false
    @FocusState private var focused: Bool

    private var transition: SlideTransition {
        reduceMotion && (request.transition == .zoom || request.transition == .slide) ? .crossfade : request.transition
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = images[index] {
                SlideImage(image: image, zoom: transition == .zoom, duration: request.duration + 1.2, seed: index)
                    .id(index)
                    .transition(slideTransition)
                    .accessibilityLabel(label(for: index))
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            if request.showCaptions, let caption = request.captions[request.slides[index].id], !finished {
                VStack { Spacer(); HStack { Text(caption).font(.system(size: 15, weight: .medium, design: .serif)).foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.8), radius: 6).padding(32); Spacer() } }
                    .id("caption-\(index)").transition(.opacity)
                    .accessibilityHidden(true)
            }
            if finished { endCard }
            if controls || !playing || finished { controlBar.transition(.opacity) }
        }
        .animation(transition == .cut ? nil : .easeInOut(duration: 1.1), value: index)
        .animation(.easeOut(duration: 0.25), value: controls)
        .onContinuousHover { phase in if case .active = phase { poke() } }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onExitCommand { exit() }
        .task(id: index) { await load() }
        .task(id: "\(index)-\(playing)-\(finished)") { await advanceAfterDelay() }
        .onAppear {
            focused = true
            poke()
            if let w = NSApp.keyWindow ?? NSApp.mainWindow, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); enteredFullScreen = true }
            if let m = request.music { SlideshowMusic.shared.start(m, volume: request.volume); musicOn = true }
            announce()
        }
        .onDisappear {
            SlideshowMusic.shared.stop()
            hideTask?.cancel()
            NSCursor.unhide()
            if enteredFullScreen, let w = NSApp.keyWindow ?? NSApp.mainWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
        .onChange(of: model.isPrivateUnlocked) { _, unlocked in if request.isPrivate && !unlocked { model.slideshow = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slideshow: \(request.title)")
    }

    private var slideTransition: AnyTransition {
        switch transition {
        case .crossfade, .zoom: .opacity
        case .slide: .asymmetric(insertion: .opacity.combined(with: .offset(x: 50)), removal: .opacity.combined(with: .offset(x: -50)))
        case .cut: .identity
        }
    }

    private var controlBar: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(.white)
                    if request.isPrivate { Label("Private Space", systemImage: "lock.fill").font(.caption).foregroundStyle(Vault.brass) }
                }
                Spacer()
                Button { exit() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).background(Circle().fill(.white.opacity(0.14))).foregroundStyle(.white)
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Exit slideshow").help("Exit (Esc)")
            }
            .padding(24)
            Spacer()
            HStack(spacing: 18) {
                roundButton("backward.fill", "Previous photo") { step(-1) }.disabled(index == 0)
                roundButton(playing && !finished ? "pause.fill" : "play.fill", playing && !finished ? "Pause" : "Play", big: true) { togglePlay() }
                roundButton("forward.fill", "Next photo") { step(1) }.disabled(index >= request.slides.count - 1)
                Text("\(index + 1) / \(request.slides.count)").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Photo \(index + 1) of \(request.slides.count)")
                if request.music != nil {
                    roundButton(musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill", musicOn ? "Mute music" : "Play music") {
                        musicOn.toggle(); if musicOn { SlideshowMusic.shared.resume() } else { SlideshowMusic.shared.pause() }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .padding(.bottom, 34)
        }
    }

    private var endCard: some View {
        VStack(spacing: 16) {
            Text("The end").font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(.white)
            Text("\(request.slides.count) photos").foregroundStyle(.white.opacity(0.7))
            HStack {
                Button { index = 0; finished = false; playing = true } label: { Label("Play Again", systemImage: "arrow.counterclockwise") }
                Button("Exit") { exit() }
            }.controlSize(.large)
        }
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.55)))
    }

    private func roundButton(_ icon: String, _ label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 20 : 14, weight: .bold))
                .frame(width: big ? 50 : 38, height: big ? 50 : 38)
                .background(Circle().fill(.white.opacity(big ? 0.22 : 0.12)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    private func label(for i: Int) -> String {
        "Photo \(i + 1) of \(request.slides.count)" + (request.captions[request.slides[i].id].map { ": \($0)" } ?? "")
    }

    private func announce() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(label(for: index)).post()
    }

    private func poke() {
        controls = true
        NSCursor.unhide()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, playing, !finished else { return }
            controls = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func togglePlay() {
        if finished { index = 0; finished = false; playing = true; return }
        playing.toggle()
        if request.music != nil && musicOn { playing ? SlideshowMusic.shared.resume() : SlideshowMusic.shared.pause() }
        poke()
    }

    private func step(_ d: Int) {
        let next = index + d
        guard next >= 0, next < request.slides.count else { return }
        finished = false
        index = next
        announce()
        poke()
    }

    private func exit() { model.slideshow = nil }

    private func advanceAfterDelay() async {
        guard playing, !finished else { return }
        try? await Task.sleep(for: .seconds(request.duration))
        guard !Task.isCancelled, playing else { return }
        if index < request.slides.count - 1 { index += 1; announce() }
        else { finished = true; controls = true }
    }

    /// The current slide (a quick preview first, then the full image) and the next one, so the next
    /// transition never waits. Only three decoded slides are kept.
    private func load() async {
        let i = index
        await loadSlide(i)
        if i + 1 < request.slides.count { await loadSlide(i + 1) }
        images = images.filter { abs($0.key - index) <= 1 }
    }

    private func loadSlide(_ i: Int) async {
        let p = request.slides[i]
        let root = model.source(p.sourceID).flatMap { $0.isOnline ? $0.url : nil }
        if images[i] == nil, let quick = await ImageCache.shared.photoThumb(p, sourceRoot: root) { images[i] = quick }
        if let full = await ViewerCache.shared.image(for: p, root: root) { images[i] = full }
    }
}

/// One slide, fitted to the screen. With "Gentle zoom" it slowly pushes in (a few percent) towards a corner
/// that varies from slide to slide.
private struct SlideImage: View {
    let image: NSImage
    let zoom: Bool
    let duration: Double
    let seed: Int
    @State private var scale: CGFloat = 1

    var body: some View {
        let anchors: [UnitPoint] = [.center, .topLeading, .bottomTrailing, .topTrailing, .bottomLeading]
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            .scaleEffect(scale, anchor: anchors[seed % anchors.count])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard zoom else { return }
                withAnimation(.linear(duration: duration)) { scale = 1.07 }
            }
    }
}
