import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Small view helpers

/// Frosted floating card used everywhere: lobby tiles, header, score rows.
/// This stays material-based by design, not by toolchain limitation —
/// Apple's Liquid Glass HIG explicitly reserves glass for the functional
/// layer (buttons, controls) and warns against stacking it onto content
/// surfaces like these. See SolidButton/GhostButton for where the real
/// .glassEffect()/.buttonStyle(.glass) API is actually used, gated behind
/// #available(iOS 26, *) so the same IPA works on iOS 17+.
struct GlassCardStyle: ViewModifier {
    var borderColor: Color = Palette.border
    var fill: Color = Palette.card
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill.opacity(0.72))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))

                    // Diagonal specular sheen — a soft light-from-above
                    // highlight, the cheapest way to sell "glass" without
                    // the real refraction API.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), .clear, .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                // Two-tone edge: a bright hairline along the top where
                // light would catch a glass rim, fading to the normal
                // border color — reads as a lit edge rather than a flat
                // outline.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [borderColor.opacity(0.9), Color.white.opacity(0.35), borderColor.opacity(0.9)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func glassCard(border: Color = Palette.border, fill: Color = Palette.card, radius: CGFloat = 18) -> some View {
        modifier(GlassCardStyle(borderColor: border, fill: fill, radius: radius))
    }

    func glow(_ color: Color, radius: CGFloat = 14, opacity: Double = 0.6) -> some View {
        self.shadow(color: color.opacity(opacity), radius: radius)
    }
}

// MARK: - Nebula Background

private struct Star: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var twinkleSpeed: Double
    var twinklePhase: Double
    var depth: CGFloat   // 0.2...1.0, drives parallax drift speed
}

/// Deep-space backdrop: soft drifting purple blobs behind a twinkling,
/// slow-parallax star field. Generated once per launch and animated with
/// TimelineView so it costs almost nothing while sitting idle.
struct AnimatedNebulaBackground: View {
    @State private var stars: [Star] = (0..<90).map { _ in
        Star(x: .random(in: 0...1), y: .random(in: 0...1),
             size: .random(in: 1...2.6), twinkleSpeed: .random(in: 0.6...1.8),
             twinklePhase: .random(in: 0...(.pi * 2)), depth: .random(in: 0.2...1))
    }
    @State private var blobsDrift = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            // slow drifting nebula blobs
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Palette.accent.opacity(0.22))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 90)
                        .offset(x: blobsDrift ? geo.size.width * 0.18 : -geo.size.width * 0.1,
                                y: blobsDrift ? -geo.size.height * 0.12 : geo.size.height * 0.05)
                        .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: blobsDrift)

                    Circle()
                        .fill(Palette.borderActive.opacity(0.28))
                        .frame(width: geo.size.width * 0.7)
                        .blur(radius: 100)
                        .offset(x: blobsDrift ? -geo.size.width * 0.22 : geo.size.width * 0.15,
                                y: blobsDrift ? geo.size.height * 0.35 : geo.size.height * 0.55)
                        .animation(.easeInOut(duration: 18).repeatForever(autoreverses: true), value: blobsDrift)

                    Circle()
                        .fill(Palette.redBright.opacity(0.08))
                        .frame(width: geo.size.width * 0.5)
                        .blur(radius: 80)
                        .offset(x: blobsDrift ? geo.size.width * 0.3 : geo.size.width * 0.05,
                                y: blobsDrift ? geo.size.height * 0.75 : geo.size.height * 0.9)
                        .animation(.easeInOut(duration: 22).repeatForever(autoreverses: true), value: blobsDrift)
                }
            }
            .ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: false)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    for star in stars {
                        // Downward cascade speed scales with depth (parallax).
                        let speed: CGFloat = 0.035 + star.depth * 0.05
                        let rawY = star.y + CGFloat(t) * speed
                        let wrapCount = Int(rawY)               // how many times this star has looped
                        let y = (rawY.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * size.height

                        // Re-randomize x each time a star completes a loop so
                        // falling stars don't pile up into visible repeating
                        // columns/streaks — deterministic hash of (id, wrapCount)
                        // means no mutable state needed, just a pure function of t.
                        var hasher = Hasher()
                        hasher.combine(star.id)
                        hasher.combine(wrapCount)
                        let hashed = abs(hasher.finalize())
                        let xJitter = CGFloat(hashed % 10_000) / 10_000
                        let x = ((star.x + xJitter * 0.6).truncatingRemainder(dividingBy: 1)) * size.width

                        let twinkle = 0.35 + 0.65 * abs(sin(t * star.twinkleSpeed + star.twinklePhase))
                        let rect = CGRect(x: x, y: y, width: star.size, height: star.size)
                        ctx.opacity = twinkle * Double(star.depth)
                        ctx.fill(Path(ellipseIn: rect), with: .color(Palette.text))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onAppear { blobsDrift = true }
    }
}

