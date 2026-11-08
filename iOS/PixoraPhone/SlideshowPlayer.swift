import SwiftUI
import PixoraCore

/// Full-screen slideshow. Tap to show or hide controls, swipe left or right to step, pull down or tap ✕ to exit.
/// Music never starts by itself: the speaker button starts it. With Reduce Motion every transition is a plain
/// crossfade and nothing zooms; with VoiceOver it starts paused and the controls stay visible.
struct SlideshowPlayer: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let request: SlideshowRequest
    @State private var index = 0
    @State private var playing = true
    @State private var images: [Int: UIImage] = [:]
    @State private var controls = true
    @State private var musicOn = false
    @State private var volume: Float = 0.35
    @State private var zoom = false
    @State private var direction = 1

    private var transition: SlideshowTransition { reduceMotion ? .crossfade : request.transition }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            slide.id(index).transition(slideTransition)
            if request.showCaptions, let text = request.captions[request.slides[safe: index]?.id ?? 0], !text.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(text).font(.callout.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.35)))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, controls ? 110 : 28)
                }
                .animation(Motion.quick, value: controls)
                .allowsHitTesting(false)
            }
            if controls || voiceOver { overlay.transition(.opacity) }
        }
        .statusBarHidden(!controls)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.quick) { controls.toggle() } }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if abs(v.translation.width) > abs(v.translation.height) { step(v.translation.width < 0 ? 1 : -1) }
            else if v.translation.height > 120 { close() }
        })
        .task(id: "\(index)-\(playing)") { await advanceLater() }
        .task(id: index) { await preload() }
        .task(id: controls) {
            guard controls, playing, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.quick) { controls = false }
        }
        .onAppear {
            volume = request.volume
            UIApplication.shared.isIdleTimerDisabled = true
            if voiceOver { playing = false }
        }
        .onDisappear {
            SlideshowMusic.shared.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .accessibilityAction(.escape) { close() }
    }

    @ViewBuilder private var slide: some View {
        if let img = images[index] {
            Image(uiImage: img).resizable().scaledToFit()
                .scaleEffect(transition == .zoom && zoom ? 1.07 : 1)
                .animation(transition == .zoom ? .linear(duration: request.duration + 1) : nil, value: zoom)
                .onAppear { zoom = false; DispatchQueue.main.async { zoom = true } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement()
                .accessibilityLabel(request.captions[request.slides[safe: index]?.id ?? 0].flatMap { $0.isEmpty ? nil : $0 } ?? "Photo \(index + 1)")
        } else {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var slideTransition: AnyTransition {
        switch transition {
        case .crossfade, .zoom: .opacity
        case .slide: .asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity), removal: .opacity)
        case .cut: .identity
        }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel("Close slideshow")
                .accessibilityIdentifier("player.close")
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(index + 1) of \(request.slides.count)").font(.caption).opacity(0.7)
                }
                .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 12)
            Spacer()
            VStack(spacing: 10) {
                if request.music != nil && musicOn {
                    HStack {
                        Image(systemName: "speaker.fill").accessibilityHidden(true)
                        Slider(value: Binding(get: { volume }, set: { volume = $0; SlideshowMusic.shared.setVolume($0) }), in: 0...1)
                            .tint(.white).accessibilityLabel("Music volume")
                        Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 8)
                }
                HStack(spacing: 0) {
                    control("backward.fill", "Previous photo") { step(-1) }
                    control(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play") { playing.toggle(); syncMusic() }
                        .accessibilityIdentifier("player.playPause")
                    control("forward.fill", "Next photo") { step(1) }
                    if request.music != nil {
                        control(musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill", musicOn ? "Mute music" : "Play music") { toggleMusic() }
                            .accessibilityIdentifier("player.music")
                    }
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func control(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private func step(_ d: Int) {
        guard !request.slides.isEmpty else { return }
        direction = d
        let next = (index + d + request.slides.count) % request.slides.count
        if transition == .cut { index = next } else { withAnimation(.easeInOut(duration: transition == .slide ? 0.6 : 0.8)) { index = next } }
    }

    private func advanceLater() async {
        guard playing, request.slides.count > 1 else { return }
        try? await Task.sleep(for: .seconds(request.duration))
        guard !Task.isCancelled, playing else { return }
        step(1)
    }

    private func preload() async {
        for i in [index, index + 1, index + 2] where i < request.slides.count && images[i] == nil {
            let p = request.slides[i]
            if let img = await PhotoImages.shared.full(p, sourceRoot: model.source(p.sourceID)?.url, maxPixel: 2400)?.image { images[i] = img }
        }
        for k in images.keys where k < index - 2 || k > index + 3 { images[k] = nil }
    }

    private func toggleMusic() {
        guard let music = request.music else { return }
        musicOn.toggle()
        if musicOn {
            if SlideshowMusic.shared.isPlaying { SlideshowMusic.shared.resume() } else { SlideshowMusic.shared.start(music, volume: volume) }
            if !playing { SlideshowMusic.shared.pause() }
        } else { SlideshowMusic.shared.pause() }
    }

    private func syncMusic() {
        guard musicOn else { return }
        if playing { SlideshowMusic.shared.resume() } else { SlideshowMusic.shared.pause() }
    }

    private func close() {
        SlideshowMusic.shared.stop()
        dismiss()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
