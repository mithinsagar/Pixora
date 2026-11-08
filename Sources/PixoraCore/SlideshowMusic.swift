import Foundation
import AVFoundation

// Slideshow transitions and background music, shared by the Mac and iPhone apps. Music is never started by
// Pixora on its own: the apps call start() only after the person opts in.

public enum SlideshowTransition: String, CaseIterable, Identifiable, Sendable {
    case crossfade, zoom, slide, cut
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .crossfade: "Crossfade"
        case .zoom: "Gentle zoom"
        case .slide: "Drift"
        case .cut: "Cut"
        }
    }
}

public enum MusicChoice: Equatable, Sendable {
    /// Soft chords Pixora synthesises itself while playing — no recording, so nothing to license.
    case ambient
    /// An audio file the user picked.
    case file(URL)
}

// MARK: - Music

/// Background music for slideshows. Off unless the user turns it on, and it only plays while a slideshow
/// they started is playing (or while they press Listen in the studio).
@MainActor
public final class SlideshowMusic {
    public static let shared = SlideshowMusic()
    private var engine: AVAudioEngine?
    private var synth: AmbientSynth?
    private var player: AVAudioPlayer?
    public private(set) var isPlaying = false

    public func start(_ choice: MusicChoice, volume: Float) {
        stop()
        #if os(iOS)
        // Playback category so music the person turned on is heard with the ring switch on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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

    public func setVolume(_ v: Float) {
        engine?.mainMixerNode.outputVolume = v
        player?.volume = v
    }

    public func pause() { engine?.pause(); player?.pause() }
    public func resume() { try? engine?.start(); player?.play() }

    public func stop() {
        engine?.stop(); engine = nil; synth = nil
        player?.stop(); player = nil
        #if os(iOS)
        if isPlaying { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        isPlaying = false
    }
}

/// A slow, quiet pad: four seventh chords, eight seconds each, overlapping with long fades. Generated sample
/// by sample, so there is no recording involved.
public final class AmbientSynth: @unchecked Sendable {
    public init() {}
    private var t: Double = 0
    private var gain: Double = 0          // fades in over ~3 s
    private let rate = 44_100.0
    private let chords: [[Double]] = [
        [130.81, 164.81, 196.00, 246.94],   // Cmaj7
        [110.00, 130.81, 164.81, 196.00],   // Am7
        [87.31, 110.00, 130.81, 164.81],    // Fmaj7
        [98.00, 123.47, 146.83, 164.81],    // G6
    ]

    public func render(frames: Int, into abl: UnsafeMutablePointer<AudioBufferList>) {
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