// MARK: - Buttons

/// Tactile press feedback shared by SolidButton/GhostButton — scales and
/// dims slightly on press with a springy release. This is the "liquid,
/// responsive" feel this project can ship today without the literal
/// Liquid Glass API (see the note on GlassCardStyle above for why).
struct PressableGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Solid pill button — primary CTA (Start Game, Play Word, Play Again…).
///
/// Branches at runtime, not at compile time: this is the same binary
/// running on iOS 17 and iOS 26 alike (deployment target stays 17.0). On
/// iOS 26+ it renders with the real Liquid Glass button style; everywhere
/// else it falls back to the material-based look this project already had.
/// This is Apple's own documented pattern for "one IPA, works everywhere."
struct SolidButton: View {
    var title: String
    var systemImage: String? = nil
    var color: Color = Palette.accent
    var height: CGFloat = 50
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(15))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                }
                .buttonStyle(.glassProminent)
                .tint(color)
            } else {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(15))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                       startPoint: .top, endPoint: .center)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(PressableGlassButtonStyle())
            }
        }
        .glow(color, radius: 16, opacity: isEnabled ? 0.45 : 0)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(.isButton)
    }
}

/// Outline "ghost" button — secondary actions (Back, Fullscreen equivalents).
/// Same runtime-branch approach as SolidButton above.
struct GhostButton: View {
    var title: String
    var systemImage: String? = nil
    var color: Color = Palette.dim
    var height: CGFloat = 42
    var action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(13))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                }
                .buttonStyle(.glass)
                .tint(color)
            } else {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(13))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.card2.opacity(0.6))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(color, lineWidth: 1)
                    )
                }
                .buttonStyle(PressableGlassButtonStyle())
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// Labeled slider used for player counts / difficulty — big value readout,
/// minimum 44pt track height for comfortable thumb dragging.
struct LabeledSlider: View {
    var label: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(GameFont.caption()).foregroundStyle(Palette.dim)
                Spacer()
                Text(valueText).font(GameFont.headline(14)).foregroundStyle(Palette.glow)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
                .frame(minHeight: 44)
                .onChange(of: value) { _, newValue in
                    let span = range.upperBound - range.lowerBound
                    let fraction = span > 0 ? (newValue - range.lowerBound) / span : 0
                    Haptics.sliderTick(fraction: fraction)
                }
        }
    }
}

// MARK: - Score Card

struct ScoreCardView: View {
    var playerNum: Int
    var isBot: Bool
    var score: Int
    var isActive: Bool
    var isOut: Bool
    var isMe: Bool = false
    @State private var displayedScore: Int = 0

