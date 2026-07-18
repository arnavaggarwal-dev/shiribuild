import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Haptics

// MARK: - Tone Engine

/// Generates short one-shot sine-wave "dings" to pair with haptics — an
/// exponential-decay envelope so each tone sounds like a plucked note
/// rather than a harsh buzz. Kept dead simple: no sample files, buffers are
/// synthesized on the fly (they're a few KB and ~0.15s, cost is trivial).
final class ToneEngine {
    static let shared = ToneEngine()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    // Every buffer we ever generate uses this exact format. Connecting the
    // graph with `format: nil` lets it inherit whatever the hardware route
    // happens to be at connect time — if that later changes (AirPods
    // connecting/disconnecting mid-game is a real, common case), the graph
    // and the buffers we hand it disagree, and scheduleBuffer raises an
    // NSException that Swift can't catch, crashing the app outright. Using
    // one fixed, explicit format here means CoreAudio handles the
    // conversion to whatever the hardware wants internally instead.
    private lazy var toneFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()

        // Route changes (headphones connecting, a call interrupting, etc.)
        // can invalidate the running graph. Rebuild the connection instead
        // of leaving stale state that the next scheduleBuffer call would
        // crash on.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuildConnection()
        }
    }

    private func rebuildConnection() {
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        if !engine.isRunning { try? engine.start() }
    }

    func play(frequency: Double, duration: Double = 0.14, volume: Float = 0.5) {
        guard AppSettings.audioEnabled else { return }
        guard let buffer = makeBuffer(frequency: frequency, duration: duration, volume: volume) else { return }
        if !engine.isRunning {
            // A missed sound effect is fine. A crash mid-game is not — if
            // the engine can't start (interrupted session, no audio route,
            // etc.), skip this tone entirely rather than schedule a buffer
            // into a graph that isn't ready for it.
            guard (try? engine.start()) != nil, engine.isRunning else { return }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Two quick notes back to back — used for the "teh-teh" loser cue.
    func playDouble(frequency: Double, gap: Double = 0.11, duration: Double = 0.09, volume: Float = 0.45) {
        play(frequency: frequency, duration: duration, volume: volume)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.play(frequency: frequency * 0.85, duration: duration, volume: volume)
        }
    }

    private func makeBuffer(frequency: Double, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-7.0 * t)   // fast attack, quick exponential decay
            data[i] = Float(sin(2.0 * .pi * frequency * t)) * volume * Float(envelope)
        }
        return buffer
    }
}

// MARK: - Haptics

enum Haptics {
    /// Every accepted word: success haptic + a bright high-pitched ding.
    /// Pitch is fixed high here (this is "the correct answer" cue, not a
    /// graded one) — the graded/"tougher = higher" pitch lives in sliderTick.
    static func accepted() {
        if AppSettings.hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        ToneEngine.shared.play(frequency: 880, duration: 0.16, volume: 0.55)
    }

    static func rejected() {
        if AppSettings.hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        ToneEngine.shared.play(frequency: 220, duration: 0.14, volume: 0.4)
    }

    static func warning() {
        guard AppSettings.hapticsEnabled else { return }
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred(intensity: 1.0)
    }

    static func winner() {
        if AppSettings.hapticsEnabled {
            let gen = UIImpactFeedbackGenerator(style: .heavy)
            gen.impactOccurred(intensity: 1.0)
        }
        ToneEngine.shared.play(frequency: 660, duration: 0.18, volume: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            ToneEngine.shared.play(frequency: 990, duration: 0.3, volume: 0.6)
        }
    }

    /// Base tap for every button — bumped from .light to .medium at full
    /// intensity so navigation reads as a firmer, more deliberate click.
    static func tap() {
        guard AppSettings.hapticsEnabled else { return }
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred(intensity: 1.0)
    }

    /// Slider "cascade" tick: fire once per discrete step while dragging.
    /// `fraction` is 0...1 of how far into the range the value sits —
    /// intensity AND pitch both scale up with it, so a slider representing
    /// something getting "tougher" (bot difficulty, player count, etc.)
    /// feels and sounds more intense near the top of its range.
    static func sliderTick(fraction: Double) {
        let f = min(max(fraction, 0), 1)
        if AppSettings.hapticsEnabled {
            let gen = UIImpactFeedbackGenerator(style: f > 0.66 ? .heavy : (f > 0.33 ? .medium : .light))
            gen.impactOccurred(intensity: 0.5 + f * 0.5)
        }
        ToneEngine.shared.play(frequency: 260 + f * 620, duration: 0.06, volume: 0.28)
    }

    /// 2-second "teh-teh… teh-teh…" losing cue: four double-pulses (each a
    /// heavy haptic pair plus a falling two-note chirp) spaced across ~2s.
    static func loser() {
        for i in 0..<4 {
            let delay = Double(i) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if AppSettings.hapticsEnabled {
                    let gen = UIImpactFeedbackGenerator(style: .heavy)
                    gen.impactOccurred(intensity: 1.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                        let gen2 = UIImpactFeedbackGenerator(style: .heavy)
                        gen2.impactOccurred(intensity: 0.85)
                    }
                }
                ToneEngine.shared.playDouble(frequency: 180, gap: 0.11, duration: 0.1, volume: 0.4)
            }
        }
    }
}

