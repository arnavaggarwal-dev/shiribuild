import SwiftUI
import Combine
import UIKit

// MARK: - Palette

/// Hex values originally lifted from the Tkinter build's cosmic nebula theme.
///
/// `accent` and `bg` are user-configurable (Settings → Appearance), and the
/// colors that read as *part of* those two — glow, the borders, the card
/// fills — are derived from them so a recolor stays coherent instead of
/// leaving purple glow stranded on a green theme.
///
/// These are `static var` computed properties rather than `static let`
/// constants purely so they can change at runtime: it keeps all ~189
/// `Palette.x` call sites compiling untouched, including the handful inside
/// `GameEngine`/`LANClient` which are not Views and have no environment to
/// read from.
enum Palette {
    static var bg: Color { ThemeStore.shared.bg }
    static var card: Color { ThemeStore.shared.card }
    static var card2: Color { ThemeStore.shared.card2 }
    static var border: Color { ThemeStore.shared.border }
    static var borderActive: Color { ThemeStore.shared.borderActive }
    static var accent: Color { ThemeStore.shared.accent }
    static var glow: Color { ThemeStore.shared.glow }
    static var dim: Color { ThemeStore.shared.dim }
    static var text: Color { ThemeStore.shared.text }

    // Semantic feedback colors stay fixed. They mean "accepted", "rejected"
    // and "careful" — letting them be themed would let a player pick a scheme
    // where a rejected word looks like an accepted one.
    static let red         = Color(hex: 0xF472B6)
    static let redBright   = Color(hex: 0xEC4899)
    static let green       = Color(hex: 0x34D399)
    static let orange      = Color(hex: 0xFB923C)
    static let deepOut     = Color(hex: 0x3D0000)
    static let forbiddenBorder = Color(hex: 0x7C2D2D)
}

// MARK: - Theme store

/// Backing store for the two user-chosen colors, persisted as hex in
/// UserDefaults alongside the other prefs in `AppSettings`.
///
/// While the chosen colors are still the shipped defaults, the derived
/// members return the *original* hand-picked constants rather than anything
/// computed — so an untouched install looks exactly as it always did, and
/// derivation only kicks in once a player actually changes something.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let defaultAccent: UInt32 = 0xA855F7
    static let defaultBg: UInt32 = 0x07050F

    private static let accentKey = "com.arnavaggarwal.shiritori.theme.accent.v1"
    private static let bgKey = "com.arnavaggarwal.shiritori.theme.bg.v1"

    /// Bumped on every change. `RootView` hangs an `.id()` off this to force
    /// SwiftUI to rebuild — static computed properties publish nothing on
    /// their own, so without this the palette would change but nothing would
    /// redraw until the next unrelated state change.
    @Published private(set) var revision = 0

    private(set) var accentHex: UInt32
    private(set) var bgHex: UInt32

    private init() {
        let defaults = UserDefaults.standard
        let storedAccent = defaults.object(forKey: Self.accentKey) as? Int
        let storedBg = defaults.object(forKey: Self.bgKey) as? Int
        accentHex = storedAccent.map { UInt32($0) } ?? Self.defaultAccent
        bgHex = storedBg.map { UInt32($0) } ?? Self.defaultBg
    }

    var isAccentDefault: Bool { accentHex == Self.defaultAccent }
    var isBgDefault: Bool { bgHex == Self.defaultBg }
    var isDefault: Bool { isAccentDefault && isBgDefault }

    func setAccent(_ hex: UInt32) {
        accentHex = hex
        UserDefaults.standard.set(Int(hex), forKey: Self.accentKey)
        revision += 1
    }

    func setBackground(_ hex: UInt32) {
        bgHex = hex
        UserDefaults.standard.set(Int(hex), forKey: Self.bgKey)
        revision += 1
    }

    func resetToDefaults() {
        accentHex = Self.defaultAccent
        bgHex = Self.defaultBg
        UserDefaults.standard.removeObject(forKey: Self.accentKey)
        UserDefaults.standard.removeObject(forKey: Self.bgKey)
        revision += 1
    }

    // MARK: derived colors

    var accent: Color { Color(hex: accentHex) }
    var bg: Color { Color(hex: bgHex) }

    var glow: Color {
        isAccentDefault ? Color(hex: 0xC084FC) : accent.adjusted(saturation: 0.72, brightness: 1.04)
    }

    var borderActive: Color {
        isAccentDefault ? Color(hex: 0x6D28D9) : accent.adjusted(saturation: 1.24, brightness: 0.87)
    }

    var border: Color {
        isAccentDefault ? Color(hex: 0x2D1B54) : accent.adjusted(saturation: 1.05, brightness: 0.36)
    }

    /// Card fills sit just off the background. On a dark theme that means
    /// slightly lighter; on a light one it has to go the other way, or the
    /// cards vanish into the backdrop.
    var card: Color {
        isBgDefault ? Color(hex: 0x0D0818) : bg.shiftedTowardContrast(by: 0.035)
    }

    var card2: Color {
        isBgDefault ? Color(hex: 0x130E24) : bg.shiftedTowardContrast(by: 0.08)
    }

    /// Body text and its muted variant follow the background's luminance.
    /// The palette is otherwise fixed, but leaving near-white text pinned
    /// would make a light background completely unreadable.
    var text: Color {
        isBgDefault ? Color(hex: 0xEDE9FE) : (bg.isLight ? Color(hex: 0x1A1425) : Color(hex: 0xEDE9FE))
    }

    var dim: Color {
        isBgDefault ? Color(hex: 0x5B4D7A) : (bg.isLight ? Color(hex: 0x6B6382) : Color(hex: 0x5B4D7A))
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Perceived luminance, used to decide whether a background needs light
    /// or dark text on top of it.
    var isLight: Bool {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.55
    }

    /// Scales saturation and brightness in HSB space, keeping the hue.
    func adjusted(saturation satScale: Double, brightness briScale: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h),
                     saturation: min(1, max(0, Double(s) * satScale)),
                     brightness: min(1, max(0, Double(b) * briScale)))
    }

    /// Nudges brightness away from the background — lighter for dark colors,
    /// darker for light ones — so layered surfaces stay distinguishable
    /// whichever direction the theme goes.
    func shiftedTowardContrast(by amount: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let delta = isLight ? -amount : amount
        return Color(hue: Double(h),
                     saturation: Double(s),
                     brightness: min(1, max(0, Double(b) + delta)))
    }
}

// MARK: - Type scale

/// Small type namespace so the whole app draws from one font family
/// (SF Rounded) instead of ad-hoc sizes scattered through the views.
enum GameFont {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func headline(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func mono(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded).monospacedDigit() }
}

extension Color {
    /// Round-trips through UIColor to get sRGB components for wire transfer,
    /// as a "#RRGGBB" string — the exact format the Python build sends.
    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Parses "#RRGGBB" or "RRGGBB" (any case). Returns nil for anything else.
    init?(hexString: String?) {
        guard let hexString else { return nil }
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(hex: v)
    }
}