    private var name: String {
        isBot ? "Bot" : (isMe ? "You" : "Player \(playerNum)")
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isBot ? Palette.borderActive.opacity(0.35) : Palette.card2)
                    .frame(width: 34, height: 34)
                if isBot {
                    Text("🤖").font(.system(size: 16))
                } else {
                    Text("P\(playerNum)")
                        .font(GameFont.caption(10))
                        .foregroundStyle(isActive ? Palette.glow : Palette.dim)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(GameFont.caption(11))
                    .foregroundStyle(isOut ? Palette.dim : (isActive ? Palette.text : Palette.dim))
                if isOut {
                    Text("out").font(GameFont.caption(9)).foregroundStyle(Palette.redBright)
                }
            }
            Spacer()
            Text("\(displayedScore)")
                .font(GameFont.mono(15))
                .foregroundStyle(isOut ? Palette.redBright : (isActive ? Palette.glow : Palette.dim))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isActive ? (isBot ? Palette.borderActive.opacity(0.18) : Palette.accent.opacity(0.14)) : Palette.card2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOut ? Palette.deepOut : (isActive ? Palette.accent : Palette.border), lineWidth: isActive ? 1.4 : 1)
        )
        .glow(isActive ? Palette.accent : .clear, radius: 10, opacity: 0.5)
        .saturation(isOut ? 0.35 : 1)
        .opacity(isOut ? 0.55 : 1)
        .blur(radius: isOut ? 0.4 : 0)
        .onAppear { displayedScore = score }
        .onChange(of: score) { _, new in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { displayedScore = new }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(score) points\(isOut ? ", eliminated" : (isActive ? ", current turn" : ""))")
    }
}

// MARK: - Word Chain

struct ChainCapsule: View {
    var word: String
    var isNewest: Bool

    var body: some View {
        Text(word)
            .font(GameFont.body(13))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isNewest ? Palette.accent.opacity(0.3) : Palette.card2)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isNewest ? Palette.accent : Palette.border, lineWidth: 1))
    }
}

struct WordChainView: View {
    var words: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                        HStack(spacing: 8) {
                            ChainCapsule(word: word, isNewest: idx == words.count - 1)
                                .id(idx)
                            if idx < words.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Palette.dim)
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                    }
                }
                .padding(.horizontal, 4)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: words)
            }
            .onChange(of: words.count) { _, _ in
                withAnimation { proxy.scrollTo(words.count - 1, anchor: .trailing) }
            }
        }
    }
}

// MARK: - Circular Timer

struct CircularTimerView: View {
    var timeLeft: Int
    var total: Int = 30

    private var fraction: CGFloat {
        max(0, min(1, CGFloat(timeLeft) / CGFloat(total)))
    }
    private var isUrgent: Bool { timeLeft <= 10 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.border, lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isUrgent ? Palette.redBright : Palette.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: fraction)
            Text("\(max(0, timeLeft))")
                .font(GameFont.mono(18))
                .foregroundStyle(isUrgent ? Palette.redBright : Palette.accent)
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel("\(max(0, timeLeft)) seconds left")
    }
}

// MARK: - Bot Thinking Indicator

struct BouncingDotsView: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Palette.glow)
                    .frame(width: 7, height: 7)
                    .offset(y: bounce ? -5 : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .onAppear { bounce = true }
    }
}

// MARK: - Confetti

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    var x: CGFloat
    var delay: Double
    var duration: Double
    var color: Color
    var rotation: Double
    var size: CGFloat
}

struct ConfettiView: View {
    @State private var pieces: [ConfettiPiece] = []
    @State private var fallen = false

    private let colors = [Palette.accent, Palette.glow, Palette.green, Palette.orange, Palette.redBright]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.size, height: piece.size * 0.4)
                        .rotationEffect(.degrees(fallen ? piece.rotation : 0))
                        .position(x: piece.x * geo.size.width, y: fallen ? geo.size.height + 40 : -20)
                        .animation(
                            .easeIn(duration: piece.duration).delay(piece.delay),
                            value: fallen
                        )
                }
            }
            .onAppear {
                pieces = (0..<60).map { _ in
                    ConfettiPiece(x: .random(in: 0...1), delay: .random(in: 0...0.5),
                                  duration: .random(in: 1.6...2.6), color: colors.randomElement()!,
                                  rotation: .random(in: 180...720), size: .random(in: 6...11))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fallen = true }
            }
        }
        .allowsHitTesting(false)
    }
}

